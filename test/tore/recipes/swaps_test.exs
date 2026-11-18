defmodule Tore.Recipes.SwapsTest do
  use Tore.DataCase, async: true
  import Mox
  alias Tore.Recipes
  alias Tore.Recipes.Swaps

  setup :verify_on_exit!

  setup do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{
          title: "Kycklinggryta",
          recipe_type: :meal,
          ingredients: [%{name: "gul lök"}, %{name: "crème fraîche"}, %{name: "timjan"}]
        },
        image: false
      )

    {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "oregano"})
    %{recipe: Recipes.get!(home_scope(), recipe.id)}
  end

  test "asks once for every missing thing, with what they have and the pantry", %{recipe: recipe} do
    expect(Tore.MockLLM, :text, fn _system, user, _opts ->
      sent = Jason.decode!(user)
      assert sent["missing"] == ["gul lök", "crème fraîche", "timjan"]
      assert sent["they_have"] == "rödlök, gräddfil"
      assert "oregano" in sent["pantry"]

      {:ok,
       %{
         "swaps" => [
           %{"for" => "Crème fraîche", "use" => "gräddfil", "note" => "Rör ner på låg värme."},
           %{"for" => "gul lök", "use" => "rödlök", "note" => nil},
           %{"for" => "timjan", "use" => "oregano", "note" => "Halva mängden."},
           %{"for" => "grädde", "use" => "mjölk", "note" => nil}
         ]
       }, %{}}
    end)

    assert {:ok,
            [
              %{for: "gul lök", use: "rödlök", note: nil, at_home: false},
              %{for: "crème fraîche", use: "gräddfil", note: "Rör ner på låg värme."},
              %{for: "timjan", use: "oregano", at_home: true}
            ]} =
             Swaps.check(
               home_scope(),
               recipe,
               ["gul lök", "crème fraîche", "timjan"],
               " rödlök, gräddfil "
             )
  end

  test "a missing thing the model passed over has no swap, and nothing is saved", %{
    recipe: recipe
  } do
    expect(Tore.MockLLM, :text, fn _s, _u, _o -> {:ok, %{"swaps" => []}, %{}} end)
    before = Tore.Pantry.list_inventory(home_scope())

    assert {:ok, [%{for: "timjan", use: nil, note: nil, at_home: false}]} =
             Swaps.check(home_scope(), recipe, ["timjan"], "rödlök")

    assert Tore.Pantry.list_inventory(home_scope()) == before
  end

  test "says so when the model can't be reached", %{recipe: recipe} do
    expect(Tore.MockLLM, :text, fn _s, _u, _o -> {:error, :timeout} end)
    assert {:error, :timeout} = Swaps.check(home_scope(), recipe, ["timjan"], "")
  end
end
