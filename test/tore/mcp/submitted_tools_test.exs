defmodule Tore.Mcp.SubmittedToolsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Mcp, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}

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

  defp ok(scope, name, args) do
    assert %{"isError" => false, "structuredContent" => content} = call(scope, name, args)
    content |> Jason.encode!() |> Jason.decode!()
  end

  @recipe %{
    "title" => "Laxpasta",
    "base_servings" => 4,
    "prep_time_minutes" => 10,
    "cook_time_minutes" => 15,
    "ingredients" => [
      %{"item" => "Lax", "quantity" => 400, "unit" => "g"},
      %{"item" => "Pasta", "quantity" => 500, "unit" => "g"},
      %{"item" => "Citron"}
    ],
    "steps" => [
      %{"phase" => "PASTA", "order" => 1, "action" => "Koka pastan.", "duration_minutes" => 10},
      %{"phase" => "LAX", "order" => 2, "action" => "Stek laxen."},
      %{"phase" => "LAX", "order" => 3, "action" => "Blanda med citron."}
    ],
    "source_url" => "https://example.com/laxpasta"
  }

  test "save_recipe saves what Claude read, as an MCP run, and undo deletes it" do
    scope = home_scope()
    result = ok(scope, "save_recipe", @recipe)

    assert %KitchenRun{actor: :mcp, status: :applied} = Runs.get(scope, result["run_id"])
    recipe_id = result["recipe_id"]

    recipe = scope |> Recipes.get(recipe_id) |> Repo.preload(recipe_ingredients: :ingredient)
    assert recipe.title == "Laxpasta"
    assert recipe.base_servings == 4
    assert recipe.source_url == "https://example.com/laxpasta"

    assert recipe |> Recipes.Recipe.decode_steps() |> Enum.map(& &1["action"]) ==
             ["Koka pastan.", "Stek laxen.", "Blanda med citron."]

    assert recipe.instructions =~ "Stek laxen."

    assert recipe.recipe_ingredients |> Enum.map(& &1.ingredient.name) |> Enum.sort() == [
             "Citron",
             "Lax",
             "Pasta"
           ]

    ok(scope, "undo", %{"run_id" => result["run_id"]})
    assert Recipes.get(scope, recipe_id) == nil
  end

  test "a recipe without a title or ingredients is refused" do
    assert %{"isError" => true} = call(home_scope(), "save_recipe", Map.delete(@recipe, "title"))

    assert %{"isError" => true} =
             call(home_scope(), "save_recipe", %{@recipe | "ingredients" => []})
  end

  test "log_receipt logs what Claude read, as an MCP run, and undo deletes it" do
    # Over MCP the scope always names the person, who the receipt is logged for.
    scope = %{home_scope() | user_id: user_fixture().id}

    result =
      ok(scope, "log_receipt", %{
        "store" => "ICA Supermarket",
        "date" => Date.to_iso8601(Tore.Clock.today()),
        "total" => 312.5,
        "lines" => [
          %{"name" => "MJÖLK 1.5L", "quantity" => 2, "section" => "dairy"},
          %{"name" => "Bröd"}
        ]
      })

    assert %KitchenRun{actor: :mcp, status: :applied} = Runs.get(scope, result["run_id"])

    # The section Claude gave is kept; a line without one is Other until it's moved.
    [receipt] = Costs.recent_receipts(scope, 5)

    assert receipt
           |> Tore.Repo.preload(:line_items)
           |> Map.fetch!(:line_items)
           |> Enum.map(&{&1.product_name, &1.category})
           |> Enum.sort() ==
             [{"Bröd", "other"}, {"MJÖLK 1.5L", "dairy"}]

    assert [%{store_name: "ICA Supermarket", total_amount: total}] =
             Costs.recent_receipts(scope, 5)

    assert Decimal.equal?(total, Decimal.new("312.5"))

    ok(scope, "undo", %{"run_id" => result["run_id"]})
    assert Costs.recent_receipts(scope, 5) == []
  end

  test "a receipt from the future, or without a total, is refused and says why" do
    tomorrow = Tore.Clock.today() |> Date.add(1) |> Date.to_iso8601()

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             call(home_scope(), "log_receipt", %{
               "store" => "ICA",
               "date" => tomorrow,
               "total" => 10
             })

    assert text =~ "date_in_future"

    assert %{"isError" => true} =
             call(home_scope(), "log_receipt", %{"store" => "ICA", "date" => "2026-11-01"})

    assert Costs.recent_receipts(home_scope(), 5) == []
  end
end
