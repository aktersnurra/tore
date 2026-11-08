defmodule Tore.Harness.OrchestratorTest do
  use Tore.DataCase, async: false
  import Mox
  import Ecto.Query
  setup :verify_on_exit!

  alias Tore.Harness.{Orchestrator, Run}
  alias Tore.Harness.Run.State

  @ctx %{
    household_id: 1,
    user_id: 42,
    command: "skip mon dinner",
    plan_stream_id: "plan-1",
    week_start: ~D[2026-06-01]
  }

  test "dispatch(:planner_command_run, ctx) returns {:ok, %State.Applied{}} on a clean message run" do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Skipped Monday dinner."},
       %{prompt_tokens: 10, completion_tokens: 3, cost_usd: Decimal.new("0.0001")}}
    end)

    assert {:ok, %State.Applied{} = state} = Orchestrator.dispatch(:planner_command_run, @ctx)
    assert state.kind == "planner_command_run"
    assert state.household_id == 1
  end

  test "Applied state carries an undo_payload derived from the run's artifacts" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, %State.Applied{undo_payload: payload}} =
      Orchestrator.dispatch(:planner_command_run, @ctx)

    assert %Tore.Harness.UndoPayload{} = payload
  end

  test "dispatch persists a 'run' event stream that can be replayed" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, state} = Orchestrator.dispatch(:planner_command_run, @ctx)
    {:ok, replayed} = Run.load(home_scope(), state.stream_id)
    sid = state.stream_id
    assert %State.Applied{stream_id: ^sid} = replayed
  end

  test "dispatch writes ai_operations rows tagged with the run's stream_id" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "done"},
       %{prompt_tokens: 5, completion_tokens: 2, cost_usd: Decimal.new("0.0001")}}
    end)

    {:ok, state} = Orchestrator.dispatch(:planner_command_run, @ctx)
    rows = Tore.AiOperations.list_for_run(state.stream_id)
    assert rows != []
    assert Enum.all?(rows, fn r -> r.run_stream_id == state.stream_id end)
  end

  test "dispatch returns NeedsUser when the agent invokes ask_user" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls, [%{id: "c1", name: "ask_user", args: %{"question" => "which Monday?"}}]},
       %{prompt_tokens: 4, completion_tokens: 2, cost_usd: Decimal.new(0)}}
    end)

    assert {:ok, %State.NeedsUser{question: "which Monday?"}} =
             Orchestrator.dispatch(:planner_command_run, @ctx)
  end

  test "dispatch builds a real PlanDiff from the planner's skip_meal call" do
    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{title: "Chili", recipe_type: :meal, base_servings: 4})

    plan = Tore.Streams.plan(home_scope(), ~D[2026-06-01])
    Tore.Planning.assign_recipe(home_scope(), plan, "mon_dinner", recipe.id, 4)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "skip_meal",
            args: %{"slot_key" => "mon_dinner", "rationale" => "busy night"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Done."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = %{
      household_id: 1,
      user_id: 1,
      command: "skip monday",
      plan_stream_id: plan,
      week_start: ~D[2026-06-01]
    }

    {:ok, state} = Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)

    plan_diff = Enum.find(state.artifacts, &match?(%Tore.Harness.Artifact.PlanDiff{}, &1))

    assert [%{slot_key: "mon_dinner", event_type: "MealSkipped", rationale: ["busy night"]}] =
             plan_diff.events

    refute Enum.any?(plan_diff.events, &(&1.slot_key == "run"))
  end

  test "dispatch broadcasts run events on the household topic" do
    Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:1")

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, _state} = Orchestrator.dispatch(:planner_command_run, @ctx)

    assert_receive {:run_event, _sid, %Tore.Harness.Run.Events.Opened{}}, 1_000
    assert_receive {:run_event, _sid, %Tore.Harness.Run.Events.Committed{}}, 1_000
  end

  test "dispatch returns {:step_failed, reason} and records the run as Failed when a step errors" do
    Mox.stub(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:error, :boom}
    end)

    ctx = %{
      household_id: 1,
      user_id: 1,
      command: "skip monday",
      plan_stream_id: Tore.Streams.plan(home_scope(), ~D[2026-06-01]),
      week_start: ~D[2026-06-01]
    }

    assert {:error, {:step_failed, :boom}} =
             Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)

    sid = latest_run_stream_id()

    assert {:ok, %Tore.Harness.Run.State.Failed{failure_code: :internal_error}} =
             Tore.Harness.Run.load(home_scope(), sid)
  end

  test "dispatch returns {:run_crashed, exception} and records Failed when a step raises" do
    Mox.stub(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      raise "boom"
    end)

    ctx = %{
      household_id: 1,
      user_id: 1,
      command: "skip monday",
      plan_stream_id: Tore.Streams.plan(home_scope(), ~D[2026-06-01]),
      week_start: ~D[2026-06-01]
    }

    assert {:error, {:run_crashed, %RuntimeError{message: "boom"}}} =
             Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)

    sid = latest_run_stream_id()
    assert {:ok, %Tore.Harness.Run.State.Failed{}} = Tore.Harness.Run.load(home_scope(), sid)
  end

  test "dispatch applies accumulated plan events to the plan stream exactly once" do
    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{title: "Stew", recipe_type: :meal, base_servings: 4})

    plan = "plan:2026-06-08-apply"
    Tore.Planning.assign_recipe(home_scope(), plan, "mon_dinner", recipe.id, 4)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "skip_meal",
            args: %{"slot_key" => "mon_dinner", "rationale" => "out"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "Done."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = %{
      household_id: 1,
      user_id: 1,
      command: "skip monday",
      plan_stream_id: plan,
      week_start: ~D[2026-06-08]
    }

    {:ok, %State.Applied{}} = Orchestrator.dispatch(:planner_command_run, ctx)

    {:ok, plan_state} = Tore.Planning.load_plan(home_scope(), plan)
    assert plan_state.slots["mon_dinner"].skipped == true
  end

  test "a failed step leaves the plan stream unwritten (nothing applied)" do
    plan = "plan:2026-06-08-empty"
    Mox.stub(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ -> {:error, :boom} end)

    ctx = %{
      household_id: 1,
      user_id: 1,
      command: "skip monday",
      plan_stream_id: plan,
      week_start: ~D[2026-06-08]
    }

    assert {:error, {:step_failed, :boom}} = Orchestrator.dispatch(:planner_command_run, ctx)

    {:ok, plan_state} = Tore.Planning.load_plan(home_scope(), plan)
    assert plan_state.slots == %{}
  end

  test "a verifier failure records Failed, applies nothing, commits nothing" do
    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{
        title: "Pinned dish",
        recipe_type: :meal,
        base_servings: 4
      })

    plan = "plan:2026-06-08-pinned"
    Tore.Planning.assign_recipe(home_scope(), plan, "mon_dinner", recipe.id, 4)
    Tore.Planning.pin_slot(home_scope(), plan, "mon_dinner", true)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "skip_meal",
            args: %{"slot_key" => "mon_dinner", "rationale" => "out"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "Done."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = %{
      household_id: 1,
      user_id: 1,
      command: "skip monday",
      plan_stream_id: plan,
      week_start: ~D[2026-06-08]
    }

    assert {:ok,
            %State.Failed{
              failure_code: :slot_pinned,
              failure_repair_action: {:edit_plan, ["mon_dinner"]}
            }} =
             Orchestrator.dispatch(:planner_command_run, ctx)

    # nothing applied: the plan is byte-for-byte its pre-run state — mon_dinner
    # still holds the original recipe, is not skipped, and no slot was added.
    # (Proves "not applied", not "applied then undone": the fail branch never
    # calls apply_events, so the skip event was never written.)
    {:ok, plan_state} = Tore.Planning.load_plan(home_scope(), plan)
    assert Map.keys(plan_state.slots) == ["mon_dinner"]
    assert plan_state.slots["mon_dinner"].recipe_id == recipe.id
    refute plan_state.slots["mon_dinner"].skipped

    # no Committed event on the run stream — the run is Failed
    sid = latest_run_stream_id()
    {:ok, run} = Run.load(home_scope(), sid)
    assert %State.Failed{} = run
  end

  defp latest_run_stream_id do
    Tore.Repo.one(
      from(e in Tore.EventStore.Event,
        where: e.stream_type == "run",
        order_by: [desc: e.id],
        limit: 1,
        select: e.stream_id
      ),
      Tore.Scope.repo_opts(home_scope())
    )
  end

  describe "dispatch(:capture_turn_run, ctx)" do
    alias Tore.Harness.UndoPayload
    alias Tore.Harness.Artifact.RunBundle

    test "start_turn/1 returns {:ok, parent_stream_id}" do
      assert {:ok, sid} = Orchestrator.start_turn(%{household_id: 1, user_id: 42})
      assert is_binary(sid)

      {:ok, %State.Running{kind: "capture_turn_run", household_id: 1}} =
        Run.load(home_scope(), sid)
    end

    test "end_turn/2 with no children produces an irreversible RunBundle and commits" do
      {:ok, sid} = Orchestrator.start_turn(%{household_id: 1, user_id: 42})

      assert {:ok, %State.Applied{} = state} = Orchestrator.end_turn(home_scope(), sid, [])
      assert [%RunBundle{child_stream_ids: []}] = state.artifacts
      assert %UndoPayload{kind: :irreversible} = state.undo_payload
    end

    test "end_turn/2 composes the children's undo_payloads into the parent's" do
      {:ok, parent} = Orchestrator.start_turn(%{household_id: 1, user_id: 42})

      child_a = seed_applied_child(1)
      child_b = seed_applied_child(1)

      assert {:ok, %State.Applied{} = state} =
               Orchestrator.end_turn(home_scope(), parent, [child_a, child_b])

      assert [%RunBundle{child_stream_ids: [^child_a, ^child_b]}] = state.artifacts
      assert %UndoPayload{kind: :composite, data: %{children: children}} = state.undo_payload
      assert length(children) == 2
    end

    test "apply_set_plan_slot/1 opens a child Run, assigns the recipe, commits with a PlanDiff" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Carbonara",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      ctx = %{
        household_id: 1,
        user_id: 42,
        date: ~D[2026-06-23],
        recipe_id: recipe.id,
        servings: 4
      }

      assert {:ok, %{stream_id: sid, recipe: %{title: "Carbonara"}}} =
               Orchestrator.apply_set_plan_slot(ctx)

      assert is_binary(sid)
      {:ok, %State.Applied{} = state} = Run.load(home_scope(), sid)
      assert state.kind == "set_plan_slot_run"

      assert [%Tore.Harness.Artifact.PlanDiff{events: [%{event_type: "RecipeAssigned"}]}] =
               state.artifacts

      assert %Tore.Harness.UndoPayload{kind: :event_sourced} = state.undo_payload
    end

    test "apply_set_plan_slot/1 returns {:error, :recipe_not_found} when recipe does not exist" do
      ctx = %{
        household_id: 1,
        user_id: 42,
        date: ~D[2026-06-23],
        recipe_id: 999_999,
        servings: 4
      }

      assert {:error, :recipe_not_found} = Orchestrator.apply_set_plan_slot(ctx)
    end

    defp seed_applied_child(household_id) do
      alias Tore.Harness.Run.{Commands, Events}
      alias Tore.Harness.Artifact.PlanDiff

      sid = Run.next_stream_id()

      {:ok, [opened]} =
        Run.decide(
          %Commands.Open{
            household_id: household_id,
            kind: "test_child_run",
            surface: :plan,
            started_by: "user",
            user_id: 42,
            input: %{}
          },
          %State.Draft{stream_id: sid}
        )

      diff = %PlanDiff{
        plan_stream_id: "plan-x",
        week_start: ~D[2026-06-22],
        events: [
          %{
            slot_key: "2026-06-23-dinner",
            event_type: "RecipeAssigned",
            payload: %{},
            rationale: ["x"]
          }
        ]
      }

      payload = UndoPayload.from_artifacts([diff])

      :ok =
        Run.append(home_scope(), sid, [
          opened,
          %Events.ArtifactAdded{artifact: diff},
          %Events.Committed{at: DateTime.utc_now(), undo_payload: payload}
        ])

      sid
    end
  end
end
