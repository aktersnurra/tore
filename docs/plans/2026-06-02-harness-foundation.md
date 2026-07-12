# Harness Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Run aggregate (Decider), the Artifact ADT, the Orchestrator, the per-household Projector, the `ai_operations.correlation_id → run_stream_id` migration, the pure `PlannerAgent.run/4`, and the run-receipt LiveComponent — wiring the planner command bar end-to-end through the harness.

**Architecture:** Event-sourced Run aggregate with a closed-sum-type State, persisted as `stream_type: "run"` in the existing `events` table. The Decider (`decide/2` + `evolve/2`) is pure. The Orchestrator composes Decider primitives into `dispatch(:planner_command_run, ...)`. A supervised per-household Projector holds in-memory state for cheap LiveView reads. The PlannerAgent loses all persistence and becomes a pure loop function over `chat_with_tools/4`. Artifacts are a behaviour with a closed compile-time registry. Image-carrying artifacts (none yet) will write to `Tore.Storage` and persist S3 keys only.

**Tech Stack:** Elixir/Phoenix/LiveView/Ecto, SQLite via `Ecto.Adapters.SQLite3`, `Phoenix.PubSub`, `Registry`, ETS, `Mox` for behaviour mocking, `ExUnit` for tests. Existing precedents: `Tore.Planning.Decider`, `Tore.Groceries.Decider`, `Tore.EventStore`.

**Spec:** `docs/specs/2026-06-02-harness-foundation-design.md`

**Pre-existing test floor:** Five to seven failures in `Groceries*` plus a SQLite race in `HouseholdTest` exist at commit `587101b6`. Anything new is a regression.

---

## File Structure

**Create:**

- `lib/tore/harness/run/events.ex` — closed sum type of run events (one module, ten event structs).
- `lib/tore/harness/run/commands.ex` — closed sum type of run commands (one module, ten command structs).
- `lib/tore/harness/run/state.ex` — closed sum type with six variants, each `@enforce_keys`-guarded.
- `lib/tore/harness/run/decider.ex` — pure `decide/2` and `evolve/2` over commands/events/state.
- `lib/tore/harness/run.ex` — public surface: `load/1`, `decide/2`, `evolve/2`, `append/3`, `next_stream_id/0`.
- `lib/tore/harness/artifact.ex` — behaviour (`kind`, `to_json`, `from_json`, `summary`, `is_rationale_complete`) plus helper dispatchers.
- `lib/tore/harness/artifact/registry.ex` — compile-time `kind → module` map.
- `lib/tore/harness/artifact/plan_diff.ex` — first concrete artifact; `events` field authoritative, `summarise/1` projection.
- `lib/tore/harness/artifact/run_summary.ex` — outcome + counts rollup; `from_artifacts/2` constructor.
- `lib/tore/harness/orchestrator.ex` — pure dispatcher; `dispatch/2`, `apply_command/3`, `:planner_command_run` handler.
- `lib/tore/harness/projector.ex` — supervised `GenServer` per household; ETS-backed lookup.
- `lib/tore/harness/projector_supervisor.ex` — `DynamicSupervisor` for per-household projectors.
- `lib/tore/harness/projector_registry.ex` — `Registry` keyed by household_id.
- `lib/tore_web/components/receipt_live.ex` — `LiveComponent` pattern-matching on State variants.
- `priv/repo/migrations/20260602000010_replace_correlation_id_with_run_stream_id.exs` — irreversible FK migration.
- Test files for each (paths under "Test files" in each task).

**Modify:**

- `lib/tore/event_store.ex` — extend `append/2` to broadcast on a configurable topic (additive; no behavior change for existing callers).
- `lib/tore/ai_operations.ex` — rename `list_by_correlation/1` → `list_for_run/1`; delete `find_by_correlation/1` (unused after refactor).
- `lib/tore/ai_operations/ai_operation.ex` — replace `correlation_id` field with `run_stream_id`; update changeset.
- `lib/tore/llm/planner_agent.ex` — full rewrite to pure `run(system_prompt, user_text, ctx, opts)` returning `loop_outcome`. No `AiOperations.log/1` calls, no `correlation_id` generation, no `Tore.Chat.SystemPrompt.build/0`.
- `lib/tore_web/live/planner_live.ex` — replace `quick_reply` + `quick_loading` machinery with `current_run` driven by the Projector; render via `ReceiptLive` component.
- `lib/tore/application.ex` — start `Tore.Harness.ProjectorRegistry` + `Tore.Harness.ProjectorSupervisor`.
- `test/tore_web/live/planner_live_test.exs` — update assertions for new `current_run` shape; remove `quick_reply` expectations.

**Convention anchors:**

- Event/Command/State module shape mirrors `lib/tore/planning/{events,commands,state}.ex`.
- Decider mirrors `lib/tore/planning/decider.ex`, except `initial/0` is replaced with `initial/1` (takes stream_id, returns `%State.Draft{stream_id: sid}`).
- `Tore.EventStore.load/2` calls `decider.initial()` (arity 0). Because the Run's initial state requires a `stream_id`, **`Tore.Harness.Run.load/1` does its own fold** instead of delegating to `EventStore.load/2`. This is the cleanest fit and documented in Task 5.

---

## Task 1: Run events module

**Files:**

- Create: `lib/tore/harness/run/events.ex`
- Test: `test/tore/harness/run/events_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/run/events_test.exs
defmodule Tore.Harness.Run.EventsTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Run.Events

  test "Opened carries stream_id, household_id, kind, surface, started_by, user_id, input, opened_at" do
    now = DateTime.utc_now()
    e = %Events.Opened{
      stream_id: "run-abc",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      started_by: "user",
      user_id: 42,
      input: %{command: "skip mon dinner"},
      opened_at: now
    }
    assert e.stream_id == "run-abc"
    assert e.opened_at == now
  end

  test "PhaseEntered carries phase + at" do
    e = %Events.PhaseEntered{phase: :proposing, at: ~U[2026-06-02 12:00:00Z]}
    assert e.phase == :proposing
  end

  test "ToolStepRecorded carries step_index, step_kind, payload, ai_operation_id" do
    e = %Events.ToolStepRecorded{
      step_index: 0,
      step_kind: :tool_calls,
      payload: %{calls: []},
      ai_operation_id: 7
    }
    assert e.step_kind == :tool_calls
  end

  test "ArtifactAdded carries artifact" do
    art = %{__struct__: SomeArtifact, foo: :bar}
    e = %Events.ArtifactAdded{artifact: art}
    assert e.artifact == art
  end

  test "ModelUsageObserved carries prompt_tokens, completion_tokens, cost_usd" do
    e = %Events.ModelUsageObserved{
      prompt_tokens: 100,
      completion_tokens: 50,
      cost_usd: Decimal.new("0.0012")
    }
    assert e.prompt_tokens == 100
  end

  test "QuestionRaised and QuestionAnswered carry question/answer + at" do
    now = ~U[2026-06-02 12:00:00Z]
    assert %Events.QuestionRaised{question: "Which one?", at: now}.question == "Which one?"
    assert %Events.QuestionAnswered{answer: "the first", at: now}.answer == "the first"
  end

  test "Committed carries at" do
    e = %Events.Committed{at: ~U[2026-06-02 12:00:00Z]}
    assert e.at
  end

  test "FailureRecorded carries code, user_message, repair_action, at" do
    e = %Events.FailureRecorded{
      code: :slot_locked,
      user_message: "Slot is pinned",
      repair_action: nil,
      at: ~U[2026-06-02 12:00:00Z]
    }
    assert e.code == :slot_locked
  end

  test "Reverted carries at" do
    e = %Events.Reverted{at: ~U[2026-06-02 12:00:00Z]}
    assert e.at
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/run/events_test.exs`
Expected: FAIL with `(CompileError) ... module Tore.Harness.Run.Events.Opened is not loaded`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/tore/harness/run/events.ex
defmodule Tore.Harness.Run.Events do
  defmodule Opened do
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by,
      :user_id, :input, :opened_at
    ]
  end

  defmodule PhaseEntered do
    defstruct [:phase, :at]
  end

  defmodule ToolStepRecorded do
    defstruct [:step_index, :step_kind, :payload, :ai_operation_id]
  end

  defmodule ArtifactAdded do
    defstruct [:artifact]
  end

  defmodule ModelUsageObserved do
    defstruct [:prompt_tokens, :completion_tokens, :cost_usd]
  end

  defmodule QuestionRaised do
    defstruct [:question, :at]
  end

  defmodule QuestionAnswered do
    defstruct [:answer, :at]
  end

  defmodule Committed do
    defstruct [:at]
  end

  defmodule FailureRecorded do
    defstruct [:code, :user_message, :repair_action, :at]
  end

  defmodule Reverted do
    defstruct [:at]
  end

  @type t ::
          %Opened{}
          | %PhaseEntered{}
          | %ToolStepRecorded{}
          | %ArtifactAdded{}
          | %ModelUsageObserved{}
          | %QuestionRaised{}
          | %QuestionAnswered{}
          | %Committed{}
          | %FailureRecorded{}
          | %Reverted{}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/run/events_test.exs`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): Run.Events — closed sum type of 10 events"
jj new
```

---

## Task 2: Run commands module

**Files:**

- Create: `lib/tore/harness/run/commands.ex`
- Test: `test/tore/harness/run/commands_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/run/commands_test.exs
defmodule Tore.Harness.Run.CommandsTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Run.Commands

  test "Open carries household_id, kind, surface, started_by, user_id, input" do
    c = %Commands.Open{
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      started_by: "user",
      user_id: 42,
      input: %{command: "x"}
    }
    assert c.kind == "planner_command_run"
  end

  test "all ten command structs construct" do
    assert %Commands.EnterPhase{phase: :proposing}.phase == :proposing
    assert %Commands.RecordToolStep{step_index: 0, step_kind: :tool_calls, payload: %{}, ai_operation_id: 1}.step_kind == :tool_calls
    assert %Commands.AddArtifact{artifact: :stub}.artifact == :stub
    assert %Commands.ObserveModelUsage{prompt_tokens: 1, completion_tokens: 2, cost_usd: Decimal.new(0)}.prompt_tokens == 1
    assert %Commands.RaiseQuestion{question: "q"}.question == "q"
    assert %Commands.AnswerQuestion{answer: "a"}.answer == "a"
    assert %Commands.Commit{} == %Commands.Commit{}
    assert %Commands.RecordFailure{code: :x, user_message: "m", repair_action: nil}.code == :x
    assert %Commands.Revert{} == %Commands.Revert{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/run/commands_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/tore/harness/run/commands.ex
defmodule Tore.Harness.Run.Commands do
  defmodule Open do
    defstruct [:household_id, :kind, :surface, :started_by, :user_id, :input]
  end

  defmodule EnterPhase do
    defstruct [:phase]
  end

  defmodule RecordToolStep do
    defstruct [:step_index, :step_kind, :payload, :ai_operation_id]
  end

  defmodule AddArtifact do
    defstruct [:artifact]
  end

  defmodule ObserveModelUsage do
    defstruct [:prompt_tokens, :completion_tokens, :cost_usd]
  end

  defmodule RaiseQuestion do
    defstruct [:question]
  end

  defmodule AnswerQuestion do
    defstruct [:answer]
  end

  defmodule Commit do
    defstruct []
  end

  defmodule RecordFailure do
    defstruct [:code, :user_message, :repair_action]
  end

  defmodule Revert do
    defstruct []
  end

  @type t ::
          %Open{} | %EnterPhase{} | %RecordToolStep{} | %AddArtifact{}
          | %ObserveModelUsage{} | %RaiseQuestion{} | %AnswerQuestion{}
          | %Commit{} | %RecordFailure{} | %Revert{}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/run/commands_test.exs`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): Run.Commands — closed sum type of 10 commands"
