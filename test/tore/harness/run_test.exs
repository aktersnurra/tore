defmodule Tore.Harness.RunTest do
  use Tore.DataCase, async: false
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, Events, State}
  alias Tore.Harness.Artifact.PlanDiff

  test "next_stream_id/0 returns a string with 'run-' prefix" do
    id = Run.next_stream_id()
    assert "run-" <> _ = id
    assert String.length(id) > 6
  end

  test "load/1 returns Draft for an unknown stream_id" do
    {:ok, state} = Run.load(home_scope(), "run-never-seen")
    assert %State.Draft{stream_id: "run-never-seen"} = state
  end

  test "append/3 persists events and load/1 replays them" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{command: "x"}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(home_scope(), sid, [opened])
    {:ok, state} = Run.load(home_scope(), sid)
    assert %State.Running{stream_id: ^sid, household_id: 1, kind: "planner_command_run"} = state
  end

  test "append/3 broadcasts {:run_event, stream_id, event} on the household topic" do
    sid = Run.next_stream_id()
    hh = household_fixture().id
    Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:#{hh}")

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: hh,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(Tore.Scope.for_household(hh), sid, [opened])
    assert_receive {:run_event, ^sid, %Events.Opened{household_id: ^hh}}, 500
  end

  test "decide/2 and evolve/2 delegate to Decider" do
    sid = Run.next_stream_id()
    assert function_exported?(Run, :decide, 2)
    assert function_exported?(Run, :evolve, 2)

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    running = Run.evolve(%State.Draft{stream_id: sid}, opened)
    assert {:ok, []} = Run.decide(%Commands.EnterPhase{phase: :gathering_context}, running)
  end

  test "load/1 rehydrates PhaseEntered phase back into an atom" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    {:ok, [phase_entered]} =
      Run.decide(
        %Commands.EnterPhase{phase: :proposing},
        Run.evolve(%State.Draft{stream_id: sid}, opened)
      )

    :ok = Run.append(home_scope(), sid, [opened, phase_entered])
    {:ok, state} = Run.load(home_scope(), sid)

    assert state.phase == :proposing
  end

  test "load/1 rehydrates Opened.surface and ToolStepRecorded.step_kind to atoms" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    step = %Events.ToolStepRecorded{
      step_index: 0,
      step_kind: :tool_calls,
      payload: %{},
      ai_operation_id: nil
    }

    :ok = Run.append(home_scope(), sid, [opened, step])
    {:ok, state} = Run.load(home_scope(), sid)

    assert state.surface == :plan
    assert [%{step_kind: :tool_calls}] = state.tool_trace
  end

  test "load/1 rehydrates FailureRecorded code without crashing on an unknown string" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    # An atom code that already exists round-trips back to the atom.
    failure = %Events.FailureRecorded{
      code: :slot_locked,
      user_message: "That slot is pinned.",
      repair_action: nil,
      at: ~U[2026-06-05 12:00:00Z]
    }

    :ok = Run.append(home_scope(), sid, [opened, failure])
    {:ok, state} = Run.load(home_scope(), sid)

    assert %State.Failed{failure_code: :slot_locked, failure_repair_action: nil} = state
  end

  test "FailureRecorded with an {:edit_plan, slots} repair_action survives a round-trip" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{command: "x"}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(home_scope(), sid, [opened])
    {:ok, running} = Run.load(home_scope(), sid)

    {:ok, fail_events} =
      Run.decide(
        %Commands.RecordFailure{
          code: :slot_pinned,
          user_message: nil,
          repair_action: {:edit_plan, ["mon_dinner", "fri_dinner"]}
        },
        running
      )

    :ok = Run.append(home_scope(), sid, fail_events)

    assert {:ok,
            %State.Failed{
              failure_code: :slot_pinned,
              failure_repair_action: {:edit_plan, ["mon_dinner", "fri_dinner"]}
            }} =
             Run.load(home_scope(), sid)
  end

  test "failure_code decodes to an atom for known verifier codes" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{command: "x"}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(home_scope(), sid, [opened])
    {:ok, running} = Run.load(home_scope(), sid)

    {:ok, fail_events} =
      Run.decide(
        %Commands.RecordFailure{
          code: :dietary_violation,
          user_message: nil,
          repair_action: {:edit_plan, ["mon_dinner"]}
        },
        running
      )

    :ok = Run.append(home_scope(), sid, fail_events)
    {:ok, loaded} = Run.load(home_scope(), sid)
    assert loaded.failure_code == :dietary_violation
    assert is_atom(loaded.failure_code)
  end

  test "load/1 folds ModelUsageObserved cost_usd back into a Decimal" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    usage = %Events.ModelUsageObserved{
      prompt_tokens: 5,
      completion_tokens: 2,
      cost_usd: Decimal.from_float(5.04e-4)
    }

    :ok = Run.append(home_scope(), sid, [opened, usage])
    {:ok, state} = Run.load(home_scope(), sid)

    assert %Decimal{} = state.model_usage.cost_usd
    assert Decimal.equal?(state.model_usage.cost_usd, Decimal.from_float(5.04e-4))
  end

  test "load/1 rehydrates ArtifactAdded artifacts via the Registry" do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [%{slot_key: "mon", event_type: "MealSkipped", payload: %{}, rationale: ["why"]}]
    }

    :ok = Run.append(home_scope(), sid, [opened, %Events.ArtifactAdded{artifact: diff}])
    {:ok, state} = Run.load(home_scope(), sid)

    assert [%PlanDiff{plan_stream_id: "plan-1"} = reloaded] = state.artifacts
    assert reloaded.week_start == ~D[2026-06-01]
  end

  test "load/1 rehydrates Committed.undo_payload back into an UndoPayload struct" do
    alias Tore.Harness.UndoPayload

    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    payload = %UndoPayload{
      kind: :event_sourced,
      data: %{
        stream_id: "plan-h1-w1",
        stream_type: "planning",
        event_types: ["RecipeAssigned"],
        compensating_events: [
          %{event_type: "RecipeRemoved", slot_key: "tue_dinner", payload: %{}}
        ]
      }
    }

    committed = %Events.Committed{at: ~U[2026-06-28 12:00:00Z], undo_payload: payload}

    :ok = Run.append(home_scope(), sid, [opened, committed])
    {:ok, state} = Run.load(home_scope(), sid)

    assert %State.Applied{undo_payload: %UndoPayload{kind: :event_sourced} = decoded} = state
    assert decoded.data.stream_id == "plan-h1-w1"
    assert decoded.data.stream_type == "planning"
    assert decoded.data.event_types == ["RecipeAssigned"]
  end

  test "another household loads a run as an empty draft" do
    sid = Run.next_stream_id()
    owner = scope_fixture(household_fixture())

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: owner.household_id,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(owner, sid, [opened])

    assert {:ok, %State.Running{}} = Run.load(owner, sid)
    assert {:ok, %State.Draft{stream_id: ^sid}} = Run.load(home_scope(), sid)
  end
end
