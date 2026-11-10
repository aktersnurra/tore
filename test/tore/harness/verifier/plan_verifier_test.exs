defmodule Tore.Harness.Verifier.PlanVerifierTest do
  use Tore.DataCase, async: false
  alias Tore.Harness.Verifier.PlanVerifier
  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Planning.{State, Events, Decider}
  alias Tore.Household.Preferences

  defp diff(events),
    do: %PlanDiff{plan_stream_id: "p", week_start: ~D[2026-06-08], events: events}

  defp ev(slot, type, payload \\ %{}, rationale \\ ["x"]),
    do: %{slot_key: slot, event_type: type, payload: payload, rationale: rationale}

  defp ctx(plan \\ %State{}, prefs \\ %Preferences{}),
    do: %{plan_state: plan, preferences: prefs, scope: home_scope()}

  test "passes a clean assign" do
    plan =
      Decider.evolve(%State{}, %Events.RecipeAssigned{
        slot_key: "mon_dinner",
        recipe_id: 1,
        servings: 2
      })

    d = diff([ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => 1, "servings" => 2})])
    assert :ok = PlanVerifier.verify(d, ctx(plan))
  end

  test "fails when a pinned slot was changed" do
    plan = %State{pins: %{"mon_dinner" => true}}
    d = diff([ev("mon_dinner", "MealSkipped")])
    assert {:fail, :slot_pinned, {:edit_plan, ["mon_dinner"]}} = PlanVerifier.verify(d, ctx(plan))
  end

  test "fails when an assigned recipe has no servings" do
    d = diff([ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => 1, "servings" => nil})])

    assert {:fail, :servings_missing, {:edit_plan, ["mon_dinner"]}} =
             PlanVerifier.verify(d, ctx())
  end

  test "fails when a skip targets a slot not present in the plan" do
    d = diff([ev("fri_dinner", "MealSkipped")])

    assert {:fail, :skip_not_explicit, {:edit_plan, ["fri_dinner"]}} =
             PlanVerifier.verify(d, ctx(%State{}))
  end

  test "fails when a leftover has no earlier source meal" do
    plan =
      %State{}
      |> Decider.evolve(%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: 1, servings: 2})
      |> Decider.evolve(%Events.LeftoverMarked{slot_key: "mon_dinner"})

    d = diff([ev("mon_dinner", "LeftoverMarked")])

    assert {:fail, :leftover_no_source, {:edit_plan, ["mon_dinner"]}} =
             PlanVerifier.verify(d, ctx(plan))
  end

  test "passes a leftover with a valid earlier source" do
    plan =
      %State{}
      |> Decider.evolve(%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: 1, servings: 2})
      |> Decider.evolve(%Events.RecipeAssigned{slot_key: "tue_dinner", recipe_id: 2, servings: 2})
      |> Decider.evolve(%Events.LeftoverMarked{slot_key: "tue_dinner"})

    d = diff([ev("tue_dinner", "LeftoverMarked")])
    assert :ok = PlanVerifier.verify(d, ctx(plan))
  end

  test "fails when a swapped-in recipe contains an ingredient someone is allergic to" do
    {:ok, r} =
      Tore.Recipes.create(home_scope(), %{
        title: "Peanut Curry",
        base_servings: 2,
        instructions: "x",
        ingredients: [%{name: "peanut", quantity: 1, unit: "cup"}]
      })

    prefs = %Preferences{allergies: ["peanut"]}

    d =
      diff([
        ev("tue_dinner", "RecipeSwapped", %{"recipe_id" => r.id, "to_slot_key" => "tue_dinner"})
      ])

    plan =
      Decider.evolve(%State{}, %Events.RecipeAssigned{
        slot_key: "tue_dinner",
        recipe_id: r.id,
        servings: 2
      })

    assert {:fail, :dietary_violation, {:edit_plan, ["tue_dinner"]}} =
             PlanVerifier.verify(d, ctx(plan, prefs))
  end

  test "fails when an assigned recipe contains an ingredient someone is allergic to" do
    {:ok, r} =
      Tore.Recipes.create(home_scope(), %{
        title: "Peanut Stew",
        base_servings: 2,
        instructions: "x",
        ingredients: [%{name: "peanut", quantity: 1, unit: "cup"}]
      })

    prefs = %Preferences{allergies: ["peanut"]}
    d = diff([ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => r.id, "servings" => 2})])

    plan =
      Decider.evolve(%State{}, %Events.RecipeAssigned{
        slot_key: "mon_dinner",
        recipe_id: r.id,
        servings: 2
      })

    assert {:fail, :dietary_violation, {:edit_plan, ["mon_dinner"]}} =
             PlanVerifier.verify(d, ctx(plan, prefs))
  end
end
