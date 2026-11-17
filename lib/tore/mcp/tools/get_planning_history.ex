defmodule Tore.Mcp.Tools.GetPlanningHistory do
  @moduledoc """
  How the household has actually planned over the last six weeks: what was planned, skipped,
  removed and chosen again. The same history the weekly memory review reads, for a harness doing
  that review through MCP.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Harness.Capsules
  alias Tore.Harness.Capsules.{RecentHistoryCapsule, RecipeAffinityCapsule}

  @impl true
  def name, do: "get_planning_history"

  @impl true
  def description,
    do: """
    The last six weeks of planning: dinners planned, skipped and removed, skips by weekday, \
    recent activity, recipes chosen often and recipes swapped out. Null when nothing was planned.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    history = Capsules.compose([RecentHistoryCapsule, RecipeAffinityCapsule], %{scope: scope})
    {:ok, %{history: if(history == "", do: nil, else: history)}}
  end
end