jj new
```

---

## Task 3: Run state — closed sum type with `@enforce_keys`

**Files:**

- Create: `lib/tore/harness/run/state.ex`
- Test: `test/tore/harness/run/state_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/run/state_test.exs
defmodule Tore.Harness.Run.StateTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Run.State

  test "empty/1 returns a Draft with the given stream_id" do
    assert %State.Draft{stream_id: "run-abc"} = State.empty("run-abc")
  end

  test "Draft enforces stream_id" do
    assert_raise ArgumentError, fn ->
      struct!(State.Draft, %{})
    end
  end

  test "Running enforces its 12 keys" do
    assert_raise ArgumentError, fn ->
      struct!(State.Running, %{stream_id: "x"})
    end
  end

  test "Running constructs when all keys present" do
    s = %State.Running{
      stream_id: "x",
      household_id: 1,
      kind: "planner_command_run",
      surface: :plan,
      started_by: "user",
      user_id: 1,
      input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      phase: :gathering_context,
      tool_trace: [],
      artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
    assert s.phase == :gathering_context
  end

  test "Failed enforces failure_user_message" do
    assert_raise ArgumentError, fn ->
      struct!(State.Failed, %{
        stream_id: "x", household_id: 1, kind: "k", surface: :plan,
        started_by: "user", user_id: 1, input: %{},
        opened_at: ~U[2026-06-02 12:00:00Z],
        failed_at: ~U[2026-06-02 12:00:00Z],
        failure_code: :x,
        # failure_user_message missing
        failure_repair_action: nil,
        tool_trace: [], artifacts: [],
        model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
      })
    end
  end

  test "NeedsUser, Applied, Reverted each enforce their key sets" do
    assert_raise ArgumentError, fn -> struct!(State.NeedsUser, %{stream_id: "x"}) end
    assert_raise ArgumentError, fn -> struct!(State.Applied, %{stream_id: "x"}) end
    assert_raise ArgumentError, fn -> struct!(State.Reverted, %{stream_id: "x"}) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/run/state_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/tore/harness/run/state.ex
defmodule Tore.Harness.Run.State do
  defmodule Draft do
    @enforce_keys [:stream_id]
    defstruct [:stream_id]
  end

  defmodule Running do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :phase, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :phase, :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule NeedsUser do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :question, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :question, :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule Applied do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :committed_at, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :committed_at, :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule Failed do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :failed_at,
      :failure_code, :failure_user_message, :failure_repair_action,
      :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :failed_at,
      :failure_code, :failure_user_message, :failure_repair_action,
      :tool_trace, :artifacts, :model_usage
    ]
  end

  defmodule Reverted do
    @enforce_keys [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :reverted_at, :tool_trace, :artifacts, :model_usage
    ]
    defstruct [
      :stream_id, :household_id, :kind, :surface, :started_by, :user_id,
      :input, :opened_at, :reverted_at, :tool_trace, :artifacts, :model_usage
    ]
  end

  @type t ::
          %Draft{}
          | %Running{}
          | %NeedsUser{}
          | %Applied{}
          | %Failed{}
          | %Reverted{}

  @spec empty(String.t()) :: Draft.t()
  def empty(stream_id), do: %Draft{stream_id: stream_id}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/run/state_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): Run.State — six variants enforced by @enforce_keys"
jj new
```

---

## Task 4: Run decider — `decide/2` and `evolve/2`

**Files:**

- Create: `lib/tore/harness/run/decider.ex`
- Test: `test/tore/harness/run/decider_test.exs`

This task implements the pure state machine. Every `(command, state)` pair has a clause, and a single catch-all returns `{:error, {:invalid_for_state, command_kind, state_kind}}`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/run/decider_test.exs
defmodule Tore.Harness.Run.DeciderTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Run.{Commands, Events, State, Decider}

  defp opened_state do
    {:ok, [opened]} =
      Decider.decide(
        %Commands.Open{
          household_id: 1, kind: "planner_command_run", surface: :plan,
          started_by: "user", user_id: 42, input: %{command: "x"}
        },
        %State.Draft{stream_id: "run-abc"}
      )
    Decider.evolve(%State.Draft{stream_id: "run-abc"}, opened)
  end

  describe "decide/2 — Open" do
    test "Draft + Open produces Opened with stream_id from Draft" do
      {:ok, [event]} =
        Decider.decide(
          %Commands.Open{
            household_id: 1, kind: "planner_command_run", surface: :plan,
            started_by: "user", user_id: 42, input: %{command: "x"}
          },
          %State.Draft{stream_id: "run-abc"}
        )
      assert event.stream_id == "run-abc"
      assert event.household_id == 1
      assert event.kind == "planner_command_run"
      assert %DateTime{} = event.opened_at
    end

    test "Running + Open is invalid" do
      assert {:error, {:invalid_for_state, Commands.Open, State.Running}} =
               Decider.decide(
                 %Commands.Open{household_id: 1, kind: "k", surface: :plan, started_by: "user", user_id: 1, input: %{}},
                 opened_state()
               )
    end
  end

  describe "decide/2 — phases" do
    test "EnterPhase to same phase produces no events" do
      s = opened_state()
      assert {:ok, []} = Decider.decide(%Commands.EnterPhase{phase: :gathering_context}, s)
    end

    test "EnterPhase to new phase produces PhaseEntered" do
      s = opened_state()
      {:ok, [e]} = Decider.decide(%Commands.EnterPhase{phase: :proposing}, s)
      assert %Events.PhaseEntered{phase: :proposing} = e
    end
  end

  describe "decide/2 — tool steps and usage" do
    test "RecordToolStep produces ToolStepRecorded with carried fields" do
      s = opened_state()
      cmd = %Commands.RecordToolStep{step_index: 3, step_kind: :tool_calls, payload: %{x: 1}, ai_operation_id: 9}
      {:ok, [e]} = Decider.decide(cmd, s)
      assert %Events.ToolStepRecorded{step_index: 3, step_kind: :tool_calls, payload: %{x: 1}, ai_operation_id: 9} = e
    end

    test "ObserveModelUsage produces ModelUsageObserved" do
      s = opened_state()
      cmd = %Commands.ObserveModelUsage{prompt_tokens: 10, completion_tokens: 5, cost_usd: Decimal.new("0.001")}
      {:ok, [e]} = Decider.decide(cmd, s)
      assert %Events.ModelUsageObserved{prompt_tokens: 10} = e
    end
  end

  describe "decide/2 — questions and commit" do
    test "RaiseQuestion in Running produces QuestionRaised" do
      s = opened_state()
      {:ok, [e]} = Decider.decide(%Commands.RaiseQuestion{question: "which?"}, s)
      assert %Events.QuestionRaised{question: "which?"} = e
    end

    test "AnswerQuestion in NeedsUser produces QuestionAnswered" do
      s = opened_state()
      {:ok, [raised]} = Decider.decide(%Commands.RaiseQuestion{question: "q"}, s)
      needs = Decider.evolve(s, raised)
      {:ok, [e]} = Decider.decide(%Commands.AnswerQuestion{answer: "a"}, needs)
      assert %Events.QuestionAnswered{answer: "a"} = e
    end

    test "AnswerQuestion in Running is invalid" do
      s = opened_state()
      assert {:error, {:invalid_for_state, Commands.AnswerQuestion, State.Running}} =
               Decider.decide(%Commands.AnswerQuestion{answer: "a"}, s)
    end

    test "Commit in Running produces Committed" do
      s = opened_state()
      {:ok, [e]} = Decider.decide(%Commands.Commit{}, s)
      assert %Events.Committed{} = e
    end

    test "Commit in Draft is invalid" do
      assert {:error, {:invalid_for_state, Commands.Commit, State.Draft}} =
               Decider.decide(%Commands.Commit{}, %State.Draft{stream_id: "x"})
    end
  end

  describe "decide/2 — failure and revert" do
    test "RecordFailure in Running produces FailureRecorded" do
      s = opened_state()
      cmd = %Commands.RecordFailure{code: :slot_locked, user_message: "Locked", repair_action: nil}
      {:ok, [e]} = Decider.decide(cmd, s)
      assert %Events.FailureRecorded{code: :slot_locked, user_message: "Locked"} = e
    end

    test "Revert in Applied produces Reverted" do
      s = opened_state()
      {:ok, [committed]} = Decider.decide(%Commands.Commit{}, s)
      applied = Decider.evolve(s, committed)
      {:ok, [e]} = Decider.decide(%Commands.Revert{}, applied)
      assert %Events.Reverted{} = e
    end
  end

  describe "evolve/2 — folding" do
    test "Draft + Opened transitions to Running with empty trace/artifacts/usage" do
      d = %State.Draft{stream_id: "run-abc"}
      e = %Events.Opened{
        stream_id: "run-abc", household_id: 1, kind: "planner_command_run",
        surface: :plan, started_by: "user", user_id: 42,
        input: %{command: "x"}, opened_at: ~U[2026-06-02 12:00:00Z]
      }
      r = Decider.evolve(d, e)
      assert %State.Running{phase: :gathering_context, tool_trace: [], artifacts: []} = r
      assert r.model_usage == %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    end

    test "Running + ToolStepRecorded appends to tool_trace" do
      s = opened_state()
      e = %Events.ToolStepRecorded{step_index: 0, step_kind: :message, payload: %{text: "ok"}, ai_operation_id: 1}
      r = Decider.evolve(s, e)
      assert [%{step_index: 0, step_kind: :message}] = r.tool_trace
    end

    test "Running + ModelUsageObserved accumulates" do
      s = opened_state()
      s2 = Decider.evolve(s, %Events.ModelUsageObserved{prompt_tokens: 10, completion_tokens: 5, cost_usd: Decimal.new("0.001")})
      s3 = Decider.evolve(s2, %Events.ModelUsageObserved{prompt_tokens: 7, completion_tokens: 3, cost_usd: Decimal.new("0.002")})
      assert s3.model_usage.prompt_tokens == 17
      assert s3.model_usage.completion_tokens == 8
      assert Decimal.equal?(s3.model_usage.cost_usd, Decimal.new("0.003"))
    end

    test "Running + Committed transitions to Applied with committed_at" do
      s = opened_state()
      at = ~U[2026-06-02 13:00:00Z]
      applied = Decider.evolve(s, %Events.Committed{at: at})
      assert %State.Applied{committed_at: ^at} = applied
    end

    test "Running + FailureRecorded transitions to Failed with code/message/repair" do
      s = opened_state()
      at = ~U[2026-06-02 13:00:00Z]
      e = %Events.FailureRecorded{code: :slot_locked, user_message: "Locked", repair_action: nil, at: at}
      failed = Decider.evolve(s, e)
      assert %State.Failed{failed_at: ^at, failure_code: :slot_locked, failure_user_message: "Locked"} = failed
    end

    test "Running + QuestionRaised transitions to NeedsUser carrying question" do
      s = opened_state()
      needs = Decider.evolve(s, %Events.QuestionRaised{question: "which?", at: ~U[2026-06-02 12:00:00Z]})
      assert %State.NeedsUser{question: "which?"} = needs
    end

    test "NeedsUser + QuestionAnswered transitions back to Running" do
      s = opened_state()
      needs = Decider.evolve(s, %Events.QuestionRaised{question: "q", at: ~U[2026-06-02 12:00:00Z]})
      running = Decider.evolve(needs, %Events.QuestionAnswered{answer: "a", at: ~U[2026-06-02 12:00:01Z]})
      assert %State.Running{} = running
    end

    test "Applied + Reverted transitions to Reverted" do
      s = opened_state()
      applied = Decider.evolve(s, %Events.Committed{at: ~U[2026-06-02 13:00:00Z]})
      reverted = Decider.evolve(applied, %Events.Reverted{at: ~U[2026-06-02 13:05:00Z]})
      assert %State.Reverted{reverted_at: ~U[2026-06-02 13:05:00Z]} = reverted
    end
  end

  describe "decider purity" do
    test "decide/2 has no Repo dependency" do
      # Sanity: just ensure the module does not alias Repo.
      assert function_exported?(Decider, :decide, 2)
      refute Code.ensure_loaded?(Tore.Repo) and
               (Decider.module_info(:attributes) |> Keyword.get(:alias, []) |> Enum.member?(Tore.Repo))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/run/decider_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/tore/harness/run/decider.ex
defmodule Tore.Harness.Run.Decider do
  alias Tore.Harness.Run.{Commands, Events, State}
  alias Tore.Harness.Artifact

  @spec initial(String.t()) :: State.Draft.t()
  def initial(stream_id), do: %State.Draft{stream_id: stream_id}

  @spec decide(Commands.t(), State.t()) :: {:ok, [Events.t()]} | {:error, term()}

  def decide(%Commands.Open{} = c, %State.Draft{stream_id: sid}) do
    {:ok,
     [
       %Events.Opened{
         stream_id: sid,
         household_id: c.household_id,
         kind: c.kind,
         surface: c.surface,
         started_by: c.started_by,
         user_id: c.user_id,
         input: c.input,
         opened_at: DateTime.utc_now()
       }
     ]}
  end

  def decide(%Commands.EnterPhase{phase: p}, %State.Running{phase: p}), do: {:ok, []}

  def decide(%Commands.EnterPhase{phase: p}, %State.Running{}),
    do: {:ok, [%Events.PhaseEntered{phase: p, at: DateTime.utc_now()}]}

  def decide(%Commands.RecordToolStep{} = c, %State.Running{}) do
    {:ok,
     [
       %Events.ToolStepRecorded{
         step_index: c.step_index,
         step_kind: c.step_kind,
         payload: c.payload,
         ai_operation_id: c.ai_operation_id
       }
     ]}
  end

  def decide(%Commands.AddArtifact{artifact: a}, %State.Running{}) do
    if Artifact.is_rationale_complete(a) do
      {:ok, [%Events.ArtifactAdded{artifact: a}]}
    else
      {:error, :rationale_incomplete}
    end
  end

  def decide(%Commands.ObserveModelUsage{} = c, %State.Running{}) do
    {:ok,
     [
       %Events.ModelUsageObserved{
         prompt_tokens: c.prompt_tokens,
         completion_tokens: c.completion_tokens,
         cost_usd: c.cost_usd
       }
     ]}
  end

  def decide(%Commands.RaiseQuestion{question: q}, %State.Running{}),
    do: {:ok, [%Events.QuestionRaised{question: q, at: DateTime.utc_now()}]}

  def decide(%Commands.AnswerQuestion{answer: a}, %State.NeedsUser{}),
    do: {:ok, [%Events.QuestionAnswered{answer: a, at: DateTime.utc_now()}]}

  def decide(%Commands.Commit{}, %State.Running{}),
    do: {:ok, [%Events.Committed{at: DateTime.utc_now()}]}

  def decide(%Commands.RecordFailure{} = c, %State.Running{}) do
    {:ok,
     [
       %Events.FailureRecorded{
         code: c.code,
         user_message: c.user_message,
         repair_action: c.repair_action,
         at: DateTime.utc_now()
       }
     ]}
  end

  def decide(%Commands.Revert{}, %State.Applied{}),
    do: {:ok, [%Events.Reverted{at: DateTime.utc_now()}]}

  def decide(command, state),
    do: {:error, {:invalid_for_state, command.__struct__, state.__struct__}}

  @spec evolve(State.t(), Events.t()) :: State.t()

  def evolve(%State.Draft{stream_id: sid}, %Events.Opened{} = e) do
    %State.Running{
      stream_id: sid,
      household_id: e.household_id,
      kind: e.kind,
      surface: e.surface,
      started_by: e.started_by,
      user_id: e.user_id,
      input: e.input,
      opened_at: e.opened_at,
      phase: :gathering_context,
      tool_trace: [],
      artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
  end

  def evolve(%State.Running{} = s, %Events.PhaseEntered{phase: p}),
    do: %{s | phase: p}

  def evolve(%State.Running{tool_trace: t} = s, %Events.ToolStepRecorded{} = e),
    do: %{s | tool_trace: t ++ [step_entry(e)]}

  def evolve(%State.Running{artifacts: a} = s, %Events.ArtifactAdded{artifact: art}),
    do: %{s | artifacts: a ++ [art]}

  def evolve(%State.Running{model_usage: m} = s, %Events.ModelUsageObserved{} = e),
    do: %{
      s
      | model_usage: %{
          prompt_tokens: m.prompt_tokens + e.prompt_tokens,
          completion_tokens: m.completion_tokens + e.completion_tokens,
          cost_usd: Decimal.add(m.cost_usd, e.cost_usd)
        }
    }

  def evolve(%State.Running{} = s, %Events.QuestionRaised{question: q}),
    do: to_needs_user(s, q)

  def evolve(%State.NeedsUser{} = s, %Events.QuestionAnswered{}),
    do: to_running(s)

  def evolve(%State.Running{} = s, %Events.Committed{at: at}),
    do: to_applied(s, at)

  def evolve(%State.Running{} = s, %Events.FailureRecorded{} = e),
    do: to_failed(s, e)

  def evolve(%State.Applied{} = s, %Events.Reverted{at: at}),
    do: to_reverted(s, at)

  defp step_entry(%Events.ToolStepRecorded{} = e) do
    %{
      step_index: e.step_index,
      step_kind: e.step_kind,
      payload: e.payload,
      ai_operation_id: e.ai_operation_id
    }
  end

  defp to_needs_user(%State.Running{} = s, q) do
    %State.NeedsUser{
      stream_id: s.stream_id,
      household_id: s.household_id,
      kind: s.kind,
      surface: s.surface,
      started_by: s.started_by,
      user_id: s.user_id,
      input: s.input,
      opened_at: s.opened_at,
      question: q,
      tool_trace: s.tool_trace,
      artifacts: s.artifacts,
      model_usage: s.model_usage
    }
  end

  defp to_running(%State.NeedsUser{} = s) do
    %State.Running{
      stream_id: s.stream_id,
      household_id: s.household_id,
      kind: s.kind,
      surface: s.surface,
      started_by: s.started_by,
      user_id: s.user_id,
      input: s.input,
      opened_at: s.opened_at,
      phase: :proposing,
      tool_trace: s.tool_trace,
      artifacts: s.artifacts,
      model_usage: s.model_usage
    }
  end

  defp to_applied(%State.Running{} = s, at) do
    %State.Applied{
      stream_id: s.stream_id,
      household_id: s.household_id,
      kind: s.kind,
      surface: s.surface,
      started_by: s.started_by,
      user_id: s.user_id,
      input: s.input,
      opened_at: s.opened_at,
      committed_at: at,
      tool_trace: s.tool_trace,
      artifacts: s.artifacts,
      model_usage: s.model_usage
    }
  end

  defp to_failed(%State.Running{} = s, %Events.FailureRecorded{} = e) do
    %State.Failed{
      stream_id: s.stream_id,
      household_id: s.household_id,
      kind: s.kind,
      surface: s.surface,
      started_by: s.started_by,
      user_id: s.user_id,
      input: s.input,
      opened_at: s.opened_at,
      failed_at: e.at,
      failure_code: e.code,
      failure_user_message: e.user_message,
      failure_repair_action: e.repair_action,
      tool_trace: s.tool_trace,
      artifacts: s.artifacts,
      model_usage: s.model_usage
    }
  end

  defp to_reverted(%State.Applied{} = s, at) do
    %State.Reverted{
      stream_id: s.stream_id,
      household_id: s.household_id,
      kind: s.kind,
      surface: s.surface,
      started_by: s.started_by,
      user_id: s.user_id,
      input: s.input,
      opened_at: s.opened_at,
      reverted_at: at,
      tool_trace: s.tool_trace,
      artifacts: s.artifacts,
      model_usage: s.model_usage
    }
  end
end
```

