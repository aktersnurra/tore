defmodule Tore.Harness.Kinds.PlanEdit do
  @moduledoc """
  Capture changes one day of the plan as someone asked: clears it, sets its servings, pins or
  unpins it, skips it, or marks it as eating out. There is no LLM step; the proposal is the
  planning command's events, decided against the plan as it is.

  A pinned day stays as it is, except to unpin it. Eating out also writes the day's dining
  entry, and undo puts the entry back as it was along with the slot.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Costs, Planning, Scope, Streams}
  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Harness.Kinds.Planner
  alias Tore.Planning.{Commands, Decider, Events}

  @doc """
  The proposal for `command` on `plan_id`, and the ctx to submit it with. `dining` holds the
  dining entry's `:description` and `:total_amount` for `Commands.EatOut`.
  """
  @spec proposal(Scope.t(), String.t(), struct(), map()) ::
          {:ok, PlanDiff.t(), map()} | {:error, term()}
  def proposal(%Scope{} = scope, plan_id, %{slot_key: slot_key} = command, dining \\ %{}) do
    with {:ok, plan} <- Planning.load_plan(scope, plan_id),
         {:ok, events} <- Decider.decide(command, plan) do
      week_start = Streams.week_start(plan_id)

      diff = %PlanDiff{
        plan_stream_id: plan_id,
        week_start: week_start,
        events: entries(command, events),
        plan_events: events
      }

      {:ok, diff,
       %{
         plan_stream_id: plan_id,
         week_start: week_start,
         slot_key: slot_key,
         dining: if(match?(%Commands.EatOut{}, command), do: dining)
       }}
    end
  end

  @impl true
  def kind, do: "plan_edit_run"

  @impl true
  def surface, do: :plan

  @impl true
  def open(ctx) do
    dining =
      ctx.dining &&
        %{
          "description" => ctx.dining[:description],
          "total_amount" => ctx.dining[:total_amount] && to_string(ctx.dining[:total_amount])
        }

    %{input: Planner.input(ctx, %{"slot_key" => ctx.slot_key, "dining" => dining}), actor: :user}
  end

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
  def apply_proposal(%PlanDiff{} = diff, %{scope: scope, run: run}) do
    plan_id = diff.plan_stream_id

    with {:ok, dining_undo} <- write_dining(scope, run, plan_id),
         {:ok, slot_undo} <- Planner.change_plan(scope, plan_id, diff.plan_events) do
      {:ok, {:steps, slot_undo ++ dining_undo}, [diff]}
    end
  end

  @impl true
  defdelegate after_commit(run), to: Planner

  # Undo runs last step first, so the entry goes before the slot is restored.
  defp write_dining(_scope, %{input: %{"dining" => nil}}, _plan_id), do: {:ok, []}

  defp write_dining(scope, %{input: %{"slot_key" => slot_key, "dining" => dining}}, plan_id) do
    before = Costs.dining_out_before(scope, plan_id, slot_key)

    attrs = %{
      plan_id: plan_id,
      slot_key: slot_key,
      date: Planning.slot_date(plan_id, slot_key),
      user_id: scope.user_id,
      description: dining["description"],
      total_amount: dining["total_amount"]
    }

    with {:ok, _entry} <- Costs.save_dining_out(scope, attrs),
         do: {:ok, [{:restore_dining_out, plan_id, slot_key, before}]}
  end

  # Eating out on a day already eating out appends nothing but changes its dining entry, so the
  # receipt still names the day.
  defp entries(%Commands.EatOut{slot_key: slot_key}, []),
    do: [entry(%Events.MealSkipped{slot_key: slot_key, reason: "eating_out"})]

  defp entries(_command, events), do: Enum.map(events, &entry/1)

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
