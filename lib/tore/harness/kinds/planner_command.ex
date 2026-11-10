defmodule Tore.Harness.Kinds.PlannerCommand do
  @moduledoc """
  A person asks the planner to change the week, from Plan or Today. `ctx` holds `:command`,
  `:plan_stream_id`, `:week_start` and optionally `:scoped_slot`, the slot the person tapped.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Harness.Kinds.Planner

  @impl true
  def kind, do: "planner_command_run"

  @impl true
  def surface, do: :plan

  @impl true
  def open(ctx) do
    %{
      input: Planner.input(ctx, %{"command" => ctx.command, "scoped_slot" => ctx[:scoped_slot]}),
      actor: :user
    }
  end

  @impl true
  def propose(run, ctx), do: Planner.propose(run, ctx, user_text(ctx.command, ctx[:scoped_slot]))

  @impl true
  defdelegate verify(proposal, ctx), to: Planner

  @impl true
  defdelegate review_question(proposal), to: Planner

  @impl true
  defdelegate apply_proposal(proposal, ctx), to: Planner

  @impl true
  defdelegate after_commit(run), to: Planner

  defp user_text(command, nil), do: command

  defp user_text(command, slot_key) do
    "[The user is referring to #{String.replace(slot_key, "_", " ")} (slot #{slot_key}).] " <>
      command
  end
end