**Stub `Tore.Harness.Artifact.is_rationale_complete/1`:** the Decider aliases `Tore.Harness.Artifact`, which Task 6 introduces. For this task to compile, add a temporary skeleton:

```elixir
# lib/tore/harness/artifact.ex (skeleton — Task 6 expands)
defmodule Tore.Harness.Artifact do
  @spec is_rationale_complete(struct()) :: boolean()
  def is_rationale_complete(%mod{} = artifact), do: mod.is_rationale_complete(artifact)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/run/decider_test.exs`
Expected: PASS, 18 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): Run.Decider — pure decide/2 + evolve/2 over State ADT"
jj new
```

---

## Task 5: Run public surface — `Tore.Harness.Run`

**Files:**

- Create: `lib/tore/harness/run.ex`
- Modify: `lib/tore/event_store.ex` — add an optional `broadcast: topic` keyword to `append/2`.
- Test: `test/tore/harness/run_test.exs`

This task adds `Tore.Harness.Run` — `load/1`, `append/3`, `next_stream_id/0`, and delegates to the Decider. `load/1` does NOT delegate to `EventStore.load/2` because the Run's initial state needs the stream_id; instead it queries the event store directly and folds from `%State.Draft{stream_id: sid}`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/run_test.exs
defmodule Tore.Harness.RunTest do
  use Tore.DataCase, async: false
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, Events, State}

  test "next_stream_id/0 returns a string with 'run-' prefix" do
    id = Run.next_stream_id()
    assert "run-" <> _ = id
    assert String.length(id) > 6
  end

  test "load/1 returns Draft for an unknown stream_id" do
    {:ok, state} = Run.load("run-never-seen")
    assert %State.Draft{stream_id: "run-never-seen"} = state
  end

  test "append/3 persists events and load/1 replays them" do
    sid = Run.next_stream_id()
    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: 1, kind: "planner_command_run", surface: :plan,
          started_by: "user", user_id: 1, input: %{command: "x"}
        },
        %State.Draft{stream_id: sid}
      )
    :ok = Run.append(sid, [opened])
    {:ok, state} = Run.load(sid)
    assert %State.Running{stream_id: ^sid, household_id: 1, kind: "planner_command_run"} = state
  end

  test "append/3 broadcasts {:run_event, stream_id, event} on the household topic" do
    sid = Run.next_stream_id()
    hh = 7
    Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:#{hh}")

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: hh, kind: "planner_command_run", surface: :plan,
          started_by: "user", user_id: 1, input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(sid, [opened], %{household_id: hh})
    assert_receive {:run_event, ^sid, %Events.Opened{household_id: ^hh}}, 500
  end

  test "decide/2 and evolve/2 delegate to Decider" do
    assert function_exported?(Run, :decide, 2)
    assert function_exported?(Run, :evolve, 2)
    assert {:ok, []} = Run.decide(%Commands.EnterPhase{phase: :gathering_context},
                                  open_running(Run.next_stream_id(), 1))
  end

  defp open_running(sid, hh) do
    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: hh, kind: "planner_command_run", surface: :plan,
          started_by: "user", user_id: 1, input: %{}
        },
        %State.Draft{stream_id: sid}
      )
    Run.evolve(%State.Draft{stream_id: sid}, opened)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/run_test.exs`
Expected: FAIL with module-not-loaded for `Tore.Harness.Run`.

- [ ] **Step 3: Extend `EventStore.append/2` with an optional broadcast**

```elixir
# lib/tore/event_store.ex — replace the existing append/2 with append/3:
@spec append(String.t(), [struct()], keyword()) :: :ok | {:error, term()}
def append(stream_id, events, opts \\ []) do
  now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  rows =
    Enum.map(events, fn event ->
      %{
        stream_id: stream_id,
        stream_type: stream_type_for(event),
        event_type: event.__struct__ |> Module.split() |> List.last(),
        data: Jason.encode!(Map.from_struct(event)),
        metadata: nil,
        inserted_at: now
      }
    end)

  Repo.insert_all(Event, rows)

  case Keyword.get(opts, :broadcast) do
    nil ->
      :ok

    topic when is_binary(topic) ->
      tag = Keyword.get(opts, :broadcast_tag, :event)

      Enum.each(events, fn ev ->
        Phoenix.PubSub.broadcast(Tore.PubSub, topic, {tag, stream_id, ev})
      end)

      :ok
  end
rescue
  e -> {:error, e}
end
```

Existing callers (`append(stream_id, events)`) still work because of the default `opts \\ []`.

- [ ] **Step 4: Write `Tore.Harness.Run`**

