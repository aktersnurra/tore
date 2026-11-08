defmodule Tore.Prep do
  alias Tore.{Repo, Prep.PrepGuide, Planning, Recipes, Scope, SpendGuard}
  import Ecto.Query

  def generate_guide(%Scope{} = scope, plan_id, week_start) do
    with :ok <- SpendGuard.allow?(scope, :generate_prep_guide),
         {:ok, plan_state} <- Planning.load_plan(scope, plan_id) do
      plan_for_prompt = build_plan_for_prompt(scope, plan_state, week_start)

      {system, user} = Tore.LLM.Prompts.prep_guide(plan_for_prompt, Tore.Household.locale(scope))

      with {:ok, guide_data, _usage} <-
             Tore.LLM.text(scope, system, user, feature: :generate_prep_guide) do
        attrs = Map.put(guide_data, "week_start", week_start)
        save_guide(scope, attrs)
      end
    end
  end

  defp build_plan_for_prompt(scope, plan_state, week_start) do
    days =
      for {slot_key, %{recipe_id: recipe_id} = slot} <- plan_state.slots, recipe_id do
        %{
          slot_key: slot_key,
          recipe_title: Recipes.get!(scope, recipe_id).title,
          servings: slot.servings
        }
      end

    %{week_start: week_start, days: days}
  end

  def save_guide(%Scope{} = scope, attrs) do
    %PrepGuide{household_id: scope.household_id}
    |> PrepGuide.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:timeline, :cascade_map, :storage_notes, :daily_assembly, :prep_session, :instructions]},
      conflict_target: [:household_id, :week_start]
    )
  end

  def get_guide_for_week(%Scope{} = scope, week_start) do
    Repo.one(from(g in PrepGuide, where: g.week_start == ^week_start), Scope.repo_opts(scope))
  end
end
