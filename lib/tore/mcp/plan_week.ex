defmodule Tore.Mcp.PlanWeek do
  @moduledoc """
  The `plan_week` prompt: how Tore plans a week, for someone's own Claude. The rules are the weekly
  planner's own (`Tore.Harness.Kinds.WeeklyPlanning.instruction/0` and the household's week mode),
  so a change to them reaches both; the rest says how to carry them out with these tools.
  """

  alias Tore.Harness.Kinds.WeeklyPlanning
  alias Tore.Scope

  def name, do: "plan_week"

  def description, do: "Plan next week's dinners the way Tore's own planner does."

  @spec text(Scope.t()) :: String.t()
  def text(%Scope{} = scope) do
    mode = scope |> Tore.WeekMode.get_current_mode() |> Tore.WeekMode.mode_prompt_fragment()

    [
      "Plan next week's dinners for this household in Tore.",
      String.trim(WeeklyPlanning.instruction()),
      mode,
      """
      How to do it here:
      - Call get_context first. Its diet and allergies are hard limits, and its language is the one \
      to write in. Prefer what's in the pantry and due soon, and this week's deals (list_deals).
      - Find recipes with search_recipes, read one with get_recipe, and put each on its day with \
      set_dinner, by ISO date. A pinned day stays as it is; set_dinner tells you if a day was.
      - Then say in a few lines what you planned, and offer to make the shopping list (make_list).
      - Every change answers with a run_id, and undo takes it back.
      """
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