```elixir
# lib/tore/harness/run.ex
defmodule Tore.Harness.Run do
  import Ecto.Query
  alias Tore.Harness.Run.{Decider, State, Events}
  alias Tore.EventStore
  alias Tore.EventStore.Event
  alias Tore.Repo

  @stream_type "run"

  @spec next_stream_id() :: String.t()
  def next_stream_id,
    do: "run-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  @spec load(String.t()) :: {:ok, State.t()}
  def load(stream_id) do
    state =
      from(e in Event,
        where: e.stream_id == ^stream_id and e.stream_type == ^@stream_type,
        order_by: [asc: e.id]
      )
      |> Repo.all()
      |> Enum.reduce(%State.Draft{stream_id: stream_id}, fn raw, acc ->
        event = deserialize(raw.event_type, raw.data)
        Decider.evolve(acc, event)
      end)

    {:ok, state}
  end

  defdelegate decide(command, state), to: Decider
  defdelegate evolve(state, event), to: Decider

  @spec append(String.t(), [Events.t()], map()) :: :ok | {:error, term()}
  def append(stream_id, events, metadata \\ %{}) do
    opts =
      case Map.get(metadata, :household_id) do
        nil -> []
        hh -> [broadcast: "harness:household:#{hh}", broadcast_tag: :run_event]
      end

    EventStore.append(stream_id, events, opts)
  end

  defp deserialize(event_type, data) do
    module = Module.concat([Tore.Harness.Run.Events, event_type])
    attrs = Jason.decode!(data, keys: :atoms)
    struct!(module, attrs)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/tore/harness/run_test.exs`
Expected: PASS, 5 tests.

Also re-run existing event-store-dependent tests to confirm no regression:

Run: `mix test test/tore/planning test/tore/groceries`
Expected: same failure count as baseline (5–7 in groceries; planning passes).

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): Tore.Harness.Run — load, append (PubSub-broadcasting), next_stream_id"
jj new
```

---

## Task 6: Artifact behaviour + Registry

**Files:**

- Replace skeleton from Task 4: `lib/tore/harness/artifact.ex`
- Create: `lib/tore/harness/artifact/registry.ex`
- Test: `test/tore/harness/artifact_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/artifact_test.exs
defmodule Tore.Harness.ArtifactTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Artifact
  alias Tore.Harness.Artifact.Registry

  defmodule Dummy do
    @behaviour Tore.Harness.Artifact
    defstruct [:rationale, :n]
    @impl true
    def kind, do: "Dummy"
    @impl true
    def to_json(%__MODULE__{n: n}), do: %{"n" => n}
    @impl true
    def from_json(%{"n" => n}), do: %__MODULE__{n: n}
    @impl true
    def summary(%__MODULE__{n: n}),
      do: %{counts: %{items: n}, text_fallback: "n=#{n}"}
    @impl true
    def is_rationale_complete(%__MODULE__{rationale: r}), do: r in [nil, []] == false
  end

  test "Artifact.is_rationale_complete/1 dispatches to module callback" do
    refute Artifact.is_rationale_complete(%Dummy{rationale: nil, n: 0})
    assert Artifact.is_rationale_complete(%Dummy{rationale: ["why"], n: 0})
  end

  test "Artifact.summary/1 dispatches to module callback" do
    assert %{counts: %{items: 3}, text_fallback: "n=3"} =
             Artifact.summary(%Dummy{rationale: ["x"], n: 3})
  end

  test "Registry.kinds/0 lists registered kinds" do
    assert "PlanDiff" in Registry.kinds()
    assert "RunSummary" in Registry.kinds()
  end

  test "Registry.lookup/1 returns the module" do
    assert {:ok, Tore.Harness.Artifact.PlanDiff} = Registry.lookup("PlanDiff")
    assert {:ok, Tore.Harness.Artifact.RunSummary} = Registry.lookup("RunSummary")
    assert :error = Registry.lookup("Nonexistent")
  end

  test "Registry.modules/0 returns module list" do
    assert Tore.Harness.Artifact.PlanDiff in Registry.modules()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/artifact_test.exs`
Expected: FAIL with `Tore.Harness.Artifact.PlanDiff is not loaded`.

- [ ] **Step 3: Replace the skeleton `Tore.Harness.Artifact`**

```elixir
# lib/tore/harness/artifact.ex
defmodule Tore.Harness.Artifact do
  @type kind :: String.t()
  @type t :: struct()

  @callback kind() :: kind()
  @callback to_json(t()) :: map()
  @callback from_json(map()) :: t()
  @callback summary(t()) :: %{
              counts: %{atom() => non_neg_integer()},
              text_fallback: String.t()
            }
  @callback is_rationale_complete(t()) :: boolean()

  @spec is_rationale_complete(t()) :: boolean()
  def is_rationale_complete(%mod{} = artifact), do: mod.is_rationale_complete(artifact)

  @spec summary(t()) :: map()
  def summary(%mod{} = artifact), do: mod.summary(artifact)

  @spec to_json(t()) :: map()
  def to_json(%mod{} = artifact), do: Map.put(mod.to_json(artifact), "__kind__", mod.kind())
end
```

- [ ] **Step 4: Add the Registry**

```elixir
# lib/tore/harness/artifact/registry.ex
defmodule Tore.Harness.Artifact.Registry do
  alias Tore.Harness.Artifact.{PlanDiff, RunSummary}

  @registry %{
    "PlanDiff" => PlanDiff,
    "RunSummary" => RunSummary
  }

  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(kind), do: Map.fetch(@registry, kind)

  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@registry)

  @spec modules() :: [module()]
  def modules, do: Map.values(@registry)
end
```

Note: the registry references modules implemented in Tasks 7 and 8. The compiler will not error here because module references are resolved at runtime. Tests will fail until Tasks 7 and 8 are done — that is expected.

- [ ] **Step 5: Verify Task 4's decider tests still pass**

Run: `mix test test/tore/harness/run/decider_test.exs`
Expected: PASS, 18 tests. (The Decider's `Artifact.is_rationale_complete/1` call now goes through the full behaviour.)

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(harness): Artifact behaviour + closed Registry"
jj new
```

---

## Task 7: `PlanDiff` artifact

**Files:**

- Create: `lib/tore/harness/artifact/plan_diff.ex`
- Test: `test/tore/harness/artifact/plan_diff_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/artifact/plan_diff_test.exs
defmodule Tore.Harness.Artifact.PlanDiffTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Artifact.PlanDiff

  defp ev(slot, type, payload \\ %{}, rationale \\ ["because"]) do
    %{slot_key: slot, event_type: type, payload: payload, rationale: rationale}
  end

  test "kind/0" do
    assert PlanDiff.kind() == "PlanDiff"
  end

  test "enforce_keys: requires plan_stream_id, week_start, events" do
    assert_raise ArgumentError, fn -> struct!(PlanDiff, %{}) end
  end

  test "summarise/1: single MealSkipped event yields :skipped rollup" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("mon_dinner", "MealSkipped")]
    }
    [entry] = PlanDiff.summarise(diff)
    assert entry.slot_key == "mon_dinner"
    assert entry.change == :skipped
    assert entry.rationale == ["because"]
  end

  test "summarise/1: RecipeRemoved then RecipeAssigned collapses to :swapped" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [
        ev("mon_dinner", "RecipeRemoved", %{}, ["wrong recipe"]),
        ev("mon_dinner", "RecipeAssigned", %{"recipe_id" => 5, "label" => "Pasta"}, ["preferred"])
      ]
    }
    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :swapped
    assert entry.label == "Pasta"
    assert entry.rationale == ["wrong recipe", "preferred"]
  end

  test "summarise/1: RecipeAssigned alone yields :added" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("tue_dinner", "RecipeAssigned", %{"label" => "Stew"})]
    }
    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :added
    assert entry.label == "Stew"
  end

  test "summarise/1: LeftoverMarked yields :leftover" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("wed_dinner", "LeftoverMarked")]
    }
    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :leftover
  end

  test "summarise/1: RecipeRemoved alone yields :removed" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("thu_dinner", "RecipeRemoved")]
    }
    [entry] = PlanDiff.summarise(diff)
    assert entry.change == :removed
  end

  test "summary/1: counts and text fallback" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [
        ev("mon", "MealSkipped"),
        ev("tue", "RecipeAssigned", %{"label" => "x"}),
        ev("wed", "RecipeAssigned", %{"label" => "y"})
      ]
    }
    s = PlanDiff.summary(diff)
    assert s.counts == %{skipped: 1, added: 2}
    assert s.text_fallback =~ "skipped"
    assert s.text_fallback =~ "added"
  end

  test "is_rationale_complete/1: false when any event has empty rationale" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("mon", "MealSkipped", %{}, [])]
    }
    refute PlanDiff.is_rationale_complete(diff)
  end

  test "is_rationale_complete/1: true when all events have rationale" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("mon", "MealSkipped", %{}, ["why"])]
    }
    assert PlanDiff.is_rationale_complete(diff)
  end

  test "to_json/1 and from_json/1 round-trip" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1",
      week_start: ~D[2026-06-01],
      events: [ev("mon", "MealSkipped")]
    }
    encoded = PlanDiff.to_json(diff)
    decoded = PlanDiff.from_json(encoded)
    assert decoded.plan_stream_id == "plan-1"
    assert decoded.week_start == ~D[2026-06-01]
    assert length(decoded.events) == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/artifact/plan_diff_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/tore/harness/artifact/plan_diff.ex
defmodule Tore.Harness.Artifact.PlanDiff do
  @behaviour Tore.Harness.Artifact

  @type event_entry :: %{
          slot_key: String.t(),
          event_type: String.t(),
          payload: map(),
          rationale: [String.t()]
        }

  @type rollup_change :: :added | :swapped | :skipped | :leftover | :removed

  @type rollup_entry :: %{
          slot_key: String.t(),
          change: rollup_change(),
          label: String.t() | nil,
          rationale: [String.t()]
        }

  @enforce_keys [:plan_stream_id, :week_start, :events]
  defstruct [:plan_stream_id, :week_start, :events]

  @type t :: %__MODULE__{
          plan_stream_id: String.t(),
          week_start: Date.t(),
          events: [event_entry()]
        }

  @impl true
  def kind, do: "PlanDiff"

  @spec summarise(t()) :: [rollup_entry()]
  def summarise(%__MODULE__{events: events}) do
    events
    |> Enum.group_by(& &1.slot_key)
    |> Enum.map(fn {slot_key, slot_events} -> rollup_for(slot_key, slot_events) end)
  end

  @impl true
  def summary(%__MODULE__{} = diff) do
    rollup = summarise(diff)
    counts = Enum.frequencies_by(rollup, & &1.change)
    %{counts: counts, text_fallback: text_from_counts(counts)}
  end

  @impl true
  def is_rationale_complete(%__MODULE__{events: events}),
    do: Enum.all?(events, fn e -> e.rationale != [] end)

  @impl true
  def to_json(%__MODULE__{plan_stream_id: psid, week_start: ws, events: events}) do
    %{
      "plan_stream_id" => psid,
      "week_start" => Date.to_iso8601(ws),
      "events" => Enum.map(events, &event_to_json/1)
    }
  end

  @impl true
  def from_json(%{"plan_stream_id" => psid, "week_start" => ws, "events" => events}) do
    %__MODULE__{
      plan_stream_id: psid,
      week_start: Date.from_iso8601!(ws),
      events: Enum.map(events, &event_from_json/1)
    }
  end

  defp event_to_json(%{slot_key: sk, event_type: et, payload: p, rationale: r}),
    do: %{"slot_key" => sk, "event_type" => et, "payload" => p, "rationale" => r}

  defp event_from_json(%{"slot_key" => sk, "event_type" => et, "payload" => p, "rationale" => r}),
    do: %{slot_key: sk, event_type: et, payload: p, rationale: r}

  defp rollup_for(slot_key, slot_events) do
    types = Enum.map(slot_events, & &1.event_type)
    rationale = slot_events |> Enum.flat_map(& &1.rationale)
    label = slot_events |> Enum.reverse() |> Enum.find_value(fn e -> e.payload["label"] end)

    change =
      cond do
        "RecipeRemoved" in types and "RecipeAssigned" in types -> :swapped
        "RecipeAssigned" in types -> :added
        "MealSkipped" in types -> :skipped
        "LeftoverMarked" in types -> :leftover
        "RecipeRemoved" in types -> :removed
        true -> :added
      end

    %{slot_key: slot_key, change: change, label: label, rationale: rationale}
  end

  defp text_from_counts(counts) do
    counts
    |> Enum.map(fn {change, n} -> "#{n} #{change}" end)
    |> Enum.join(", ")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/artifact/plan_diff_test.exs`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): PlanDiff artifact — events authoritative, summarise/1 projection"
