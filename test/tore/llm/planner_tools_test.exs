defmodule Tore.LLM.PlannerToolsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.LLM.PlannerTools
  alias Tore.Planning.{Decider, State, Events}

  @week_start ~D[2026-06-01]

  setup :set_mox_from_context

  setup do
    # Recipes.create/1 fires an async Task that calls Tore.LLM.text to write
    # an image-gen prompt; stub it so the fire-and-forget task doesn't crash
    # under Mox's ownership checks.
    stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"prompt" => "A plate of food."}, %{}}
    end)

    %{ctx: %{plan_id: "plan:test", week_start: @week_start}}
  end

  defp make_recipe(attrs \\ %{}) do
    base = %{
      title: "Recipe #{System.unique_integer([:positive])}",
      base_servings: 2,
      instructions: "x"
    }

    {:ok, r} = Tore.Recipes.create(Map.merge(base, attrs))
    r
  end

  defp find(name), do: Enum.find(PlannerTools.all(), &(&1.name == name))

  defp with_slot(state, slot, rid),
    do: Decider.evolve(state, %Events.RecipeAssigned{slot_key: slot, recipe_id: rid, servings: 2})

  test "assign_recipe proposes a RecipeAssigned event and evolves the plan", %{ctx: ctx} do
    %{id: rid} = make_recipe(%{title: "Test Salmon"})
    tool = find("assign_recipe")

    args = %{
      "slot_key" => "mon_dinner",
      "recipe_id" => rid,
      "servings" => 2,
      "rationale" => "good protein"
    }

    assert {:ok, %{ok: true}, events, next} = tool.run.(args, ctx, %State{})
    assert [%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: ^rid, servings: 2}] = events
    assert %{recipe_id: ^rid, servings: 2} = next.slots["mon_dinner"]
  end

  test "assign_recipe returns the recipe title as label", %{ctx: ctx} do
    %{id: rid} = make_recipe(%{title: "Roast chicken"})
    tool = find("assign_recipe")

    args = %{
      "slot_key" => "mon_dinner",
      "recipe_id" => rid,
      "servings" => 4,
      "rationale" => "easy"
    }

    assert {:ok, %{ok: true, label: "Roast chicken"}, _events, _next} =
             tool.run.(args, ctx, %State{})
  end

  test "skip_meal on an occupied slot proposes MealSkipped", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "tue_dinner", rid)
    tool = find("skip_meal")

    assert {:ok, %{ok: true}, [%Events.MealSkipped{slot_key: "tue_dinner"}], next} =
             tool.run.(%{"slot_key" => "tue_dinner", "rationale" => "out"}, ctx, state)

    assert next.slots["tue_dinner"].skipped == true
  end

  describe "a day marked as eating out" do
    setup do
      plan =
        Decider.evolve(%State{}, %Events.MealSkipped{slot_key: "tue_dinner", reason: "eating_out"})

      %{plan: plan}
    end

    test "can't be given a recipe by the planner", %{ctx: ctx, plan: plan} do
      args = %{"slot_key" => "tue_dinner", "recipe_id" => 1, "servings" => 2}
      assert {:error, :slot_eating_out} = find("assign_recipe").run.(args, ctx, plan)
    end

    test "can't be skipped or removed by the planner", %{ctx: ctx, plan: plan} do
      args = %{"slot_key" => "tue_dinner"}
      assert {:error, :slot_eating_out} = find("skip_meal").run.(args, ctx, plan)
      assert {:error, :slot_eating_out} = find("remove_recipe").run.(args, ctx, plan)
    end

    test "can't be swapped by the planner", %{ctx: ctx, plan: plan} do
      args = %{"from_slot_key" => "mon_dinner", "to_slot_key" => "tue_dinner"}
      assert {:error, :slot_eating_out} = find("swap_recipe").run.(args, ctx, plan)
    end
  end

  test "skip_meal on an empty slot returns the Decider error and does not evolve", %{ctx: ctx} do
    tool = find("skip_meal")

    assert {:error, :slot_empty} =
             tool.run.(%{"slot_key" => "fri_dinner", "rationale" => "out"}, ctx, %State{})
  end

  test "remove_recipe clears a slot", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "mon_dinner", rid)
    tool = find("remove_recipe")

    assert {:ok, %{ok: true}, [%Events.RecipeRemoved{slot_key: "mon_dinner"}], next} =
             tool.run.(%{"slot_key" => "mon_dinner", "rationale" => "changed mind"}, ctx, state)

    refute Map.has_key?(next.slots, "mon_dinner")
  end

  test "set_servings changes servings", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "mon_dinner", rid)
    tool = find("set_servings")

    assert {:ok, %{ok: true}, [%Events.ServingsChanged{slot_key: "mon_dinner", servings: 6}],
            next} =
             tool.run.(
               %{"slot_key" => "mon_dinner", "servings" => 6, "rationale" => "guests"},
               ctx,
               state
             )

    assert next.slots["mon_dinner"].servings == 6
  end

  test "mark_leftover marks the slot", %{ctx: ctx} do
    %{id: rid} = make_recipe()
    state = with_slot(%State{}, "tue_dinner", rid)
    tool = find("mark_leftover")

    assert {:ok, %{ok: true}, [%Events.LeftoverMarked{slot_key: "tue_dinner"}], next} =
             tool.run.(%{"slot_key" => "tue_dinner", "rationale" => "leftovers"}, ctx, state)

    assert next.slots["tue_dinner"].leftover == true
  end

  test "swap_recipe cross-assigns two slots", %{ctx: ctx} do
    r1 = make_recipe(%{title: "One"})
    r2 = make_recipe(%{title: "Two"})
    state = %State{} |> with_slot("mon_dinner", r1.id) |> with_slot("tue_dinner", r2.id)
    tool = find("swap_recipe")

    assert {:ok, %{ok: true, label: "One"} = result, events, next} =
             tool.run.(
               %{
                 "from_slot_key" => "mon_dinner",
                 "to_slot_key" => "tue_dinner",
                 "rationale" => "balance"
               },
               ctx,
               state
             )

    refute Map.has_key?(result, :recipe_id)
    assert next.slots["tue_dinner"].recipe_id == r1.id
    assert next.slots["mon_dinner"].recipe_id == r2.id
    assert events != []
  end

  test "read tools return the plan unchanged with no events", %{ctx: ctx} do
    tool = find("search_recipes")
    assert {:ok, %{recipes: _}, [], %State{}} = tool.run.(%{"query" => "x"}, ctx, %State{})
  end

  test "ask_user returns the question with the plan unchanged", %{ctx: ctx} do
    tool = find("ask_user")

    assert {:ok, %{ask_user: "which day?"}, [], %State{}} =
             tool.run.(%{"question" => "which day?"}, ctx, %State{})
  end

  test "search_recipes results carry a ref string and __handles__", %{ctx: ctx} do
    make_recipe(%{title: "Findable Stew"})
    tool = find("search_recipes")

    assert {:ok, %{recipes: recipes} = result, [], %State{}} =
             tool.run.(%{"query" => "Findable"}, ctx, %State{})

    assert [%{ref: ref, title: "Findable Stew"} = entry] = recipes
    assert is_binary(ref)
    assert String.starts_with?(ref, "rcp_")
    refute Map.has_key?(entry, :id)

    assert %{__handles__: [%Tore.Harness.Handles.ResolvedRecipe{ref: ^ref}]} = result
  end

  test "resolve_recipe tool maps an :ok resolver result", %{ctx: ctx} do
    %{id: rid, title: title} = make_recipe(%{title: "Very Unique Recipe Name"})
    tool = find("resolve_recipe")

    assert {:ok, %{match: match} = result, [], %State{}} =
             tool.run.(%{"query" => "Very Unique Recipe Name"}, ctx, %State{})

    assert match.label == title
    assert is_binary(match.ref)
    assert is_float(match.confidence)

    assert %{__handles__: [%Tore.Harness.Handles.ResolvedRecipe{id: ^rid}]} = result
  end

  test "resolve_recipe tool maps an :ambiguous resolver result", %{ctx: ctx} do
    make_recipe(%{title: "Chicken Soup With Rice"})
    make_recipe(%{title: "Chicken Soup With Noodles"})
    tool = find("resolve_recipe")

    assert {:ok, %{ambiguous: matches, note: note} = result, [], %State{}} =
             tool.run.(%{"query" => "chicken soup recipe"}, ctx, %State{})

    assert matches != []
    assert Enum.all?(matches, &(is_binary(&1.ref) and is_binary(&1.label)))
    assert note =~ "ask_user"
    assert %{__handles__: handles} = result
    assert length(handles) == length(matches)
  end

  test "resolve_recipe tool maps a :not_found resolver result", %{ctx: ctx} do
    tool = find("resolve_recipe")

    assert {:ok, %{not_found: true}, [], %State{}} =
             tool.run.(%{"query" => "zzzzzzz-nonexistent-recipe-zzzzzzz"}, ctx, %State{})
  end

  test "resolve_slot tool resolves against the working plan", %{ctx: ctx} do
    %{id: rid} = make_recipe(%{title: "Chicken skewers"})
    state = %State{} |> with_slot("wed_dinner", rid)
    tool = find("resolve_slot")

    assert {:ok, %{slot_key: "wed_dinner", label: label}, [], ^state} =
             tool.run.(%{"reference" => "the chicken skewers slot"}, ctx, state)

    assert label =~ "dinner"
  end

  test "resolve_slot tool reports ambiguity with candidates", %{ctx: ctx} do
    r1 = make_recipe(%{title: "Salmon pasta"})
    r2 = make_recipe(%{title: "Salmon soup"})
    state = %State{} |> with_slot("mon_dinner", r1.id) |> with_slot("fri_dinner", r2.id)
    tool = find("resolve_slot")

    assert {:ok, %{ambiguous: candidates, note: note}, [], ^state} =
             tool.run.(%{"reference" => "the salmon one"}, ctx, state)

    assert length(candidates) == 2
    assert note =~ "ask_user"
  end

  test "assign_recipe schema requires recipe_ref and not recipe_id" do
    tool = find("assign_recipe")
    required = tool.parameters.required

    assert "recipe_ref" in required
    refute "recipe_id" in required
    refute Map.has_key?(tool.parameters.properties, :recipe_id)
    assert Map.has_key?(tool.parameters.properties, :recipe_ref)
  end
end
