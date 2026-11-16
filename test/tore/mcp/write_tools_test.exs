defmodule Tore.Mcp.WriteToolsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Mcp, Pantry, Planning, Recipes, Shop, Streams}
  alias Tore.Harness.{KitchenRun, Runs}

  # No expectations: any call to the model fails the test.
  setup :verify_on_exit!

  setup do
    %{scope: home_scope()}
  end

  defp monday, do: Streams.monday(Tore.Clock.today())
  defp day(n), do: monday() |> Date.add(n) |> Date.to_iso8601()

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

  defp ok(scope, name, args) do
    assert %{"isError" => false, "structuredContent" => content} = call(scope, name, args)
    content |> Jason.encode!() |> Jason.decode!()
  end

  defp by_mcp!(scope, %{"run_id" => id}) do
    assert %KitchenRun{actor: :mcp, status: :applied} = Runs.get(scope, id)
    id
  end

  defp recipe(title) do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: title,
        recipe_type: :meal,
        ingredients: [%{name: "Ost", quantity: 1, unit: "st"}]
      })

    recipe
  end

  defp plan(scope), do: Streams.plan(scope, monday())
  defp list_id(scope), do: Streams.shop_list(scope, monday())

  defp slot(scope, key) do
    {:ok, state} = Planning.load_plan(scope, plan(scope))
    state.slots[key]
  end

  defp list(scope) do
    {:ok, state} = Shop.load_list(scope, list_id(scope))
    state.items |> Map.values() |> Enum.map(&{&1.name, &1.checked}) |> Enum.sort()
  end

  test "tools/list names the write tools" do
    {:reply, %{"result" => %{"tools" => tools}}} =
      Mcp.handle(home_scope(), %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    names = Enum.map(tools, & &1["name"])

    for name <-
          ~w(set_dinner change_day add_to_list check_off remove_from_list make_list add_to_pantry remove_from_pantry update_memory mark_cooked delete_recipe delete_receipt undo),
        do: assert(name in names, name)
  end

  test "set_dinner puts a recipe on a day as an MCP run, and undo takes it off", %{scope: scope} do
    pasta = recipe("Pasta")

    result =
      ok(scope, "set_dinner", %{"date" => day(2), "recipe_id" => pasta.id, "servings" => 2})

    assert result["done"] =~ "Pasta"
    run_id = by_mcp!(scope, result)
    assert %{recipe_id: id, servings: 2} = slot(scope, "wed_dinner")
    assert id == pasta.id

    assert %{"done" => _} = ok(scope, "undo", %{"run_id" => run_id})
    assert slot(scope, "wed_dinner") == nil
  end

  test "a pinned day stays as it is", %{scope: scope} do
    pasta = recipe("Pasta")
    soup = recipe("Soppa")
    {:ok, _} = Planning.assign_recipe(scope, plan(scope), "wed_dinner", soup.id, 4)
    by_mcp!(scope, ok(scope, "change_day", %{"date" => day(2), "action" => "pin"}))

    result = ok(scope, "set_dinner", %{"date" => day(2), "recipe_id" => pasta.id})
    assert result["run_id"] == nil
    assert result["done"] =~ "pin"
    assert slot(scope, "wed_dinner").recipe_id == soup.id
  end

  test "change_day skips, sets servings, eats out and clears", %{scope: scope} do
    pasta = recipe("Pasta")
    {:ok, _} = Planning.assign_recipe(scope, plan(scope), "thu_dinner", pasta.id, 4)

    by_mcp!(
      scope,
      ok(scope, "change_day", %{"date" => day(3), "action" => "servings", "servings" => 6})
    )

    assert slot(scope, "thu_dinner").servings == 6

    by_mcp!(scope, ok(scope, "change_day", %{"date" => day(3), "action" => "skip"}))
    assert slot(scope, "thu_dinner").skipped

    by_mcp!(scope, ok(scope, "change_day", %{"date" => day(3), "action" => "clear"}))
    assert slot(scope, "thu_dinner") == nil

    by_mcp!(
      scope,
      ok(scope, "change_day", %{"date" => day(4), "action" => "eat_out", "place" => "Pizzerian"})
    )

    assert slot(scope, "fri_dinner").reason == "eating_out"
  end

  test "the list: add several, tick one, remove one", %{scope: scope} do
    result =
      ok(scope, "add_to_list", %{
        "items" => [
          %{"name" => "Mjölk", "quantity" => 2, "unit" => "l"},
          %{"name" => "Bröd"},
          %{"name" => "Smör"}
        ]
      })

    assert [%{"run_id" => _} = first | _] = result["added"]
    by_mcp!(scope, first)
    assert list(scope) == [{"Bröd", false}, {"Mjölk", false}, {"Smör", false}]

    by_mcp!(scope, ok(scope, "check_off", %{"name" => "mjölk"}))
    assert {"Mjölk", true} in list(scope)

    assert %{"done" => _} = ok(scope, "remove_from_list", %{"name" => "Smör"})
    refute Enum.any?(list(scope), &match?({"Smör", _}, &1))
  end

  test "make_list builds the week's list from the plan", %{scope: scope} do
    pasta = recipe("Pasta")
    {:ok, _} = Planning.assign_recipe(scope, plan(scope), "mon_dinner", pasta.id, 4)

    # Building replaces the list, so, as in Capture, it offers no undo.
    assert %{"done" => _, "run_id" => nil} = ok(scope, "make_list", %{})
    assert list(scope) == [{"Ost", false}]
  end

  test "the pantry: add and remove by name", %{scope: scope} do
    by_mcp!(
      scope,
      ok(scope, "add_to_pantry", %{"name" => "ägg", "quantity" => 12, "unit" => "st"})
    )

    assert [%{name: "ägg"}] = Pantry.list_inventory(scope)

    by_mcp!(scope, ok(scope, "remove_from_pantry", %{"name" => "ägg"}))
    assert Pantry.list_inventory(scope) == []
  end

  test "update_memory keeps a note, and a refused one says why", %{scope: scope} do
    result =
      ok(scope, "update_memory", %{
        "target" => "notes",
        "operations" => [%{"action" => "add", "content" => "Fisk på fredagar"}]
      })

    run_id = by_mcp!(scope, result)
    assert Tore.Household.Memory.snapshot(scope) =~ "Fisk på fredagar"
    ok(scope, "undo", %{"run_id" => run_id})
    refute (Tore.Household.Memory.snapshot(scope) || "") =~ "Fisk på fredagar"

    assert %{"isError" => true} =
             call(scope, "update_memory", %{
               "target" => "notes",
               "operations" => [
                 %{"action" => "patch", "old_text" => "inget sådant", "content" => "x"}
               ]
             })
  end

  test "mark_cooked, delete_recipe and delete_receipt", %{scope: scope} do
    pasta = recipe("Pasta")
    assert %{"done" => _} = ok(scope, "mark_cooked", %{"recipe_id" => pasta.id})
    assert Recipes.get(scope, pasta.id).last_used_at

    assert %{"done" => _} = ok(scope, "delete_recipe", %{"recipe_id" => pasta.id})
    assert Recipes.get(scope, pasta.id) == nil

    {:ok, receipt} =
      Costs.log_receipt(scope, %{
        date: Tore.Clock.today(),
        total_amount: "99",
        store_name: "ICA",
        user_id: user_fixture().id
      })

    assert %{"done" => _} = ok(scope, "delete_receipt", %{"receipt_id" => receipt.id})
    assert Costs.recent_receipts(scope, 5) == []
  end

  test "arguments a tool can't use come back as errors Claude can read", %{scope: scope} do
    for {name, args} <- [
          {"set_dinner", %{"date" => "on wednesday", "recipe_id" => 1}},
          {"set_dinner", %{"date" => day(2)}},
          {"change_day", %{"date" => day(2), "action" => "fly"}},
          {"change_day", %{"date" => day(2), "action" => "servings"}},
          {"add_to_list", %{"items" => []}},
          {"undo", %{"run_id" => "no-such-run"}},
          {"delete_recipe", %{"recipe_id" => "pasta"}}
        ] do
      assert %{"isError" => true, "content" => [%{"text" => text}]} = call(scope, name, args),
             "#{name} #{inspect(args)} was not refused"

      assert text != ""
    end
  end
end