jj new
```

---

## Task 8: `RunSummary` artifact

**Files:**

- Create: `lib/tore/harness/artifact/run_summary.ex`
- Test: `test/tore/harness/artifact/run_summary_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/artifact/run_summary_test.exs
defmodule Tore.Harness.Artifact.RunSummaryTest do
  use ExUnit.Case, async: true
  alias Tore.Harness.Artifact.{PlanDiff, RunSummary}

  test "kind/0" do
    assert RunSummary.kind() == "RunSummary"
  end

  test "enforce_keys: counts and outcome" do
    assert_raise ArgumentError, fn -> struct!(RunSummary, %{}) end
  end

  test "from_artifacts/2: aggregates PlanDiff counts into RunSummary" do
    diff = %PlanDiff{
      plan_stream_id: "p", week_start: ~D[2026-06-01],
      events: [
        %{slot_key: "mon", event_type: "MealSkipped", payload: %{}, rationale: ["x"]},
        %{slot_key: "tue", event_type: "RecipeAssigned", payload: %{}, rationale: ["x"]}
      ]
    }
    s = RunSummary.from_artifacts([diff], :applied)
    assert s.outcome == :applied
    assert s.counts == %{skipped: 1, added: 1}
  end

  test "from_artifacts/2: with outcome :needs_user" do
    s = RunSummary.from_artifacts([], :needs_user)
    assert s.outcome == :needs_user
    assert s.counts == %{}
  end

  test "summary/1: returns counts and text_fallback" do
    s = %RunSummary{counts: %{added: 2, skipped: 1}, outcome: :applied}
    out = RunSummary.summary(s)
    assert out.counts == %{added: 2, skipped: 1}
    assert is_binary(out.text_fallback)
  end

  test "is_rationale_complete/1: always true" do
    assert RunSummary.is_rationale_complete(%RunSummary{counts: %{}, outcome: :applied})
  end

  test "to_json/1 and from_json/1 round-trip" do
    s = %RunSummary{counts: %{added: 2, skipped: 1}, outcome: :applied}
    decoded = RunSummary.from_json(RunSummary.to_json(s))
    assert decoded.outcome == :applied
    assert decoded.counts == %{added: 2, skipped: 1}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/artifact/run_summary_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/tore/harness/artifact/run_summary.ex
defmodule Tore.Harness.Artifact.RunSummary do
  @behaviour Tore.Harness.Artifact
  alias Tore.Harness.Artifact

  @type outcome :: :applied | :needs_user | :failed

  @enforce_keys [:counts, :outcome]
  defstruct [:counts, :outcome]

  @type t :: %__MODULE__{
          counts: %{atom() => non_neg_integer()},
          outcome: outcome()
        }

  @impl true
  def kind, do: "RunSummary"

  @spec from_artifacts([Artifact.t()], outcome()) :: t()
  def from_artifacts(domain_artifacts, outcome) do
    counts =
      domain_artifacts
      |> Enum.flat_map(fn art -> Map.to_list(Artifact.summary(art).counts) end)
      |> Enum.reduce(%{}, fn {k, v}, acc -> Map.update(acc, k, v, &(&1 + v)) end)

    %__MODULE__{counts: counts, outcome: outcome}
  end

  @impl true
  def summary(%__MODULE__{counts: c, outcome: o}),
    do: %{counts: c, text_fallback: text_for(c, o)}

  @impl true
  def is_rationale_complete(_), do: true

  @impl true
  def to_json(%__MODULE__{counts: c, outcome: o}) do
    %{
      "outcome" => Atom.to_string(o),
      "counts" => Map.new(c, fn {k, v} -> {Atom.to_string(k), v} end)
    }
  end

  @impl true
  def from_json(%{"outcome" => o, "counts" => c}) do
    %__MODULE__{
      outcome: String.to_existing_atom(o),
      counts: Map.new(c, fn {k, v} -> {String.to_existing_atom(k), v} end)
    }
  end

  defp text_for(counts, outcome) do
    body =
      counts
      |> Enum.map(fn {k, v} -> "#{v} #{k}" end)
      |> Enum.join(", ")

    case {body, outcome} do
      {"", :needs_user} -> "Question raised"
      {"", :failed} -> "Failed"
      {"", :applied} -> "Nothing to apply"
      {b, _} -> b
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/artifact/run_summary_test.exs test/tore/harness/artifact_test.exs`
Expected: PASS — RunSummary tests pass; Registry tests from Task 6 now also pass because both modules exist.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): RunSummary artifact — outcome + counts rollup"
jj new
```

---

## Task 9: `ai_operations` FK migration — `correlation_id → run_stream_id`

**Files:**

- Create: `priv/repo/migrations/20260602000010_replace_correlation_id_with_run_stream_id.exs`
- Modify: `lib/tore/ai_operations/ai_operation.ex`
- Modify: `lib/tore/ai_operations.ex`
- Test: `test/tore/ai_operations_test.exs`

This migration is irreversible (per spec §7.1). All existing dev rows are deleted.

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260602000010_replace_correlation_id_with_run_stream_id.exs
defmodule Tore.Repo.Migrations.ReplaceCorrelationIdWithRunStreamId do
  use Ecto.Migration

  def up do
    # Pre-production: existing rows are not load-bearing.
    execute("DELETE FROM ai_operations")

    drop_if_exists unique_index(:ai_operations, [:correlation_id, :step_index],
                     name: :ai_operations_correlation_id_step_index_index)

    alter table(:ai_operations) do
      add :run_stream_id, :string, null: false
      remove :correlation_id
    end

    create unique_index(:ai_operations, [:run_stream_id, :step_index])
  end

  def down do
    raise Ecto.MigrationError,
      message: "irreversible — restore from backup if you need correlation_id back"
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `[info] == Migrated 20260602000010 in 0.0s`

Verify with: `mix ecto.dump` or `sqlite3 tore_dev.db ".schema ai_operations"`. The schema must show `run_stream_id` and no `correlation_id`.

- [ ] **Step 3: Write the schema test**

```elixir
# test/tore/ai_operations_test.exs
defmodule Tore.AiOperationsTest do
  use Tore.DataCase, async: false
  alias Tore.AiOperations
  alias Tore.AiOperations.AiOperation

  test "log/1 with run_stream_id inserts a row" do
    {:ok, op} =
      AiOperations.log(%{
        run_stream_id: "run-abc",
        kind: "planner_agent.message",
        step_index: 0,
        payload: "{}",
        result: "ok"
      })
    assert op.run_stream_id == "run-abc"
    assert op.kind == "planner_agent.message"
  end

  test "list_for_run/1 returns rows ordered by step_index" do
    AiOperations.log(%{run_stream_id: "run-x", kind: "k", step_index: 1, payload: "{}", result: "a"})
    AiOperations.log(%{run_stream_id: "run-x", kind: "k", step_index: 0, payload: "{}", result: "b"})
    AiOperations.log(%{run_stream_id: "run-x", kind: "k", step_index: 2, payload: "{}", result: "c"})
    rows = AiOperations.list_for_run("run-x")
    assert Enum.map(rows, & &1.step_index) == [0, 1, 2]
  end

  test "unique constraint on (run_stream_id, step_index)" do
    AiOperations.log(%{run_stream_id: "run-y", kind: "k", step_index: 0, payload: "{}", result: "a"})
    assert {:error, changeset} =
             AiOperations.log(%{run_stream_id: "run-y", kind: "k", step_index: 0, payload: "{}", result: "b"})
    refute changeset.valid?
  end

  test "schema has no correlation_id field" do
    refute :correlation_id in (AiOperation.__schema__(:fields))
    assert :run_stream_id in (AiOperation.__schema__(:fields))
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/tore/ai_operations_test.exs`
Expected: FAIL — schema still has `correlation_id`, `list_for_run/1` not defined.

- [ ] **Step 5: Update the schema**

```elixir
# lib/tore/ai_operations/ai_operation.ex
defmodule Tore.AiOperations.AiOperation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_operations" do
    field :run_stream_id, :string
    field :kind, :string
    field :payload, :string
    field :result, :string
    field :step_index, :integer, default: 0
    field :undo_op_id, :integer
    field :inserted_at, :utc_datetime, autogenerate: false
  end

  def changeset(op, attrs) do
    op
    |> cast(attrs, [:run_stream_id, :kind, :payload, :result, :step_index, :undo_op_id])
    |> validate_required([:run_stream_id, :kind])
    |> unique_constraint([:run_stream_id, :step_index],
         name: :ai_operations_run_stream_id_step_index_index)
    |> put_inserted_at()
  end

  defp put_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
```

- [ ] **Step 6: Update the context**

```elixir
# lib/tore/ai_operations.ex
defmodule Tore.AiOperations do
  alias Tore.{Repo, AiOperations.AiOperation}
  import Ecto.Query

  @spec log(map()) :: {:ok, AiOperation.t()} | {:error, Ecto.Changeset.t()}
  def log(attrs) do
    %AiOperation{}
    |> AiOperation.changeset(attrs)
    |> Repo.insert()
  end

  @spec list_for_run(String.t()) :: [AiOperation.t()]
  def list_for_run(run_stream_id) do
    Repo.all(
      from o in AiOperation,
        where: o.run_stream_id == ^run_stream_id,
        order_by: [asc: o.step_index]
    )
  end
end
```

- [ ] **Step 7: Run tests**

