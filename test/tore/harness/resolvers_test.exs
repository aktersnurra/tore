defmodule Tore.Harness.ResolversTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Harness.Resolvers
  alias Tore.Harness.Handles.ResolvedRecipe
  alias Tore.Recipes

  setup :set_mox_from_context

  setup do
    # Recipes.create/1 fires an async Task that calls Tore.LLM.text to write
    # an image-gen prompt; stub it so the fire-and-forget task doesn't crash
    # under Mox's ownership checks.
    stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"prompt" => "A plate of food."}, %{}}
    end)

    {:ok, _} =
      Recipes.create(home_scope(), %{title: "Salmon pasta", base_servings: 2, instructions: "x"})

    {:ok, _} =
      Recipes.create(home_scope(), %{title: "Salmon soup", base_servings: 2, instructions: "x"})

    {:ok, _} =
      Recipes.create(home_scope(), %{
        title: "Chicken skewers",
        base_servings: 2,
        instructions: "x"
      })

    :ok
  end

  test "exact-ish title resolves with high confidence" do
    assert {:ok, %ResolvedRecipe{label: "Chicken skewers", source: :resolve_recipe} = h} =
             Resolvers.resolve_recipe(home_scope(), "chicken skewers")

    assert h.confidence > 0.9
  end

  test "shared prefix is ambiguous" do
    assert {:ambiguous, handles} = Resolvers.resolve_recipe(home_scope(), "salmon")
    assert length(handles) == 2
    assert Enum.all?(handles, &match?(%ResolvedRecipe{}, &1))
  end

  test "garbage is not found" do
    assert :not_found = Resolvers.resolve_recipe(home_scope(), "zzzz qqqq")
  end

  describe "resolve_slot/2" do
    # slots: %{slot_key => recipe title or nil}
    @slots %{
      "mon_dinner" => "Salmon pasta",
      "tue_dinner" => nil,
      "wed_dinner" => "Chicken skewers"
    }

    test "day words resolve structurally" do
      assert {:ok, %{slot_key: "mon_dinner", label: "Monday dinner"}} =
               Resolvers.resolve_slot("monday", slots: @slots, today: ~D[2026-07-15])

      assert {:ok, %{slot_key: "tue_dinner"}} =
               Resolvers.resolve_slot("Tuesday", slots: @slots, today: ~D[2026-07-15])
    end

    test "tonight/today and tomorrow resolve relative to today" do
      # 2026-07-15 is a Wednesday
      assert {:ok, %{slot_key: "wed_dinner"}} =
               Resolvers.resolve_slot("tonight", slots: @slots, today: ~D[2026-07-15])

      assert {:ok, %{slot_key: "thu_dinner"}} =
               Resolvers.resolve_slot("tomorrow", slots: @slots, today: ~D[2026-07-15])
    end

    test "a recipe reference resolves to the slot holding it" do
      assert {:ok, %{slot_key: "wed_dinner"}} =
               Resolvers.resolve_slot("the chicken skewers slot",
                 slots: @slots,
                 today: ~D[2026-07-15]
               )
    end

    test "a reference matching multiple assigned recipes is ambiguous" do
      slots = Map.put(@slots, "fri_dinner", "Salmon soup")

      assert {:ambiguous, candidates} =
               Resolvers.resolve_slot("the salmon dinner", slots: slots, today: ~D[2026-07-15])

      assert Enum.map(candidates, & &1.slot_key) |> Enum.sort() == ["fri_dinner", "mon_dinner"]
    end

    test "garbage is not found" do
      assert :not_found =
               Resolvers.resolve_slot("xyzzy plugh", slots: @slots, today: ~D[2026-07-15])
    end
  end
end
