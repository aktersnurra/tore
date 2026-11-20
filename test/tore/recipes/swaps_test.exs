defmodule Tore.Recipes.SwapsTest do
  @moduledoc "pi's swaps before cooking: suggest_swaps reads them, and the sheet lines them up."
  use Tore.DataCase, async: true

  alias Tore.{Mcp, Recipes}
  alias Tore.Recipes.Swaps

  setup do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Kycklinggryta",
        recipe_type: :meal,
        ingredients: [%{name: "gul lök"}, %{name: "crème fraîche"}, %{name: "timjan"}]
      })

    {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "oregano"})
    %{recipe: recipe}
  end

  defp call(args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "suggest_swaps", "arguments" => args}
    }

    {:reply, %{"result" => result}} = Mcp.handle(home_scope(), request)
    result
  end

  test "suggest_swaps says which swaps are at home, and saves nothing", %{recipe: recipe} do
    before = Tore.Pantry.list_inventory(home_scope())

    swaps = [
      %{"for" => " Crème fraîche ", "use" => "gräddfil", "note" => "Rör ner på låg värme."},
      %{"for" => "timjan", "use" => "oregano", "note" => " "},
      %{"for" => "", "use" => "mjölk"}
    ]

    assert %{"isError" => false, "structuredContent" => content} =
             call(%{"recipe_id" => recipe.id, "swaps" => swaps})

    assert [
             %{
               for: "Crème fraîche",
               use: "gräddfil",
               note: "Rör ner på låg värme.",
               at_home: false
             },
             %{for: "timjan", use: "oregano", note: nil, at_home: true}
           ] = content.swaps

    assert Tore.Pantry.list_inventory(home_scope()) == before
    assert %{"isError" => true} = call(%{"recipe_id" => 0, "swaps" => swaps})
  end

  test "the sheet gets a swap per missing thing, in its order, from a tool's result" do
    from_result = [
      %{"for" => "Crème fraîche", "use" => "gräddfil", "note" => nil, "at_home" => false},
      %{"for" => "grädde", "use" => "mjölk", "note" => nil, "at_home" => true}
    ]

    assert [
             %{for: "gul lök", use: nil, note: nil, at_home: false},
             %{for: "crème fraîche", use: "gräddfil", at_home: false}
           ] = Swaps.for_missing(["gul lök", "crème fraîche"], from_result)
  end
end
