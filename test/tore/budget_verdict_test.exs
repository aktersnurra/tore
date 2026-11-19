defmodule Tore.BudgetVerdictTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.{Budget, Costs, Planning, Recipes, Shop, Streams}

  @week ~D[2026-11-02]

  defp d(s), do: Decimal.new(s)

  defp tick(week_start) do
    list = Streams.shop_list(home_scope(), week_start)
    {:ok, _} = Shop.add_item(home_scope(), list, "Mjölk", d("1"), "l", nil)
    {:ok, %{items: items}} = Shop.load_list(home_scope(), list)
    [id] = Map.keys(items)
    {:ok, _} = Shop.check_item(home_scope(), list, id, nil)
  end

  defp receipt(date, total, attrs \\ %{}) do
    {:ok, receipt} =
      Costs.log_receipt(
        home_scope(),
        Map.merge(
          %{date: date, store_name: "ICA", total_amount: d(total), user_id: user_fixture().id},
          attrs
        )
      )

    receipt
  end

  # A week whose plan is one dinner estimated at `kr`, eating out the other days, so none is open.
  defp planned(week_start, kr) do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{
          title: "Middag #{week_start}",
          base_servings: 4,
          ingredients: [%{name: "i #{week_start}", quantity: 1}]
        },
        image: false
      )

    Repo.update_all(
      from(i in Tore.Recipes.Ingredient, where: i.name == ^"i #{week_start}"),
      [set: [estimated_price: d(kr), estimated_unit: "st"]],
      Tore.Scope.repo_opts(home_scope())
    )

    {:ok, _} =
      Planning.assign_recipe(
        home_scope(),
        Streams.plan(home_scope(), week_start),
        "mon_dinner",
        recipe.id,
        4
      )

    for key <- ~w[tue wed thu fri sat sun] do
      {:ok, _} =
        Planning.eat_out(
          home_scope(),
          Streams.plan(home_scope(), week_start),
          key <> "_dinner",
          %{}
        )
    end
  end

  describe "which week a receipt counts towards" do
    test "its own week when nothing was ticked" do
      assert Costs.receipt_week(home_scope(), ~D[2026-11-07]) == @week
    end

    test "the list ticked last, when that's the week after: a weekend shop for the coming week" do
      tick(Date.add(@week, 7))
      assert Costs.receipt_week(home_scope(), ~D[2026-11-07]) == Date.add(@week, 7)
    end

    test "never a list from long ago" do
      tick(Date.add(@week, -21))
      assert Costs.receipt_week(home_scope(), ~D[2026-11-07]) == @week
    end

    test "one tap moves it to the week after and back, and moves the total" do
      r = receipt(~D[2026-11-07], "500")
      assert Costs.spent_in_week(home_scope(), @week) == d("500")

      {:ok, moved} = Costs.move_receipt_week(home_scope(), r.id)
      assert moved.week_start == Date.add(@week, 7)
      assert Costs.spent_in_week(home_scope(), @week) == nil
      assert Costs.spent_in_week(home_scope(), Date.add(@week, 7)) == d("500")

      {:ok, back} = Costs.move_receipt_week(home_scope(), r.id)
      assert back.week_start == @week
    end

    test "several receipts add up" do
      receipt(~D[2026-11-03], "450")
      receipt(~D[2026-11-06], "980.50")
      assert Decimal.eq?(Costs.spent_in_week(home_scope(), @week), d("1430.50"))
    end
  end

  describe "the verdict" do
    test "once the week has ended, from what was paid against the estimate and the budget" do
      planned(@week, "1000")
      :ok = Budget.set_week(home_scope(), @week, d("1200"))
      receipt(~D[2026-11-04], "1050")

      assert Budget.verdict(home_scope(), @week, ~D[2026-11-08]) == nil

      assert %{spent: spent, budget: budget, off_by_percent: 5} =
               Budget.verdict(home_scope(), @week, ~D[2026-11-09])

      assert {spent, budget} == {d("1050"), d("1200")}
    end

    test "from a typed total" do
      planned(@week, "800")
      receipt(~D[2026-11-08], "760", %{store_name: "Inskriven summa", week_start: @week})

      assert %{off_by_percent: -5} = Budget.verdict(home_scope(), @week, ~D[2026-11-10])
    end

    test "none without a receipt or a total" do
      planned(@week, "800")
      assert Budget.verdict(home_scope(), @week, ~D[2026-11-10]) == nil
    end
  end

  describe "calibration" do
    test "none until two weeks have receipts, then the mean gap is added to the next estimate" do
      w1 = Date.add(@week, -14)
      w2 = Date.add(@week, -7)
      planned(w1, "1000")
      planned(w2, "1000")
      planned(@week, "1000")

      receipt(Date.add(w1, 3), "1100")
      assert Budget.adjustment(home_scope(), @week) == nil
      assert %{expected: expected} = Budget.status(home_scope(), @week)
      assert Decimal.eq?(expected, 1000)

      receipt(Date.add(w2, 3), "1300")
      assert Budget.adjustment(home_scope(), @week) == d("200.00")
      assert %{expected: expected} = Budget.status(home_scope(), @week)
      assert Decimal.eq?(expected, 1200)
    end

    test "a week still being shopped for doesn't count" do
      w1 = Date.add(@week, -14)
      w2 = Date.add(@week, -7)
      for w <- [w1, w2, @week], do: planned(w, "1000")

      receipt(Date.add(w1, 3), "1100")
      receipt(Date.add(w2, 3), "1300")
      receipt(Date.add(@week, 1), "200")

      next = Date.add(@week, 7)
      assert Budget.adjustment(home_scope(), next, Date.add(@week, 5)) == d("200.00")
      assert Budget.adjustment(home_scope(), next, next) == d("-133.33")
    end

    test "a weekend shop for the week doesn't price that week's own estimate" do
      {:ok, recipe} =
        Recipes.create(
          home_scope(),
          %{
            title: "Lax",
            base_servings: 4,
            ingredients: [%{name: "Lax", quantity: 1, unit: "kg"}]
          },
          image: false
        )

      salmon =
        Repo.get_by!(Tore.Recipes.Ingredient, [name: "Lax"], Tore.Scope.repo_opts(home_scope()))

      Tore.Prices.Products.put(home_scope(), "LAXFILE", salmon.id)

      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), @week),
          "mon_dinner",
          recipe.id,
          4
        )

      receipt(Date.add(@week, -2), "300", %{
        week_start: @week,
        line_items: [
          %{product_name: "LAXFILE", quantity: d("1"), unit: "kg", total_price: d("300")}
        ]
      })

      assert %{estimate: %{priced: 0}} = Budget.status(home_scope(), @week)
    end

    test "a week without a plan doesn't count" do
      w1 = Date.add(@week, -21)
      w2 = Date.add(@week, -14)
      planned(w1, "1000")
      planned(w2, "1000")

      receipt(Date.add(w1, 3), "1100")
      receipt(Date.add(w2, 3), "1100")
      receipt(Date.add(@week, -4), "2500")

      assert Budget.adjustment(home_scope(), @week) == d("100.00")
    end

    test "a week's estimate never learns from its own receipts" do
      {:ok, recipe} =
        Recipes.create(
          home_scope(),
          %{
            title: "Lax",
            base_servings: 4,
            ingredients: [%{name: "Lax", quantity: 1, unit: "kg"}]
          },
          image: false
        )

      salmon =
        Repo.get_by!(Tore.Recipes.Ingredient, [name: "Lax"], Tore.Scope.repo_opts(home_scope()))

      Tore.Prices.Products.put(home_scope(), "LAXFILE", salmon.id)

      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), @week),
          "mon_dinner",
          recipe.id,
          4
        )

      receipt(~D[2026-11-04], "300", %{
        line_items: [
          %{product_name: "LAXFILE", quantity: d("1"), unit: "kg", total_price: d("300")}
        ]
      })

      assert %{estimate: %{amount: amount, priced: 0}} = Budget.status(home_scope(), @week)
      assert Decimal.eq?(amount, 0)

      next_week = Date.add(@week, 7)

      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), next_week),
          "mon_dinner",
          recipe.id,
          4
        )

      assert %{estimate: %{amount: next, priced: 1}} = Budget.status(home_scope(), next_week)
      assert Decimal.eq?(next, 300)
    end
  end
end
