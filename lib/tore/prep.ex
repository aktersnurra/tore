defmodule Tore.Prep do
  alias Tore.{Repo, Prep.PrepGuide, Planning, Recipes, SpendGuard}
  import Ecto.Query

  def generate_guide(plan_id, week_start) do
    with :ok <- SpendGuard.allow?(:generate_prep_guide),
         {:ok, plan_state} <- Planning.load_plan(plan_id) do
      plan_for_prompt = build_plan_for_prompt(plan_state, week_start)

      {system, user} = Tore.LLM.Prompts.prep_guide(plan_for_prompt, Tore.Household.locale())

      with {:ok, guide_data, usage} <- Tore.LLM.text(system, user, []),
           :ok <- SpendGuard.log_usage(:generate_prep_guide, usage) do
        attrs = Map.put(guide_data, "week_start", week_start)
        save_guide(attrs)
      end
    end
  end

  defp build_plan_for_prompt(plan_state, week_start) do
    days =
      for {slot_key, %{recipe_id: recipe_id} = slot} <- plan_state.slots, recipe_id do
        %{
          slot_key: slot_key,
          recipe_title: Recipes.get!(recipe_id).title,
          servings: slot.servings
        }
      end

    %{week_start: week_start, days: days}
  end

  def save_guide(attrs) do
    %PrepGuide{}
    |> PrepGuide.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:timeline, :cascade_map, :storage_notes, :daily_assembly, :prep_session, :instructions]},
      conflict_target: [:week_start]
    )
  end

  def get_guide_for_week(week_start) do
    Repo.one(from g in PrepGuide, where: g.week_start == ^week_start)
  end
end
