defmodule Tore.Harness.Artifact.RecipeProposalTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.Artifact
  alias Tore.Harness.Artifact.RecipeProposal

  defp proposal(overrides \\ %{}) do
    base = %RecipeProposal{
      title: "Miso Ramen",
      description: "A quick weeknight ramen.",
      instructions: "Simmer the broth. Cook the noodles. Assemble.",
      base_servings: 4,
      prep_time_minutes: 10,
      cook_time_minutes: 20,
      ingredients: [
        %{name: "miso paste", quantity: "2", unit: "msk"},
        %{name: "ramen noodles", quantity: "4", unit: "portioner"}
      ],
      tags: ["japanese", "quick"],
      source: :generation,
      source_url: nil,
      source_recipe_id: 7,
      instruction: "make it simpler",
      pending_assignment: %{slot_key: "mon_dinner", servings: 4}
    }

    struct!(base, overrides)
  end

  test "kind/0 is the registered string" do
    assert RecipeProposal.kind() == "RecipeProposal"
  end

  test "round-trips through to_json/from_json" do
    original = proposal()
    round_tripped = RecipeProposal.from_json(RecipeProposal.to_json(original))

    assert round_tripped == original
  end

  test "round-trips a web_import proposal" do
    original =
      proposal(%{
        source: :web_import,
        source_url: "https://example.com/ramen",
        source_recipe_id: nil,
        instruction: nil,
        pending_assignment: nil
      })

    assert RecipeProposal.from_json(RecipeProposal.to_json(original)) == original
  end

  test "round-trips a nil pending_assignment" do
    original = proposal(%{pending_assignment: nil})

    assert RecipeProposal.from_json(RecipeProposal.to_json(original)) == original
  end

  test "Artifact.to_json/1 stamps __kind__" do
    assert %{"__kind__" => "RecipeProposal"} = Artifact.to_json(proposal())
  end

  test "the registry resolves the kind to the module" do
    assert Tore.Harness.Artifact.Registry.lookup("RecipeProposal") == {:ok, RecipeProposal}
  end
end