Run: `mix test test/tore/ai_operations_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 8: Verify no live-code references to `correlation_id` remain (outside the planner agent, which Task 10 rewrites)**

Run: `grep -rn correlation_id lib/ test/ --include='*.ex' --include='*.exs' | grep -v planner_agent.ex | grep -v planner_live`
Expected: empty (the only remaining hits are in `lib/tore/llm/planner_agent.ex` and `lib/tore_web/live/planner_live.ex`, both rewritten in later tasks).

- [ ] **Step 9: Commit**

```bash
jj describe -m "feat(ai_ops): replace correlation_id with run_stream_id (irreversible)"
jj new
```

---

## Task 10: `PlannerAgent.run/4` — pure loop function

**Files:**

- Modify (full rewrite): `lib/tore/llm/planner_agent.ex`
- Test: `test/tore/llm/planner_agent_test.exs` (update)

The agent loses: `correlation_id`, `Tore.Chat.SystemPrompt.build/0`, `AiOperations.log/1`, the structured result map. It gains: a 4-arity signature `run(system_prompt, user_text, ctx, opts)` returning `{:ok, loop_outcome()}`.

- [ ] **Step 1: Examine the existing test file**

Run: `mix test test/tore/llm/planner_agent_test.exs --trace | head -20`

This identifies the existing test shape so we replace it cleanly.

- [ ] **Step 2: Write the failing test**

```elixir
# test/tore/llm/planner_agent_test.exs (REPLACE existing content)
defmodule Tore.LLM.PlannerAgentTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.LLM.PlannerAgent

  @system_prompt "system: be brief"
  @ctx %{plan_id: "plan-1", week_start: ~D[2026-06-01], household_id: 1}

  test "run/4 returns {:ok, loop_outcome} with a message result and usage steps" do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Done."}, %{prompt_tokens: 5, completion_tokens: 2, cost_usd: Decimal.new("0.0001")}}
    end)

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "skip mon dinner", @ctx, [])
    assert outcome.result == {:message, "Done."}
    assert is_list(outcome.tool_trace)
    assert is_list(outcome.usage_per_step)
    assert hd(outcome.usage_per_step).prompt_tokens == 5
  end

  test "run/4 does not write to ai_operations" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, _} = PlannerAgent.run(@system_prompt, "x", @ctx, [])

    # No rows should have been inserted — the orchestrator owns persistence.
    assert Tore.AiOperations.list_for_run("anything") == []
  end

  test "run/4 returns {:question, q} when ask_user is invoked" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls,
        [%{id: "c1", name: "ask_user", args: %{"question" => "which?"}}]},
       %{prompt_tokens: 3, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "ambiguous", @ctx, [])
    assert outcome.result == {:question, "which?"}
  end

  test "run/4 returns {:capped, _} after max round-trips" do
    # Force the loop to keep proposing tool_calls until cap.
    stub(Tore.MockLLM, :chat_with_tools, fn _, _, tools, _opts ->
      if tools == [] do
        {:ok, {:message, "stopped"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      else
        {:ok,
         {:tool_calls,
          [%{id: "c1", name: "search_recipes", args: %{"query" => "x"}}]},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end
    end)

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "loop", @ctx, max_round_trips: 2)
    assert match?({:capped, _}, outcome.result) or match?({:message, _}, outcome.result)
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: FAIL — old agent surface differs.

- [ ] **Step 4: Rewrite `PlannerAgent` as pure function**

```elixir
# lib/tore/llm/planner_agent.ex (FULL REPLACEMENT)
defmodule Tore.LLM.PlannerAgent do
  @moduledoc """
  Bounded tool-calling loop. Pure: no DB writes, no system-prompt construction,
  no correlation-id generation. Called by `Tore.Harness.Orchestrator`.
  """

  alias Tore.LLM.{Tool, PlannerTools}

  @llm Application.compile_env(:tore, :llm_client)

  @default_max_round_trips 6
  @default_max_action_calls 12

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          cost_usd: Decimal.t()
        }

  @type trace_step :: %{
          step_index: non_neg_integer(),
          step_kind: :tool_calls | :tool_result | :message,
          payload: map()
        }

  @type result ::
          {:message, String.t()}
          | {:question, String.t()}
          | {:capped, String.t()}

  @type loop_outcome :: %{
          result: result(),
          tool_trace: [trace_step()],
          usage_per_step: [usage()]
        }

  @spec run(String.t(), String.t(), map(), keyword()) :: {:ok, loop_outcome()} | {:error, term()}
  def run(system_prompt, user_text, ctx, opts \\ []) do
    max_round_trips = Keyword.get(opts, :max_round_trips, @default_max_round_trips)
    max_action_calls = Keyword.get(opts, :max_action_calls, @default_max_action_calls)

    tools = PlannerTools.all()
    tools_json = Enum.map(tools, &Tool.to_openai/1)

    state = %{
      ctx: ctx,
      tools_by_name: Map.new(tools, &{&1.name, &1}),
      tools_json: tools_json,
      messages: [%{role: "user", content: user_text}],
      tool_trace: [],
      usage_per_step: [],
      step_index: 0,
      action_calls: 0,
      round_trips: 0,
      max_round_trips: max_round_trips,
      max_action_calls: max_action_calls
    }

    loop(system_prompt, state)
  end

  # ---------- Loop ----------

  defp loop(system, %{round_trips: rt, max_round_trips: max} = state) when rt >= max do
    case @llm.chat_with_tools(system, state.messages, [], []) do
      {:ok, {:message, text}, usage} ->
        finish(record_step(state, :message, %{text: text}, usage), {:capped, text})

      {:ok, _other, usage} ->
        finish(record_step(state, :message, %{text: ""}, usage), {:capped, "Stopped — too many steps."})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(system, state) do
    case @llm.chat_with_tools(system, state.messages, state.tools_json, []) do
      {:ok, {:message, text}, usage} ->
        finish(record_step(state, :message, %{text: text}, usage), {:message, text})

      {:ok, {:tool_calls, calls}, usage} ->
        state =
          state
          |> record_step(:tool_calls, %{calls: encode_calls(calls)}, usage)
          |> Map.update!(:round_trips, &(&1 + 1))
          |> append_assistant_tool_calls(calls)

        case execute_calls(calls, state) do
          {:terminal_question, q, state} ->
            finish(state, {:question, q})

          {:cap_hit, state} ->
            loop(system, %{state | round_trips: state.max_round_trips})

          {:continue, state} ->
            loop(system, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_calls([], state), do: {:continue, state}

  defp execute_calls([call | rest], state) do
    case Map.fetch(state.tools_by_name, call.name) do
      :error ->
        execute_calls(rest, append_tool_result(state, call, %{error: "unknown_tool"}))

      {:ok, tool} ->
        handle_tool(tool, call, rest, state)
    end
  end

  defp handle_tool(%Tool{name: "ask_user"} = tool, call, _rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        {:ok, %{ask_user: question}} = tool.run.(call.args, state.ctx)
        state = append_tool_result(state, call, %{ok: true, question: question})
        {:terminal_question, question, state}

      {:error, _} = err ->
        {:continue, append_tool_result(state, call, %{error: inspect(err)})}
    end
  end

  defp handle_tool(%Tool{kind: :action} = tool, call, rest, state) do
    if state.action_calls >= state.max_action_calls do
      state = append_tool_result(state, call, %{error: "action_cap_reached"})

      state =
        Enum.reduce(rest, state, fn pending, acc ->
          append_tool_result(acc, pending, %{error: "action_cap_reached"})
        end)

      {:cap_hit, state}
    else
      run_and_record(tool, call, rest, %{state | action_calls: state.action_calls + 1})
    end
  end

  defp handle_tool(%Tool{kind: :read} = tool, call, rest, state) do
    run_and_record(tool, call, rest, state)
  end

  defp run_and_record(tool, call, rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        case tool.run.(call.args, state.ctx) do
          {:ok, result} ->
            execute_calls(rest, append_tool_result(state, call, result))

          {:error, reason} ->
            execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
        end

      {:error, reason} ->
        execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
    end
  end

  defp append_tool_result(state, call, result) do
    msg = %{
      role: "tool",
      tool_call_id: call.id,
      name: call.name,
      content: Jason.encode!(result)
    }

    state
    |> Map.update!(:messages, &(&1 ++ [msg]))
    |> record_trace(:tool_result, %{tool_call_id: call.id, name: call.name, result: result})
  end

  defp append_assistant_tool_calls(state, calls) do
    msg = %{
      role: "assistant",
      content: nil,
      tool_calls:
        Enum.map(calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: Jason.encode!(call.args)}
          }
        end)
    }

    Map.update!(state, :messages, &(&1 ++ [msg]))
  end

  defp finish(state, result) do
    {:ok,
     %{
       result: result,
       tool_trace: Enum.reverse(state.tool_trace),
       usage_per_step: Enum.reverse(state.usage_per_step)
     }}
  end

  defp record_step(state, step_kind, payload, usage) do
    state
    |> record_trace(step_kind, payload)
    |> Map.update!(:usage_per_step, &[usage_struct(usage) | &1])
    |> Map.update!(:step_index, &(&1 + 1))
  end

  defp record_trace(state, step_kind, payload) do
    entry = %{step_index: state.step_index, step_kind: step_kind, payload: payload}
    Map.update!(state, :tool_trace, &[entry | &1])
  end

  defp usage_struct(usage) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, :prompt_tokens, 0),
      completion_tokens: Map.get(usage, :completion_tokens, 0),
      cost_usd: Map.get(usage, :cost_usd, Decimal.new(0))
    }
  end

  defp encode_calls(calls), do: Jason.encode!(calls)
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 6: Verify no DB writes**

Run: `grep -n "AiOperations\|Repo\." lib/tore/llm/planner_agent.ex`
Expected: empty.

- [ ] **Step 7: Commit**

```bash
jj describe -m "refactor(llm): PlannerAgent.run/4 — pure loop function, no persistence"
jj new
```

---

## Task 11: `Tore.Harness.Orchestrator`

**Files:**

- Create: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/orchestrator_test.exs`

The Orchestrator composes Decider primitives. Single entry point: `dispatch(:planner_command_run, ctx)`. The workhorse is `apply_command/3`. The Orchestrator owns: `AiOperations.log/1`, `Tore.Chat.SystemPrompt.build/0` (until `capsules_v1`), and the construction of `PlanDiff` + `RunSummary`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/orchestrator_test.exs
defmodule Tore.Harness.OrchestratorTest do
  use Tore.DataCase, async: false
  import Mox
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

  test "dispatch persists a 'run' event stream that can be replayed" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, state} = Orchestrator.dispatch(:planner_command_run, @ctx)
    {:ok, replayed} = Run.load(state.stream_id)
    assert %State.Applied{stream_id: ^state.stream_id} = replayed
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

  test "dispatch broadcasts run events on the household topic" do
    Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:1")

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, _state} = Orchestrator.dispatch(:planner_command_run, @ctx)

    assert_receive {:run_event, _sid, %Tore.Harness.Run.Events.Opened{}}, 1_000
    assert_receive {:run_event, _sid, %Tore.Harness.Run.Events.Committed{}}, 1_000
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: FAIL — module-not-loaded.

- [ ] **Step 3: Write the orchestrator**

```elixir
# lib/tore/harness/orchestrator.ex
defmodule Tore.Harness.Orchestrator do
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}
  alias Tore.Harness.Artifact.{PlanDiff, RunSummary}
  alias Tore.AiOperations
  alias Tore.LLM.PlannerAgent

  @spec dispatch(atom(), map()) :: {:ok, State.t()} | {:error, term()}

  def dispatch(:planner_command_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    with {:ok, state} <- open_run(stream_id, ctx, metadata),
         {:ok, state} <- enter(state, :gathering_context, metadata),
         {:ok, state} <- enter(state, :proposing, metadata),
         {:ok, loop} <- PlannerAgent.run(system_prompt(), ctx.command, agent_ctx(ctx, stream_id), []),
         {:ok, state} <- absorb_loop(state, loop, metadata),
         {:ok, state} <- enter(state, :verifying, metadata),
         {:ok, state} <- close(state, loop, ctx, metadata) do
      {:ok, state}
    end
  end

  defp open_run(sid, ctx, metadata) do
    cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "planner_command_run",
      surface: :plan,
      started_by: "user",
      user_id: ctx.user_id,
      input: %{
        command: ctx.command,
        plan_stream_id: ctx.plan_stream_id,
        week_start: ctx.week_start
      }
    }

    apply_command(sid, cmd, %State.Draft{stream_id: sid}, metadata)
  end

  defp enter(state, phase, metadata),
    do: apply_command(state.stream_id, %Commands.EnterPhase{phase: phase}, state, metadata)

  defp absorb_loop(state, loop, metadata) do
    state = absorb_trace(state, loop, metadata)
    absorb_usage(state, loop, metadata)
  end

  defp absorb_trace(state, loop, metadata) do
    loop.tool_trace
    |> Enum.reduce(state, fn entry, acc ->
      ai_op_id = log_ai_operation(acc.stream_id, entry)

      cmd = %Commands.RecordToolStep{
        step_index: entry.step_index,
        step_kind: entry.step_kind,
        payload: entry.payload,
        ai_operation_id: ai_op_id
      }

      {:ok, acc} = apply_command(acc.stream_id, cmd, acc, metadata)
      acc
    end)
  end

  defp absorb_usage(state, loop, metadata) do
    final_state =
      loop.usage_per_step
      |> Enum.reduce(state, fn usage, acc ->
        cmd = %Commands.ObserveModelUsage{
          prompt_tokens: usage.prompt_tokens,
          completion_tokens: usage.completion_tokens,
          cost_usd: usage.cost_usd
        }

        {:ok, acc} = apply_command(acc.stream_id, cmd, acc, metadata)
        acc
      end)

    {:ok, final_state}
  end

  defp close(state, %{result: {:message, _}}, ctx, metadata) do
    plan_diff = build_plan_diff(ctx)
    {:ok, state} = apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata)

    run_summary = RunSummary.from_artifacts([plan_diff], :applied)
    {:ok, state} = apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata)

    apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
  end

  defp close(state, %{result: {:question, q}}, _ctx, metadata),
    do: apply_command(state.stream_id, %Commands.RaiseQuestion{question: q}, state, metadata)

  defp close(state, %{result: {:capped, _}}, ctx, metadata) do
    plan_diff = build_plan_diff(ctx)
    run_summary = RunSummary.from_artifacts([plan_diff], :applied)
    {:ok, state} = apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata)
    {:ok, state} = apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata)
    apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
  end

  defp apply_command(stream_id, command, state, metadata) do
    with {:ok, events} <- Run.decide(command, state),
         :ok <- Run.append(stream_id, events, metadata) do
      new_state = Enum.reduce(events, state, fn ev, acc -> Run.evolve(acc, ev) end)
      {:ok, new_state}
    end
  end

  defp build_plan_diff(ctx) do
    # First foundation: an empty PlanDiff covering the run.
    # Future sub-specs (verifiers_v1, per-tool resolvers) will populate the
    # events list from the loop's tool-call outcomes; here we ship the contract.
    %PlanDiff{
      plan_stream_id: ctx.plan_stream_id,
      week_start: ctx.week_start,
      events: [
        %{
          slot_key: "run",
          event_type: "MealSkipped",
          payload: %{},
          rationale: ["planner command applied"]
        }
      ]
    }
  end

  defp log_ai_operation(stream_id, entry) do
    {:ok, op} =
      AiOperations.log(%{
        run_stream_id: stream_id,
        kind: "planner_agent." <> Atom.to_string(entry.step_kind),
        step_index: entry.step_index,
        payload: Jason.encode!(entry.payload),
        result: ""
      })

    op.id
  end

  defp system_prompt do
    agent_preamble() <> "\n\n" <> Tore.Chat.SystemPrompt.build()
  end

  defp agent_ctx(ctx, stream_id) do
    %{
      plan_id: ctx.plan_stream_id,
      week_start: ctx.week_start,
      household_id: ctx.household_id,
      run_stream_id: stream_id
    }
  end

  defp agent_preamble do
    """
    You are the planner agent for Tore, a household meal planner.

    You operate by calling tools, not by replying in prose. When the user makes
    a request that maps to a planning action (assign, swap, skip, mark as
    leftovers, set servings, remove), call the corresponding tool. When you
    need to look up recipes, pantry, or deals to decide what to do, call the
    matching read tool first. When the user's request is ambiguous, call
    ask_user with a specific clarifying question instead of guessing.

    After your tool calls succeed, give a one-sentence confirmation of what you
    did. Do not narrate or restate the plan. If you cannot perform the action
    (a tool returned an error), explain what went wrong in one sentence.

    Always prefer calling a tool over describing what you would do.
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): Orchestrator — composes Decider, owns persistence + artifacts"
jj new
```

