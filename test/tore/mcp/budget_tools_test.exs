defmodule Tore.Mcp.BudgetToolsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Basics, Budget, Deals, Mcp, Streams}
  alias Tore.Recipes.Ingredient

  # No expectations: any call to the model fails the test.
  setup :verify_on_exit!

  defp call(name, args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    {:reply, %{"result" => result}} = Mcp.handle(home_scope(), request)
    result
  end

  defp ok(name, args \\ %{}) do
    assert %{"isError" => false, "structuredContent" => content} = call(name, args)
    content |> Jason.encode!() |> Jason.decode!()
  end

  defp monday, do: Streams.monday(Tore.Clock.today())

  test "set_budget sets the usual budget, or one week's, and get_context shows it" do
    ok("set_budget", %{"amount" => 2000})

    ok("set_budget", %{
      "amount" => 1500,
      "week_of" => monday() |> Date.add(9) |> Date.to_iso8601()
    })

    assert Decimal.eq?(Budget.amount(home_scope(), monday()), 2000)

    assert %{
             "budget" => %{"this_week" => %{"budget" => this}, "next_week" => %{"budget" => next}}
           } =
             ok("get_context")

    assert {this, next} == {"2000", "1500"}

    assert %{"isError" => true} = call("set_budget", %{"amount" => -5})
  end

  test "set_basics adds basics, get_context lists them, and stop takes one off" do
    ok("set_basics", %{
      "items" => [%{"name" => "Mjölk", "quantity" => 3, "unit" => "l"}, %{"name" => "Kaffe"}]
    })

    assert %{"basics" => ["Kaffe", "Mjölk"]} = ok("get_context")

    ok("set_basics", %{"items" => [%{"name" => "Kaffe"}], "stop" => true})
    assert ["Mjölk"] = Enum.map(Basics.list(home_scope()), & &1.name)
  end

  test "match_deals ties offers to ingredients, so list_deals shows them matched" do
    store = Repo.insert!(%Tore.Deals.Store{name: "ICA Maxi", url: "https://example.test/maxi"})

    Repo.insert!(%Tore.Deals.HouseholdStore{
      household_id: home_scope().household_id,
      store_id: store.id
    })

    Deals.upsert_deals([
      %{
        chain: "ica",
        store: "ICA Maxi",
        product_name: "Kycklingfilé Kronfågel",
        price: Decimal.new(59)
      },
      %{chain: "ica", store: "ICA Maxi", product_name: "Pizza Grandiosa", price: Decimal.new(35)}
    ])

    Repo.insert!(%Ingredient{
      household_id: home_scope().household_id,
      name: "Kycklingfilé",
      key: Ingredient.to_key("Kycklingfilé")
    })

    assert %{"deals" => deals} = ok("list_deals")
    assert Enum.all?(deals, &(&1["matched"] == false and &1["ingredient"] == nil))

    assert %{"matched" => 1, "none" => 1, "unknown_ingredients" => ["Tofu"]} =
             ok("match_deals", %{
               "matches" => [
                 %{"product" => "Kycklingfilé Kronfågel", "ingredient" => "kycklingfilé"},
                 %{"product" => "Pizza Grandiosa", "ingredient" => nil},
                 %{"product" => "Pizza Grandiosa", "ingredient" => "Tofu"}
               ]
             })

    assert %{"deals" => deals} = ok("list_deals")
    by_product = Map.new(deals, &{&1["product"], {&1["ingredient"], &1["matched"]}})
    assert by_product["Kycklingfilé Kronfågel"] == {"Kycklingfilé", true}
    assert by_product["Pizza Grandiosa"] == {nil, true}
  end

  describe "what_if" do
    setup do
      stew = Tore.BudgetFixtures.priced_recipe(home_scope(), "Gryta", "100")
      feast = Tore.BudgetFixtures.priced_recipe(home_scope(), "Fest", "300")
      Tore.BudgetFixtures.one_dinner(home_scope(), monday(), stew)

      {:ok, _} =
        Tore.Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), monday()),
          "tue_dinner",
          stew.id,
          4
        )

      :ok = Budget.set_week(home_scope(), monday(), Decimal.new(250))
      %{stew: stew, feast: feast}
    end

    test "says what the week would cost with a changed plan, and changes nothing", %{
      feast: feast
    } do
      friday = monday() |> Date.add(4) |> Date.to_iso8601()

      assert %{"budget" => "250", "now" => now, "then" => then, "difference" => difference} =
               ok("what_if", %{
                 "changes" => [%{"date" => friday, "recipe_id" => feast.id, "servings" => 4}]
               })

      # Friday was eaten out; with the feast the week costs 300 kr more.
      assert {now["expected"], then["expected"], difference} == {"200.00", "500.00", "300.00"}
      assert then["over_budget"] == "250.00"

      {:ok, plan} = Tore.Planning.load_plan(home_scope(), Streams.plan(home_scope(), monday()))
      assert plan.slots["fri_dinner"][:reason] == "eating_out"
    end

    test "can clear a day, which then counts as an open day" do
      tuesday = monday() |> Date.add(1) |> Date.to_iso8601()

      %{"now" => now, "then" => then} =
        ok("what_if", %{"changes" => [%{"date" => tuesday, "recipe_id" => nil}]})

      # Tuesday open costs a typical dinner, the stew's 100 kr, so the week costs the same.
      assert {now["open_days"], then["open_days"]} == {0, 1}
      assert then["expected"] == now["expected"]
    end

    test "refuses a recipe the household doesn't have, or changes in two weeks" do
      today = Date.to_iso8601(monday())
      later = monday() |> Date.add(7) |> Date.to_iso8601()

      assert %{"isError" => true} =
               call("what_if", %{"changes" => [%{"date" => today, "recipe_id" => 999_999}]})

      assert %{"isError" => true} =
               call("what_if", %{
                 "changes" => [
                   %{"date" => today, "recipe_id" => nil},
                   %{"date" => later, "recipe_id" => nil}
                 ]
               })
    end
  end
end
