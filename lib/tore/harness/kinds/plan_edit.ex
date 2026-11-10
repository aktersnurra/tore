defmodule Tore.Harness.Kinds.PlanEdit do
  @moduledoc """
  Capture changes one day of the plan as someone asked: clears it, sets its servings, pins or
  unpins it, skips it, or marks it as eating out. There is no LLM step; the proposal is the
  planning command's events, decided against the plan as it is.

  A pinned day stays as it is, except to unpin it. Eating out carries its place and amount on
  the day itself, so undo puts them back with the slot.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Planning, Scope, Streams}
  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Harness.Kinds.Planner
  alias Tore.Planning.{Decider, Events}

  @doc "The proposal for `command` on `plan_id`, and the ctx to submit it with."
  @spec proposal(Scope.t(), String.t(), struct()) ::
          {:ok, PlanDiff.t(), map()} | {:error, term()}
  def proposal(%Scope{} = scope, plan_id, %{slot_key: slot_key} = command) do
    with {:ok, plan} <- Planning.load_plan(scope, plan_id),
         {:ok, events} <- Decider.decide(command, plan) do
      week_start = Streams.week_start(plan_id)

      diff = %PlanDiff{
        plan_stream_id: plan_id,
        week_start: week_start,
        events: Enum.map(events, &entry/1),
        plan_events: events
      }

      {:ok, diff, %{plan_stream_id: plan_id, week_start: week_start, slot_key: slot_key}}
    end
  end

  @impl true
  def kind, do: "plan_edit_run"

  @impl true
  def surface, do: :plan

  @impl true
  def open(ctx),
    do: %{input: Planner.input(ctx, %{"slot_key" => ctx.slot_key}), actor: :user}

  @impl true
  def verify(%PlanDiff{plan_events: events} = diff, %{scope: scope}) do
    {:ok, plan} = Planning.load_plan(scope, diff.plan_stream_id)

    pinned =
      for event <- events,
          not match?(%Events.SlotPinned{}, event),
          not match?(%Events.SlotUnpinned{}, event),
          Map.has_key?(plan.pins, event.slot_key),
          uniq: true,
          do: event.slot_key

    if pinned == [], do: :ok, else: {:fail, :slot_pinned, {:edit_plan, pinned}}
  end

  @impl true
  def review_question(_diff), do: nil

  @impl true
  def apply_proposal(%PlanDiff{} = diff, %{scope: scope}) do
    with {:ok, undo} <- Planner.change_plan(scope, diff.plan_stream_id, diff.plan_events),
         do: {:ok, {:steps, undo}, [diff]}
  end

  @impl true
  defdelegate after_commit(run), to: Planner

  defp entry(event) do
    payload =
      event
      |> Map.from_struct()
      |> Map.drop([:slot_key, :event_type])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    %{
      slot_key: event.slot_key,
      event_type: event |> Map.fetch!(:__struct__) |> Module.split() |> List.last(),
      payload: payload,
      rationale: ["user requested"]
    }
  end
end