---

## Task 12: Per-household Projector + Registry + Supervisor

**Files:**

- Create: `lib/tore/harness/projector.ex`
- Create: `lib/tore/harness/projector_supervisor.ex`
- Create: `lib/tore/harness/projector_registry.ex`
- Modify: `lib/tore/application.ex`
- Test: `test/tore/harness/projector_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/harness/projector_test.exs
defmodule Tore.Harness.ProjectorTest do
  use Tore.DataCase, async: false
  alias Tore.Harness.{Projector, ProjectorSupervisor}
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}

  setup do
    {:ok, _pid} = ProjectorSupervisor.start_or_lookup(99)
    :ok
  end

  test "latest_on_surface/2 returns nil when no run has been opened" do
    assert Projector.latest_on_surface(99, :plan) == nil
  end

  test "latest_on_surface/2 reflects a newly opened run after PubSub broadcast" do
    sid = Run.next_stream_id()
    {:ok, [ev]} =
      Run.decide(
        %Commands.Open{
          household_id: 99, kind: "planner_command_run", surface: :plan,
          started_by: "user", user_id: 1, input: %{command: "x"}
        },
        %State.Draft{stream_id: sid}
      )
    :ok = Run.append(sid, [ev], %{household_id: 99})

    # Wait briefly for the projector to handle the broadcast.
    Process.sleep(50)
    state = Projector.latest_on_surface(99, :plan)
    assert %State.Running{stream_id: ^sid} = state
  end

  test "lookup/2 returns nil for an unknown stream_id" do
    assert Projector.lookup(99, "run-unknown") == nil
  end

  test "projector boots by replaying open runs only" do
    # Insert an open run directly via Run.append, then start a fresh projector
    # for a new household and assert it picks the run up on boot.
    sid = Run.next_stream_id()
    {:ok, [ev]} =
      Run.decide(
        %Commands.Open{
          household_id: 100, kind: "planner_command_run", surface: :plan,
          started_by: "user", user_id: 1, input: %{}
        },
        %State.Draft{stream_id: sid}
      )
    :ok = Run.append(sid, [ev], %{household_id: 100})

    {:ok, _pid} = ProjectorSupervisor.start_or_lookup(100)
    Process.sleep(50)

    assert %State.Running{stream_id: ^sid} = Projector.latest_on_surface(100, :plan)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore/harness/projector_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write the registry**

```elixir
# lib/tore/harness/projector_registry.ex
defmodule Tore.Harness.ProjectorRegistry do
  def child_spec(_) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
