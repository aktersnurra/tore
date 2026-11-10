defmodule Tore.Harness.Verifier.PlanVerifier do
  @moduledoc """
  Deterministic verifier for the planner's PlanDiff. Pure: deterministic reads
  only (recipe ingredients), no writes, no model calls. Returns :ok or the first
  failing check as {:fail, code, {:edit_plan, slots}}.
  """

  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Planning.State
  alias Tore.Household.Preferences

  @day_order ~w(mon tue wed thu fri sat sun)

  @type fail_code ::
          :slot_pinned
          | :servings_missing
          | :skip_not_explicit
          | :leftover_no_source
          | :dietary_violation
  @type repair_action :: {:edit_plan, [String.t()]}
  @type ctx :: %{plan_state: State.t(), preferences: Preferences.t(), scope: Tore.Scope.t()}

  @spec verify(PlanDiff.t(), ctx()) :: :ok | {:fail, fail_code(), repair_action()}
  def verify(%PlanDiff{events: events}, ctx) do
    with :ok <- check_pins(events, ctx.plan_state),
         :ok <- check_servings(events),
         :ok <- check_skips(events, ctx.plan_state),
         :ok <- check_leftovers(events, ctx.plan_state),
         :ok <- check_dietary(events, ctx.preferences, ctx.scope) do
      :ok
    end
  end

  defp check_pins(events, plan_state) do
    pinned = Map.keys(plan_state.pins)
    touched = events |> Enum.map(& &1.slot_key) |> Enum.filter(&(&1 in pinned))
    fail_if(touched, :slot_pinned)
  end

  defp check_servings(events) do
    bad =
      events
      |> Enum.filter(&(&1.event_type in ["RecipeAssigned", "ServingsChanged"]))
      |> Enum.reject(&positive_int?(&1.payload["servings"]))
      |> Enum.map(& &1.slot_key)

    fail_if(bad, :servings_missing)
  end

  defp check_skips(events, plan_state) do
    bad =
      events
      |> Enum.filter(&(&1.event_type == "MealSkipped"))
      |> Enum.map(& &1.slot_key)
      |> Enum.reject(&Map.has_key?(plan_state.slots, &1))

    fail_if(bad, :skip_not_explicit)
  end

  defp check_leftovers(events, plan_state) do
    bad =
      events
      |> Enum.filter(&(&1.event_type == "LeftoverMarked"))
      |> Enum.map(& &1.slot_key)
      |> Enum.reject(&has_earlier_source?(&1, plan_state))

    fail_if(bad, :leftover_no_source)
  end

  # Unlike the other checks (which key off the authoritative plan_state), this one
  # reads recipe_id from the PlanDiff payload. It therefore depends on
  # PlanDiffBuilder emitting recipe_id for both RecipeAssigned AND RecipeSwapped —
  # if that fidelity ever lapses, the dietary check goes blind on swapped recipes
  # while the plan still gets written. Keep the two in sync.
  defp check_dietary(events, prefs, scope) do
    banned = MapSet.new(downcase(prefs.dietary_restrictions ++ prefs.allergies))

    bad =
      events
      |> Enum.filter(&(&1.event_type in ["RecipeAssigned", "RecipeSwapped"]))
      |> Enum.filter(fn e -> violates?(scope, e.payload["recipe_id"], banned) end)
      |> Enum.map(& &1.slot_key)

    fail_if(bad, :dietary_violation)
  end

  defp fail_if([], _code), do: :ok
  defp fail_if(slots, code), do: {:fail, code, {:edit_plan, Enum.uniq(slots)}}

  defp positive_int?(n) when is_integer(n) and n > 0, do: true
  defp positive_int?(_), do: false

  defp has_earlier_source?(slot_key, plan_state) do
    idx = day_index(slot_key)

    Enum.any?(plan_state.slots, fn {k, slot} ->
      day_index(k) < idx and slot.recipe_id != nil and not slot.skipped and not slot.leftover
    end)
  end

  # Slot keys are always "<day>_<meal>" with a known day, so the fallback index
  # (length(@day_order)) is unreachable in practice; it keeps day_index total.
  defp day_index(slot_key) do
    day = slot_key |> String.split("_", parts: 2) |> hd()
    Enum.find_index(@day_order, &(&1 == day)) || length(@day_order)
  end

  defp violates?(_scope, nil, _banned), do: false

  defp violates?(scope, recipe_id, banned) do
    scope
    |> ingredient_names(recipe_id)
    |> Enum.any?(fn name -> MapSet.member?(banned, name) end)
  end

  defp ingredient_names(scope, recipe_id) do
    Tore.Recipes.get!(scope, recipe_id).recipe_ingredients
    |> Enum.map(&String.downcase(&1.ingredient.name))
  rescue
    Ecto.NoResultsError -> []
  end

  defp downcase(list), do: Enum.map(list, &String.downcase/1)
end
