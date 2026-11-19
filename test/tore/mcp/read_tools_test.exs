defmodule Tore.Mcp.ReadToolsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Mcp, Planning, Recipes, Shop}

  # No expectations: any call to the model fails the test.
  setup :verify_on_exit!

  defp call(scope, name, args) do
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
        steps:
          Jason.encode!([
            %{"phase" => "KOK", "order" => 2, "action" => "Riv osten.", "ingredients" => ["Ost"]},
            %{"phase" => "KOK", "order" => 1, "action" => "Koka pastan.", "ingredients" => []}
          ]),
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
    assert context["week_mode"] == nil

    Tore.WeekMode.set_mode(scope, "low_effort")
    assert ok(scope, "get_context")["week_mode"] =~ "Low effort"
  end

  test "search_recipes finds by title or ingredient, and lists all without a query" do
    recipe("Pasta med ost")
    recipe("Laxsoppa", [%{name: "Lax", quantity: 400, unit: "g"}])

    assert %{"recipes" => [%{"title" => "Laxsoppa", "total_minutes" => 30}]} =
             ok(home_scope(), "search_recipes", %{"query" => "lax"})

    assert %{"recipes" => all} = ok(home_scope(), "search_recipes")
    assert length(all) == 2
  end

  test "get_recipe gives the recipe as save_recipe takes it, and refuses one that isn't there" do
    pasta = recipe("Pasta")

    assert %{
             "title" => "Pasta",
             "recipe_type" => "meal",
             "base_servings" => 4,
             "prep_time_minutes" => 10,
             "has_picture" => false,
             "ingredients" => [%{"item" => "Ost", "unit" => "st"}],
             "steps" => [%{"action" => "Koka pastan."}, %{"action" => "Riv osten."}]
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

  test "get_planning_history lists each day of the last six weeks and this one" do
    scope = home_scope()
    assert %{"days" => []} = ok(scope, "get_planning_history")

    pasta = recipe("Pasta")
    sauce = recipe("Köttfärssås")
    salmon = recipe("Lax")
    this_monday = Tore.Streams.monday(Tore.Clock.today())
    last_week = Tore.Streams.plan(scope, Date.add(this_monday, -7))
    this_week = Tore.Streams.plan(scope, this_monday)

    # Sunday's sauce eaten again on Monday, across the week boundary.
    {:ok, _} = Planning.assign_recipe(scope, last_week, "sun_dinner", sauce.id, 4)
    {:ok, _} = Planning.assign_recipe(scope, this_week, "mon_dinner", sauce.id, 4)

    :ok =
      Tore.EventStore.append(scope, this_week, [
        %Tore.Planning.Events.LeftoverMarked{slot_key: "mon_dinner"}
      ])

    # Salmon swapped for pasta; Thursday planned and then skipped.
    {:ok, _} = Planning.assign_recipe(scope, this_week, "tue_dinner", salmon.id, 4)
    {:ok, _} = Planning.assign_recipe(scope, this_week, "tue_dinner", pasta.id, 4)
    {:ok, _} = Planning.assign_recipe(scope, this_week, "thu_dinner", pasta.id, 4)
    {:ok, _} = Planning.skip_meal(scope, this_week, "thu_dinner")
    # Removed outright.
    {:ok, _} = Planning.assign_recipe(scope, this_week, "fri_dinner", salmon.id, 4)
    {:ok, _} = Planning.remove_recipe(scope, this_week, "fri_dinner")

    date = &Date.to_iso8601(Date.add(this_monday, &1))

    assert %{"days" => days} = ok(scope, "get_planning_history")

    assert days == [
             %{"date" => date.(-1), "slot" => "sun_dinner", "recipe" => "Köttfärssås"},
             %{
               "date" => date.(0),
               "slot" => "mon_dinner",
               "recipe" => "Köttfärssås",
               "leftovers" => true
             },
             %{
               "date" => date.(1),
               "slot" => "tue_dinner",
               "recipe" => "Pasta",
               "swapped_out" => ["Lax"]
             },
             %{
               "date" => date.(3),
               "slot" => "thu_dinner",
               "recipe" => "Pasta",
               "skipped" => true
             },
             %{"date" => date.(4), "slot" => "fri_dinner", "swapped_out" => ["Lax"]}
           ]

    other = Tore.AccountsFixtures.household_fixture() |> Tore.AccountsFixtures.scope_fixture()
    assert %{"days" => []} = ok(other, "get_planning_history")
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
