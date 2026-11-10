defmodule Tore.Harness.Kinds.WeeklyPlanning do
  @moduledoc """
  The Saturday job fills next week's empty dinners. `ctx` holds `:plan_stream_id` and
  `:week_start`. The loop is capped, and a capped loop still applies what it did.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.Kinds.Planner

  @opts [max_round_trips: 10, max_action_calls: 25]

  @impl true
  def kind, do: "weekly_planning_run"

  @impl true
  def surface, do: :plan

  @impl true
  def open(ctx), do: %{input: Planner.input(ctx), actor: :system}

  @impl true
  def propose(run, ctx), do: Planner.propose(run, ctx, instruction(), @opts)

  @impl true
  defdelegate verify(proposal, ctx), to: Planner

  @impl true
  defdelegate review_question(proposal), to: Planner

  @impl true
  defdelegate apply_proposal(proposal, ctx), to: Planner

  @impl true
  defdelegate after_commit(run), to: Planner

  defp instruction do
    """
    Fill every empty, unplanned dinner this week with a suitable recipe. Leave
    days that already have a meal, days the household has pinned, and days marked
    eating_out exactly as they are. Use leftovers across days where it makes
    sense. When you are done, stop.
    """
  end
end
