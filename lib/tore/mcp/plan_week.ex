defmodule Tore.Mcp.PlanWeek do
  @moduledoc """
  The `plan_week` prompt, for someone's own Claude: the same instructions Tore's own `plan_week`
  job gives pi (`harness/tasks/plan_week.md`), so a change to them reaches both.
  """

  alias Tore.Scope

  def name, do: "plan_week"

  def description, do: "Plan next week's dinners the way Tore's own planner does."

  @spec text(Scope.t()) :: String.t()
  def text(%Scope{}), do: Tore.Agent.task("plan_week")
end