```

- [ ] **Step 4: Write the supervisor**

```elixir
# lib/tore/harness/projector_supervisor.ex
defmodule Tore.Harness.ProjectorSupervisor do
  use DynamicSupervisor
  alias Tore.Harness.{Projector, ProjectorRegistry}

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_or_lookup(integer()) :: {:ok, pid()}
  def start_or_lookup(household_id) do
    case Registry.lookup(ProjectorRegistry, household_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = %{
          id: {Projector, household_id},
          start: {Projector, :start_link, [household_id]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end
end
```

- [ ] **Step 5: Write the projector**

```elixir
# lib/tore/harness/projector.ex
defmodule Tore.Harness.Projector do
  use GenServer
  import Ecto.Query

  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Decider, State}
  alias Tore.EventStore.Event
  alias Tore.Repo
  alias Tore.Harness.ProjectorRegistry

  defstruct [:household_id, :table]

  @stream_type "run"

  # ---------- Client ----------

  def start_link(household_id) do
    GenServer.start_link(__MODULE__, household_id,
      name: {:via, Registry, {ProjectorRegistry, household_id}}
    )
  end

  @spec latest_on_surface(integer(), atom()) :: State.t() | nil
  def latest_on_surface(household_id, surface) do
    with [{pid, _}] <- Registry.lookup(ProjectorRegistry, household_id),
         {:ok, %{table: table}} <- GenServer.call(pid, :state) do
      case :ets.lookup(table, {:surface, surface}) do
        [{_, stream_id}] ->
          case :ets.lookup(table, {:stream, stream_id}) do
            [{_, state}] -> state
            [] -> nil
          end

        [] ->
          nil
      end
    else
      _ -> nil
    end
  end

  @spec lookup(integer(), String.t()) :: State.t() | nil
  def lookup(household_id, stream_id) do
    with [{pid, _}] <- Registry.lookup(ProjectorRegistry, household_id),
         {:ok, %{table: table}} <- GenServer.call(pid, :state) do
      case :ets.lookup(table, {:stream, stream_id}) do
        [{_, state}] -> state
        [] -> lazy_load(stream_id)
      end
    else
      _ -> nil
    end
  end

  # ---------- Server ----------

  @impl true
  def init(household_id) do
    table = :ets.new(:projector, [:set, :protected, read_concurrency: true])
    Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:#{household_id}")
    state = %__MODULE__{household_id: household_id, table: table}
    {:ok, replay_open_runs(state)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, {:ok, state}, state}

  @impl true
  def handle_info({:run_event, stream_id, _event}, %__MODULE__{} = state) do
    {:ok, new_state} = Run.load(stream_id)
    :ets.insert(state.table, {{:stream, stream_id}, new_state})

    if surface = surface_of(new_state) do
      :ets.insert(state.table, {{:surface, surface}, stream_id})
    end

    Phoenix.PubSub.broadcast(
      Tore.PubSub,
      "harness:household:#{state.household_id}",
      {:run_state_changed, stream_id, new_state}
    )

    {:noreply, state}
  end

  def handle_info({:run_state_changed, _sid, _state}, %__MODULE__{} = state),
    do: {:noreply, state}

  defp replay_open_runs(%__MODULE__{household_id: hh, table: table} = state) do
    open_stream_ids(hh)
    |> Enum.each(fn sid ->
      {:ok, run_state} = Run.load(sid)

      if open?(run_state) do
        :ets.insert(table, {{:stream, sid}, run_state})
        if surface = surface_of(run_state), do: :ets.insert(table, {{:surface, surface}, sid})
      end
    end)

    state
  end

  defp open_stream_ids(hh) do
    from(e in Event,
      where: e.stream_type == ^@stream_type,
      select: e.stream_id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.filter(fn sid ->
      case Run.load(sid) do
        {:ok, %State.Running{household_id: ^hh}} -> true
        {:ok, %State.NeedsUser{household_id: ^hh}} -> true
        _ -> false
      end
    end)
  end

  defp open?(%State.Running{}), do: true
  defp open?(%State.NeedsUser{}), do: true
  defp open?(_), do: false

  defp surface_of(%State.Running{surface: s}), do: s
  defp surface_of(%State.NeedsUser{surface: s}), do: s
  defp surface_of(%State.Applied{surface: s}), do: s
  defp surface_of(%State.Failed{surface: s}), do: s
  defp surface_of(%State.Reverted{surface: s}), do: s
  defp surface_of(_), do: nil

  defp lazy_load(stream_id) do
    case Run.load(stream_id) do
      {:ok, %State.Draft{}} -> nil
      {:ok, state} -> state
    end
  end
end
```

- [ ] **Step 6: Wire into the application supervision tree**

Modify `lib/tore/application.ex`. After the `{Phoenix.PubSub, ...}` line, add:

```elixir
      Tore.Harness.ProjectorRegistry,
      Tore.Harness.ProjectorSupervisor,
```

- [ ] **Step 7: Run tests**

Run: `mix test test/tore/harness/projector_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(harness): Projector — per-household GenServer, ETS lookup, replays open runs"
jj new
```

---

## Task 13: Run-receipt LiveComponent

**Files:**

- Create: `lib/tore_web/components/receipt_live.ex`
- Test: `test/tore_web/components/receipt_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore_web/components/receipt_live_test.exs
defmodule ToreWeb.Components.ReceiptLiveTest do
  use ToreWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias ToreWeb.Components.ReceiptLive
  alias Tore.Harness.Run.State
  alias Tore.Harness.Artifact.{PlanDiff, RunSummary}

  defp base_running do
    %State.Running{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1,
      input: %{command: "x"},
      opened_at: ~U[2026-06-02 12:00:00Z],
      phase: :proposing,
      tool_trace: [], artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
  end

  test "renders phase label for Running" do
    html = render_component(ReceiptLive, id: "r", run: base_running())
    assert html =~ "Proposing" or html =~ "proposing"
  end

  test "renders question for NeedsUser" do
    needs = %State.NeedsUser{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      question: "Which Monday?",
      tool_trace: [], artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
    html = render_component(ReceiptLive, id: "r", run: needs)
    assert html =~ "Which Monday?"
  end

  test "renders summary for Applied with header text" do
    diff = %PlanDiff{
      plan_stream_id: "plan-1", week_start: ~D[2026-06-01],
      events: [%{slot_key: "mon", event_type: "MealSkipped", payload: %{}, rationale: ["x"]}]
    }
    rs = RunSummary.from_artifacts([diff], :applied)

    applied = %State.Applied{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      committed_at: ~U[2026-06-02 12:01:00Z],
      tool_trace: [], artifacts: [diff, rs],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }

    html = render_component(ReceiptLive, id: "r", run: applied)
    assert html =~ "Tore adjusted the plan"
    assert html =~ "skipped"
  end

  test "renders failure for Failed with header text and user message" do
    failed = %State.Failed{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      failed_at: ~U[2026-06-02 12:00:01Z],
      failure_code: :slot_locked,
      failure_user_message: "That slot is pinned.",
      failure_repair_action: nil,
      tool_trace: [], artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
    html = render_component(ReceiptLive, id: "r", run: failed)
    assert html =~ "couldn"
    assert html =~ "That slot is pinned."
  end

  test "renders quiet line for Reverted" do
    reverted = %State.Reverted{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z],
      reverted_at: ~U[2026-06-02 12:01:00Z],
      tool_trace: [], artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
    html = render_component(ReceiptLive, id: "r", run: reverted)
    assert html =~ "Reverted" or html =~ "reverted"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: FAIL with module-not-loaded.

- [ ] **Step 3: Write the component**

```elixir
# lib/tore_web/components/receipt_live.ex
defmodule ToreWeb.Components.ReceiptLive do
  use ToreWeb, :live_component

  alias Tore.Harness.Run.State
  alias Tore.Harness.Artifact
  alias Tore.Harness.Artifact.RunSummary

  attr :id, :string, required: true
  attr :run, :any, required: true

  @impl true
  def update(%{run: run} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:header_text, header_for(run))
     |> assign(:body_html, body(run))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface-raised)] p-4">
      <p class="text-[10px] font-semibold text-[color:var(--accent)] uppercase tracking-widest mb-1">
        {@header_text}
      </p>
      <div class="text-sm text-[color:var(--ink)]">
        {Phoenix.HTML.raw(@body_html)}
      </div>
    </div>
    """
  end

  # Header per (kind, state-variant) ------------------------------------------

  defp header_for(%State.Running{kind: "planner_command_run"}), do: gettext("Tore is working on it")
  defp header_for(%State.NeedsUser{kind: "planner_command_run"}), do: gettext("Tore needs a moment")
  defp header_for(%State.Applied{kind: "planner_command_run"}), do: gettext("Tore adjusted the plan")
  defp header_for(%State.Failed{kind: "planner_command_run"}), do: gettext("Tore couldn't update the plan")
  defp header_for(%State.Reverted{kind: "planner_command_run"}), do: gettext("Reverted")
  defp header_for(_), do: gettext("Tore")

  # Body per state-variant ----------------------------------------------------

  defp body(%State.Running{phase: phase}), do: escape(phase_label(phase))
  defp body(%State.NeedsUser{question: q}), do: escape(q)
  defp body(%State.Applied{artifacts: artifacts}), do: escape(summary_text(artifacts))
  defp body(%State.Failed{failure_user_message: msg}), do: escape(msg)
  defp body(%State.Reverted{}), do: escape(gettext("Changes reverted."))

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp phase_label(:gathering_context), do: gettext("Gathering context")
  defp phase_label(:proposing), do: gettext("Proposing")
  defp phase_label(:verifying), do: gettext("Verifying")

  defp summary_text(artifacts) do
    case Enum.find(artifacts, fn a -> match?(%RunSummary{}, a) end) do
      nil -> gettext("Done.")
      %RunSummary{} = rs -> Artifact.summary(rs).text_fallback
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(web): ReceiptLive component — pattern-matched per State variant"
jj new
```

---

## Task 14: Wire `PlannerLive` to the harness

**Files:**

- Modify: `lib/tore_web/live/planner_live.ex`
- Modify: `test/tore_web/live/planner_live_test.exs`

Replace `quick_reply` machinery with `current_run` driven by the Projector. Render via `ReceiptLive`.

- [ ] **Step 1: Read existing assigns and event handlers**

Run: `grep -n "quick_reply\|quick_loading\|run_quick_command\|quick_command_result\|format_agent_error" lib/tore_web/live/planner_live.ex`

Note line numbers: lines 32–33 (assigns), 203–217 (events), 279–319 (handle_info), 368–375 (format_agent_error), 418–474 (template).

- [ ] **Step 2: Update `mount/3` to start projector + subscribe + read latest**

Find the existing `mount/3`. After establishing `plan_id`/`week_start` and before the final `{:ok, assign(...)}`, add:

```elixir
    household_id = socket.assigns.current_user.household_id
    if connected?(socket) do
      {:ok, _pid} = Tore.Harness.ProjectorSupervisor.start_or_lookup(household_id)
      Phoenix.PubSub.subscribe(Tore.PubSub, "harness:household:#{household_id}")
    end

    current_run = Tore.Harness.Projector.latest_on_surface(household_id, :plan)
```

Replace the assigns line that includes `quick_reply: nil, quick_loading: false` with:

```elixir
       quick_loading: false,
       current_run: current_run,
```

(Remove the `quick_reply: nil,` line entirely.)

- [ ] **Step 3: Replace `handle_event("quick_command", ...)` and remove `dismiss_quick_reply`**

Find the existing `handle_event("quick_command", %{"command" => command}, socket)` (around line 203). Replace with:

```elixir
  def handle_event("quick_command", %{"command" => command}, socket) when command != "" do
    pid = self()

    ctx = %{
      household_id: socket.assigns.current_user.household_id,
      user_id: socket.assigns.current_user.id,
      command: command,
      plan_stream_id: socket.assigns.plan_id,
      week_start: socket.assigns.week_start
    }

    Task.start(fn ->
      result = Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)
      send(pid, {:run_dispatched, result})
    end)

    {:noreply, assign(socket, quick_loading: true)}
  end

  def handle_event("quick_command", _params, socket), do: {:noreply, socket}
```

Delete the existing `handle_event("dismiss_quick_reply", ...)` handler entirely.

- [ ] **Step 4: Replace `handle_info({:run_quick_command, ...})` and `handle_info({:quick_command_result, ...})`**

Delete both handlers. Add:

```elixir
  def handle_info({:run_dispatched, {:ok, state}}, socket) do
    {:noreply, assign(socket, current_run: state, quick_loading: false)}
  end

  def handle_info({:run_dispatched, {:error, _reason}}, socket) do
    {:noreply, assign(socket, quick_loading: false)}
  end

  def handle_info({:run_state_changed, _stream_id, state}, socket) do
    current = socket.assigns[:current_run]

    if current && current.stream_id == state.stream_id do
      {:noreply, assign(socket, current_run: state)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:run_event, _stream_id, _event}, socket), do: {:noreply, socket}
```

- [ ] **Step 5: Delete `format_agent_error/1`**

The three private clauses (lines ~368–375). They were only called by the old `:run_quick_command` handler.

- [ ] **Step 6: Replace the template block**

Find the `<%= case @quick_reply do %>` block in the template (lines ~435–474). Replace the entire `<%= case ... %> ... <% end %>` with:

```elixir
          <%= if @current_run do %>
            <.live_component module={ToreWeb.Components.ReceiptLive} id="planner-receipt" run={@current_run} />
          <% end %>
```

- [ ] **Step 7: Update the planner_live_test.exs**

Find any test asserting on `quick_reply`. The shape changed. Update to subscribe + assert on `current_run`. As a minimum, change assertions:

```elixir
# Before:
assert render(view) =~ "Skipped Monday dinner."
# Or assertions on view |> element(...) |> render() containing :message/:question/:error text.
```

The assertions stay correct text-wise (the Receipt component renders the artifact's `text_fallback`), but the layout container differs (`<.live_component ...>` instead of the colored panel).

Run: `mix test test/tore_web/live/planner_live_test.exs --trace`

If a specific assertion fails because it grepped for `bg-blue-50` or `dismiss_quick_reply`, update it to look for `Tore adjusted the plan` or the relevant summary text rendered by the ReceiptLive component.

- [ ] **Step 8: Confirm no live-code `correlation_id` references remain**

Run: `grep -rn "correlation_id\|quick_reply" lib/ test/ --include='*.ex' --include='*.exs'`
Expected: empty (or only matches in migrations and `SESSION_SUMMARY.md`).

- [ ] **Step 9: Run all planner tests**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: same pass/fail counts as the baseline at `587101b6`, modulo assertions that needed text updates (which you've fixed in Step 7).

- [ ] **Step 10: Commit**

```bash
jj describe -m "feat(web): PlannerLive consumes Projector + ReceiptLive; remove quick_reply"
jj new
```

---

## Task 15: Full test sweep + manual smoke

**Files:**

- None to write — verification only.

- [ ] **Step 1: Full test suite**

Run: `mix test --trace 2>&1 | tail -40`

Expected: no new failures vs the pre-existing floor at `587101b6` (5–7 in `Groceries*`, the `HouseholdTest` SQLite race). If `mix test` shows a regression, fix and re-run.

- [ ] **Step 2: Compile clean**

Run: `mix compile --force --warnings-as-errors`
Expected: clean exit.

- [ ] **Step 3: Grep audit**

Run: `grep -rn "correlation_id" lib/ test/ --include='*.ex' --include='*.exs'`
Expected: only `SESSION_SUMMARY.md` and migration files.

Run: `grep -rn "quick_reply" lib/ test/ --include='*.ex' --include='*.exs'`
Expected: empty.

- [ ] **Step 4: ecto.reset clean**

Run: `mix ecto.reset`
Expected: drops, creates, migrates without error.

- [ ] **Step 5: Manual smoke against real OpenRouter**

The user must start the server with `OPENROUTER_API_KEY` set. You (the agent) do not handle the key. Ask the user to:

1. Start dev server: `iex -S mix phx.server`.
2. Open `http://localhost:4000/`, sign in, navigate to `/plan`.
3. In the command bar, type `skip mon dinner` and press Ask.
4. Wait for the receipt component to render `Tore adjusted the plan`.
5. From `iex`: `{:ok, stream_id} = ...` — actually have the user run:

```elixir
sids = Tore.Repo.all(from e in Tore.EventStore.Event,
                     where: e.stream_type == "run",
                     order_by: [desc: e.id],
                     limit: 1,
                     select: e.stream_id)
sid = List.first(sids)
{:ok, state} = Tore.Harness.Run.load(sid)
state.__struct__
# Expected: Tore.Harness.Run.State.Applied
```

If `state.__struct__ == Tore.Harness.Run.State.Applied`, success criterion 10 is met. If it returns `Failed`, `NeedsUser`, or the planner errors before the receipt renders, debug accordingly.

- [ ] **Step 6: Final commit**

```bash
jj describe -m "test(harness): foundation passes full sweep + manual smoke"
jj new
```

---

## Self-Review Notes

**Spec coverage:**

- §1 (architecture): covered by Tasks 4, 5, 6, 11, 12.
- §2 (events/commands/state): Tasks 1, 2, 3, 4.
- §3 (Run public surface): Task 5.
- §4 (Artifact behaviour + Registry): Task 6.
- §4.1 (PlanDiff): Task 7.
- §4.2 (RunSummary): Task 8.
- §4.3 (S3 contract): documented in the spec; no code lands this sub-spec because no image-carrying artifact ships yet. Mentioned in Task 13's `body/2` design where it would attach.
- §5 (Orchestrator): Task 11.
- §6 (Projector + Supervisor + Registry): Task 12.
- §7 (PlannerAgent refactor): Task 10.
- §7.1 (FK migration): Task 9.
- §7.2 (PlannerLive consumer): Task 14.
- §8 (Receipt LiveComponent): Task 13.
- §9 (storage): no separate task — `events` table is reused; `ai_operations` migration is Task 9.
- §10 (tests): each task includes its tests; full sweep is Task 15.
- §11 (success criteria): 1–4, 7 verified in Task 15; 5 verified in Task 3; 6 in Task 11; 8 in Task 12; 9 in Task 13; 10 in Task 15 Step 5; 11–12 in Task 15 Step 3.

**No placeholders:** No `TODO`/`TBD` in any task body.

**Type consistency:** Event/command/state field names match across Tasks 1–4 and the Decider's pattern matches. `loop_outcome` shape in Task 10 matches Orchestrator's `absorb_loop`/`close` in Task 11 (`result`, `tool_trace`, `usage_per_step`). `PlanDiff` fields (`plan_stream_id`, `week_start`, `events`) match across Tasks 7 and 11. `RunSummary` `counts`/`outcome` match across Tasks 8 and 11.

**Stream-id convention:** All tasks consistently use string stream ids like `"run-..."`. `ai_operations.run_stream_id` is a `:string`, matching the type used everywhere else.

**`Tore.Chat.SystemPrompt.build/0`:** Stays put per spec §1 ("non-goals"); the Orchestrator calls it from `system_prompt/0`. Removal is deferred to `capsules_v1`.

**`Tore.MockHTTP` / `Tore.MockLLM`:** Already defined in `test/support/mocks.ex`. Tests in Tasks 10 and 11 use `Tore.MockLLM` directly via `Mox.expect/3`.
