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
end
