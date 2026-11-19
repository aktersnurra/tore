defmodule Tore.BasicsTest do
  use Tore.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Tore.{Basics, Budget, Planning, Recipes, Shop, Streams}
  alias Tore.Basics.Basic
  alias Tore.Recipes.Ingredient

  # No MockLLM expectations anywhere: a model call fails the test.
  setup :verify_on_exit!

  @today ~D[2026-11-14]
  @week Streams.monday(@today)

  defp d(s), do: Decimal.new(s)
  defp opts, do: Tore.Scope.repo_opts(home_scope())

  defp ingredient(name, price \\ nil) do
    Repo.insert!(%Ingredient{
      household_id: home_scope().household_id,
      name: name,
      key: Ingredient.to_key(name),
      estimated_price: price && d(price),
      estimated_unit: price && "l"
    })
  end

  defp tick(week_start, name, quantity \\ "1", unit \\ "l") do
    list = Streams.shop_list(home_scope(), week_start)
    {:ok, _} = Shop.add_item(home_scope(), list, name, d(quantity), unit, nil)
    {:ok, %{items: items}} = Shop.load_list(home_scope(), list)
    %{id: id} = Enum.find(Map.values(items), &(&1.name == name and not &1.checked))
    {:ok, _} = Shop.check_item(home_scope(), list, id, nil)
  end

  defp weeks_ago(n), do: Date.add(@week, -7 * n)

  defp basic(name) do
    id = Repo.get_by!(Ingredient, [name: name], opts()).id
    Repo.get_by(Basic, [ingredient_id: id], opts())
  end

  describe "learning" do
    test "bought in three weeks, it's a basic with the median gap, and due when that has passed" do
      ingredient("Mjölk")
      for n <- [5, 4, 3], do: tick(weeks_ago(n), "Mjölk")

      :ok = Basics.learn(home_scope(), @today)

      assert %Basic{interval_days: 7, source: :learned, last_bought: last} = basic("Mjölk")
      assert last == weeks_ago(3)
      assert [%{name: "Mjölk"}] = Basics.due(home_scope(), @week)
    end

    test "twice isn't enough" do
      ingredient("Mjölk")
      for n <- [2, 1], do: tick(weeks_ago(n), "Mjölk")

      :ok = Basics.learn(home_scope(), @today)
      assert basic("Mjölk") == nil
    end

    test "what a week's dinners called for doesn't count" do
      {:ok, recipe} =
        Recipes.create(
          home_scope(),
          %{title: "Gratäng", base_servings: 4, ingredients: [%{name: "Grädde", quantity: 2}]}
        )

      for n <- [3, 2, 1] do
        {:ok, _} =
          Planning.assign_recipe(
            home_scope(),
            Streams.plan(home_scope(), weeks_ago(n)),
            "mon_dinner",
            recipe.id,
            4
          )

        tick(weeks_ago(n), "Grädde")
      end

      :ok = Basics.learn(home_scope(), @today)
      assert basic("Grädde") == nil
    end

    test "receipt lines never make a basic: a price match must not reach the list" do
      milk = ingredient("Mjölk")
      Tore.Prices.Products.put(home_scope(), "MELLANMJOLK 1,5%", milk.id)

      for n <- [6, 4, 2] do
        {:ok, _} =
          Tore.Costs.log_receipt(home_scope(), %{
            date: weeks_ago(n),
            store_name: "ICA",
            total_amount: d("20"),
            user_id: user_fixture().id,
            line_items: [
              %{
                product_name: "MELLANMJOLK 1,5%",
                quantity: d("1.5"),
                unit: "l",
                total_price: d("20")
              }
            ]
          })
      end

      :ok = Basics.learn(home_scope(), @today)
      assert basic("Mjölk") == nil
    end
  end

  describe "on the list" do
    setup do
      ingredient("Mjölk", "15")
      :ok = Basics.ask(home_scope(), [%{name: "Mjölk", quantity: d("3"), unit: "l"}])
      :ok
    end

    test "a due basic is added when the list is built, marked as one" do
      items = Shop.items_for(home_scope(), [], @week)
      assert [%{name: "Mjölk", basic: true}] = items
    end

    test "ticking it off makes it due again only after its interval" do
      tick(@week, "Mjölk")
      bought = Tore.Clock.today()

      assert basic("Mjölk").last_bought == bought
      assert Basics.due(home_scope(), Streams.monday(bought)) == []
      assert [_] = Basics.due(home_scope(), Date.add(Streams.monday(bought), 7))
    end

    test "removing it puts it off for longer each time; three in a row stop it" do
      this_week = Streams.monday(Tore.Clock.today())
      list = Streams.shop_list(home_scope(), this_week)
      items = Shop.items_for(home_scope(), [], this_week)

      {:ok, _} =
        Shop.append(home_scope(), list, %Shop.Commands.BuildList{
          week_start: this_week,
          items: items
        })

      {:ok, %{items: on_list}} = Shop.load_list(home_scope(), list)
      [id] = Map.keys(on_list)
      {:ok, _} = Shop.remove_item(home_scope(), list, id, nil)

      assert %Basic{interval_days: 11, removals: 1, last_bought: today} = basic("Mjölk")
      assert today == Tore.Clock.today()
      assert Basics.due(home_scope(), this_week) == []
      assert [_] = Basics.due(home_scope(), Date.add(this_week, 14))

      :ok = Basics.removed(home_scope(), "Mjölk")
      :ok = Basics.removed(home_scope(), "Mjölk")
      assert %Basic{interval_days: 26, stopped: true} = basic("Mjölk")
      assert Shop.items_for(home_scope(), [], Date.add(this_week, 56)) == []
    end

    test "bought this week, it stays in this week's estimate" do
      this_week = Streams.monday(Tore.Clock.today())
      tick(this_week, "Mjölk")

      assert Basics.due(home_scope(), this_week) == []
      assert [%{ingredient_id: _}] = Basics.lines(home_scope(), this_week)
    end

    test "a basic the dinners already need isn't counted twice" do
      {:ok, recipe} =
        Recipes.create(
          home_scope(),
          %{
            title: "Pannkakor",
            base_servings: 4,
            ingredients: [%{name: "Mjölk", quantity: 1, unit: "l"}]
          }
        )

      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), @week),
          "mon_dinner",
          recipe.id,
          4
        )

      assert %{estimate: %{amount: amount}} = Budget.status(home_scope(), @week)
      assert Decimal.eq?(amount, 15)
    end

    test "it's priced into the week's estimate" do
      assert %{estimate: %{amount: amount}} = Budget.status(home_scope(), @week)
      assert Decimal.eq?(amount, 45)
    end

    test "stopping one keeps it off" do
      :ok = Basics.stop(home_scope(), "mjölk")
      assert Basics.due(home_scope(), @week) == []
    end
  end

  test "asking for one that's unknown makes the ingredient" do
    :ok = Basics.ask(home_scope(), [%{name: "Havregryn"}])
    assert [%{name: "Havregryn"}] = Basics.list(home_scope())
    assert Repo.exists?(from(i in Ingredient, where: i.name == "Havregryn"), opts())
  end
end
