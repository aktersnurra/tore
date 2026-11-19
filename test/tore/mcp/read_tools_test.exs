defmodule Tore.Mcp.ReadToolsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Mcp, Planning, Recipes, Shop}

  # No expectations: any call to the model fails the test.
  setup :verify_on_exit!

  defp call(scope, name, args \\ %{}) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    {:reply, %{"result" => result}} = Mcp.handle(scope, request)
    result
  end

  defp ok(scope, name, args \\ %{}) do
    %{"isError" => false, "structuredContent" => content} = call(scope, name, args)
    content |> Jason.encode!() |> Jason.decode!()
  end

  defp recipe(title, ingredients \\ [%{name: "Ost", quantity: 1, unit: "st"}]) do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: title,
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 20,
        steps: Jason.encode!(["Koka pastan.", "Riv osten."]),
        ingredients: ingredients
      })

    recipe
  end

  test "tools/list names the read tools with their schemas" do
    {:reply, %{"result" => %{"tools" => tools}}} =
      Mcp.handle(home_scope(), %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    names = Enum.map(tools, & &1["name"])

    for name <- ~w(get_context search_recipes get_recipe list_receipts list_deals),
        do: assert(name in names)

    assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
  end

  test "get_context gives the language, today, the plan, the list and the pantry" do
    scope = home_scope()
    pasta = recipe("Pasta")
    today = Tore.Clock.today()
    monday = Tore.Streams.monday(today)

    {:ok, _} =
      Planning.assign_recipe(scope, Tore.Streams.plan(scope, monday), "mon_dinner", pasta.id, 4)

    {:ok, _} = Shop.add_item(scope, Tore.Streams.shop_list(scope, monday), "Mjölk", nil, nil, nil)
    {:ok, _} = Tore.Pantry.add_item(scope, %{name: "ägg", expires_at: Date.add(today, 1)})

    context = ok(scope, "get_context")

    assert context["language"] == "sv"
    assert context["today"] == Date.to_iso8601(today)

    assert %{"date" => _, "status" => "assigned", "recipe_id" => id, "recipe_title" => "Pasta"} =
             hd(context["this_week"])

    assert id == pasta.id

    assert %{"lunch_day" => true, "lunch" => nil, "day_off" => false} =
             Enum.at(context["this_week"], 6)

    assert length(context["next_week"]) == 7
    assert [%{"name" => "Mjölk", "checked" => false}] = context["shopping_list"]
    assert [%{"name" => "ägg", "expires_on" => _}] = context["pantry"]
    assert "next week has no dinners planned" in context["due"]
    assert Enum.any?(context["due"], &(&1 =~ "ägg"))
  end

  test "search_recipes finds by title or ingredient, and lists all without a query" do
    recipe("Pasta med ost")
    recipe("Laxsoppa", [%{name: "Lax", quantity: 400, unit: "g"}])

    assert %{"recipes" => [%{"title" => "Laxsoppa", "total_minutes" => 30}]} =
             ok(home_scope(), "search_recipes", %{"query" => "lax"})

    assert %{"recipes" => all} = ok(home_scope(), "search_recipes")
    assert length(all) == 2
  end

  test "get_recipe gives ingredients and steps, and refuses a recipe that isn't there" do
    pasta = recipe("Pasta")

    assert %{
             "title" => "Pasta",
             "servings" => 4,
             "ingredients" => [%{"name" => "Ost", "unit" => "st"}],
             "steps" => ["Koka pastan.", "Riv osten."]
           } = ok(home_scope(), "get_recipe", %{"recipe_id" => pasta.id})

    assert %{"isError" => true} = call(home_scope(), "get_recipe", %{"recipe_id" => 0})
    assert %{"isError" => true} = call(home_scope(), "get_recipe", %{"recipe_id" => "pasta"})
  end

  test "list_receipts gives the latest receipts" do
    {:ok, _} =
      Costs.log_receipt(home_scope(), %{
        date: ~D[2026-11-10],
        total_amount: "312.50",
        store_name: "ICA",
        user_id: user_fixture().id
      })

    assert %{"receipts" => [%{"store" => "ICA", "date" => "2026-11-10"}]} =
             ok(home_scope(), "list_receipts")
  end

  test "get_planning_history gives the last six weeks the memory review reads" do
    scope = home_scope()
    assert %{"history" => nil} = ok(scope, "get_planning_history")

    pasta = recipe("Pasta")
    plan = Tore.Streams.plan(scope, Tore.Streams.monday(Tore.Clock.today()))
    {:ok, _} = Planning.assign_recipe(scope, plan, "mon_dinner", pasta.id, 4)
    {:ok, _} = Planning.remove_recipe(scope, plan, "mon_dinner")
    {:ok, _} = Planning.assign_recipe(scope, plan, "thu_dinner", pasta.id, 4)
    {:ok, _} = Planning.skip_meal(scope, plan, "thu_dinner")

    %{"history" => history} = ok(scope, "get_planning_history")

    assert history =~ "2 meals planned, 1 skipped"
    assert history =~ "Skip-heavy days: thu (1)"
    assert history =~ "Pasta"

    other = Tore.AccountsFixtures.household_fixture() |> Tore.AccountsFixtures.scope_fixture()
    assert %{"history" => nil} = ok(other, "get_planning_history")
  end

  test "list_deals answers with the household's current deals" do
    assert %{"deals" => []} = ok(home_scope(), "list_deals")
  end

  test "another household sees none of this household's recipes" do
    pasta = recipe("Pasta")
    other = Tore.AccountsFixtures.household_fixture() |> Tore.AccountsFixtures.scope_fixture()

    assert %{"recipes" => []} = ok(other, "search_recipes")
    assert %{"isError" => true} = call(other, "get_recipe", %{"recipe_id" => pasta.id})
  end

  test "an unknown tool is a JSON-RPC error" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "launch", "arguments" => %{}}
    }

    assert {:reply, %{"error" => %{"code" => -32602}}} = Mcp.handle(home_scope(), request)
  end
end
