# Orchestrator error boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Tore.Harness.Orchestrator.dispatch/2` funnel every failure (a step returning `{:error,_}` or raising) into recording the run as `%State.Failed{}` and returning a typed `{:error, dispatch_error()}` — no MatchError, no dangling open run — and translate the failure in the receipt from `failure_code`.

**Architecture:** Restore railway-oriented flow in the interior helpers (they currently bare-match `{:ok, acc} =` and raise on `{:error,_}`); add a typed two-variant error ADT; rescue exceptions only at the dispatch boundary; tee the failure track to append a `RecordFailure` (closing the run as `Failed`) when the run reached `Running`. The receipt's `Failed` body translates `failure_code` via a closed gettext map instead of rendering a baked string.

**Tech Stack:** Elixir, Phoenix LiveComponent, ExUnit, Mox (`Tore.MockLLM`), gettext. VCS is **jj (Jujutsu), never git**.

**Spec:** `docs/specs/2026-06-06-orchestrator-error-boundary-design.md`

**Baseline:** Pre-existing test floor is ~5–8 flaky failures in `Tore.Groceries.*` / `Tore.HouseholdTest` (Mox/SQLite race) that pass in isolation. "No new failures" = that floor unchanged.

**VCS discipline:** Start each task with `jj st`; if the working copy is not clean/empty, `jj new` before editing. End each task with `jj describe -m "<msg>"` then `jj new`.

---

## Reference: current code & facts

`lib/tore/harness/orchestrator.ex` — current relevant pieces:

```elixir
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}
  alias Tore.Harness.Artifact.RunSummary
  alias Tore.Harness.PlanDiffBuilder
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

  defp absorb_loop(state, loop, metadata) do
    state = absorb_trace(state, loop, metadata)
    absorb_usage(state, loop, metadata)
  end

  defp absorb_trace(state, loop, metadata) do
    Enum.reduce(loop.tool_trace, state, fn entry, acc ->
      ai_op_id = log_ai_operation(acc.stream_id, entry)
      cmd = %Commands.RecordToolStep{
        step_index: entry.step_index, step_kind: entry.step_kind,
        payload: entry.payload, ai_operation_id: ai_op_id
      }
      {:ok, acc} = apply_command(acc.stream_id, cmd, acc, metadata)
      acc
    end)
  end

  defp absorb_usage(state, loop, metadata) do
    final_state =
      Enum.reduce(loop.usage_per_step, state, fn usage, acc ->
        cmd = %Commands.ObserveModelUsage{
          prompt_tokens: usage.prompt_tokens, completion_tokens: usage.completion_tokens,
          cost_usd: usage.cost_usd
        }
        {:ok, acc} = apply_command(acc.stream_id, cmd, acc, metadata)
        acc
      end)
    {:ok, final_state}
  end

  defp close(state, %{result: {:message, _}} = loop, ctx, metadata) do
    plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)
    {:ok, state} = apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata)
    run_summary = RunSummary.from_artifacts([plan_diff], :applied)
    {:ok, state} = apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata)
    apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
  end

  defp close(state, %{result: {:question, q}}, _ctx, metadata),
    do: apply_command(state.stream_id, %Commands.RaiseQuestion{question: q}, state, metadata)

  defp close(state, %{result: {:capped, _}} = loop, ctx, metadata) do
    plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)
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
```

Facts:
- `Commands.RecordFailure{code, user_message, repair_action}` exists; the Decider handles it ONLY from `%State.Running{}` (`decide(%RecordFailure{}, %State.Running{})` → `FailureRecorded` → `to_failed` → `%State.Failed{}`). From any other state the Decider's catch-all returns `{:error, {:invalid_for_state, ...}}`.
- `Run.load(stream_id)` → `{:ok, State.t()}`; an unknown/empty stream → `{:ok, %State.Draft{}}`.
- `PlannerAgent.run/4` is spec'd `{:ok, loop_outcome()} | {:error, term()}` and PROPAGATES an LLM `{:error, reason}` (does not raise). So a `Tore.MockLLM.chat_with_tools` stub returning `{:error, :boom}` makes `PlannerAgent.run` return `{:error, :boom}`; a stub that `raise`s makes the dispatch chain raise.
- `%State.Failed{}` has fields `failure_code`, `failure_user_message`, `failure_repair_action` (+ the common run fields). `failure_code` rehydrates via `safe_atom/1` in `Run.load`, so after a reload it is an atom.
- `lib/tore_web/components/receipt_live.ex` aliases are exactly `alias Tore.Harness.Run.State` and `alias Tore.Harness.Artifact.PlanDiff`. The `Failed` body clause is `defp body(%State.Failed{failure_user_message: msg}), do: escape(msg)`. The test file `test/tore_web/components/receipt_live_test.exs` pins `Gettext.put_locale(ToreWeb.Gettext, "sv")` in `setup`.

---

## Task 1: Railway-orient the Orchestrator + record Failed on any error

**Files:**
- Modify: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/orchestrator_test.exs`

- [ ] **Step 1: Add failing tests for the two failure classes**

Read `test/tore/harness/orchestrator_test.exs` first to match its setup (it uses `Tore.MockLLM` via Mox, `use Tore.DataCase`, and dispatches with a ctx map). Add these tests. They need the run's stream_id after dispatch — query the most-recent `"run"` stream via `Tore.Repo` + `Tore.EventStore.Event` (import Ecto.Query), mirroring how other harness tests fetch a run.

```elixir
  test "dispatch returns {:step_failed, reason} and records the run as Failed when a step errors" do
    Mox.stub(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:error, :boom}
    end)

    ctx = %{household_id: 1, user_id: 1, command: "skip monday",
            plan_stream_id: "plan:2026-06-01", week_start: ~D[2026-06-01]}

    assert {:error, {:step_failed, :boom}} = Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)

    sid = latest_run_stream_id()
    assert {:ok, %Tore.Harness.Run.State.Failed{failure_code: :internal_error}} =
             Tore.Harness.Run.load(sid)
  end

  test "dispatch returns {:run_crashed, exception} and records Failed when a step raises" do
    Mox.stub(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      raise "boom"
    end)

    ctx = %{household_id: 1, user_id: 1, command: "skip monday",
            plan_stream_id: "plan:2026-06-01", week_start: ~D[2026-06-01]}

    assert {:error, {:run_crashed, %RuntimeError{message: "boom"}}} =
             Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)

    sid = latest_run_stream_id()
    assert {:ok, %Tore.Harness.Run.State.Failed{}} = Tore.Harness.Run.load(sid)
  end
```

Add this private helper to the test module (import Ecto.Query at the top of the test file if not already imported):

```elixir
  defp latest_run_stream_id do
    import Ecto.Query

    Tore.Repo.one(
      from e in Tore.EventStore.Event,
        where: e.stream_type == "run",
        order_by: [desc: e.id],
        limit: 1,
        select: e.stream_id
    )
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: the two new tests FAIL — currently a raise propagates out of dispatch (no `{:run_crashed,_}` wrapping), and an LLM `{:error, :boom}` returns bare `{:error, :boom}` (not `{:step_failed, :boom}`), and no run is recorded Failed.

- [ ] **Step 3: Add the typed error ADT + @spec**

In `lib/tore/harness/orchestrator.ex`, replace the existing `@spec dispatch/2` line with:

```elixir
  @type dispatch_error :: {:step_failed, term()} | {:run_crashed, Exception.t()}

  @spec dispatch(atom(), map()) :: {:ok, State.t()} | {:error, dispatch_error()}
```

- [ ] **Step 4: Rewrite dispatch/2 with the try/rescue boundary + failure tee**

Replace the `dispatch(:planner_command_run, ctx)` function body with:

```elixir
  def dispatch(:planner_command_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    result =
      try do
        with {:ok, state} <- open_run(stream_id, ctx, metadata),
             {:ok, state} <- enter(state, :gathering_context, metadata),
             {:ok, state} <- enter(state, :proposing, metadata),
             {:ok, loop} <- PlannerAgent.run(system_prompt(), ctx.command, agent_ctx(ctx, stream_id), []),
             {:ok, state} <- absorb_loop(state, loop, metadata),
             {:ok, state} <- enter(state, :verifying, metadata),
             {:ok, state} <- close(state, loop, ctx, metadata) do
          {:ok, state}
        else
          {:error, reason} -> {:error, {:step_failed, reason}}
        end
      rescue
        e -> {:error, {:run_crashed, e}}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, _} = err ->
        record_failure(stream_id, metadata)
        err
    end
  end
```

- [ ] **Step 5: Add record_failure/2**

Add this private function (place near `apply_command/4`):

```elixir
  # On any dispatch failure, close the run as Failed so it isn't a dangling open
  # run the Projector replays forever. Only valid from Running (the Decider
  # rejects RecordFailure otherwise); a pre-Running failure persisted nothing to
  # close. Best-effort: a further append error is swallowed.
  defp record_failure(stream_id, metadata) do
    case Run.load(stream_id) do
      {:ok, %State.Running{} = state} ->
        cmd = %Commands.RecordFailure{
          code: :internal_error,
          user_message: nil,
          repair_action: nil
        }

        _ = apply_command(stream_id, cmd, state, metadata)
        :ok

      _ ->
        :ok
    end
  end
```

- [ ] **Step 6: Restore the rails in absorb_trace/3 (reduce_while)**

Replace `absorb_trace/3` with an error-threading fold:

```elixir
  defp absorb_trace(state, loop, metadata) do
    Enum.reduce_while(loop.tool_trace, {:ok, state}, fn entry, {:ok, acc} ->
      ai_op_id = log_ai_operation(acc.stream_id, entry)

      cmd = %Commands.RecordToolStep{
        step_index: entry.step_index,
        step_kind: entry.step_kind,
        payload: entry.payload,
        ai_operation_id: ai_op_id
      }

      case apply_command(acc.stream_id, cmd, acc, metadata) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
```

Note: `absorb_trace/3` now returns `{:ok, state} | {:error, reason}`.

- [ ] **Step 7: Restore the rails in absorb_loop/3 + absorb_usage/3**

Replace `absorb_loop/3` and `absorb_usage/3` with:

```elixir
  defp absorb_loop(state, loop, metadata) do
    with {:ok, state} <- absorb_trace(state, loop, metadata) do
      absorb_usage(state, loop, metadata)
    end
  end

  defp absorb_usage(state, loop, metadata) do
    Enum.reduce_while(loop.usage_per_step, {:ok, state}, fn usage, {:ok, acc} ->
      cmd = %Commands.ObserveModelUsage{
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        cost_usd: usage.cost_usd
      }

      case apply_command(acc.stream_id, cmd, acc, metadata) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
```

- [ ] **Step 8: Restore the rails in both close/4 artifact clauses (with chains)**

Replace the `{:message, _}` and `{:capped, _}` `close/4` clauses (leave the `{:question, q}` clause exactly as-is — it's already a single `apply_command` returning `{:ok,_}|{:error,_}`):

```elixir
  defp close(state, %{result: {:message, _}} = loop, ctx, metadata) do
    plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)
    run_summary = RunSummary.from_artifacts([plan_diff], :applied)

    with {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata),
         {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata) do
      apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
    end
  end

  defp close(state, %{result: {:question, q}}, _ctx, metadata),
    do: apply_command(state.stream_id, %Commands.RaiseQuestion{question: q}, state, metadata)

  defp close(state, %{result: {:capped, _}} = loop, ctx, metadata) do
    plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)
    run_summary = RunSummary.from_artifacts([plan_diff], :applied)

    with {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: plan_diff}, state, metadata),
         {:ok, state} <- apply_command(state.stream_id, %Commands.AddArtifact{artifact: run_summary}, state, metadata) do
      apply_command(state.stream_id, %Commands.Commit{}, state, metadata)
    end
  end
```

- [ ] **Step 9: Run to verify pass**

Run: `mix test test/tore/harness/orchestrator_test.exs`
Expected: PASS — the two new failure tests AND all pre-existing dispatch tests (the happy-path skip_meal PlanDiff test etc.). The happy path is unchanged because the `with` chains return `{:ok, state}` exactly as the bare matches did.

- [ ] **Step 10: Compile clean**

Run: `mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 11: Commit**

```bash
jj describe -m "fix(harness): Orchestrator error boundary — thread errors, rescue at edge, record Failed"
jj new
```

---

## Task 2: Receipt translates failure_code

**Files:**
- Modify: `lib/tore_web/components/receipt_live.ex`
- Test: `test/tore_web/components/receipt_live_test.exs`

- [ ] **Step 1: Add failing tests**

Add to `test/tore_web/components/receipt_live_test.exs` (the file pins `sv` locale in `setup`, so assert Swedish). Build the `%State.Failed{}` like the existing Failed test in the file, but set `failure_code` and a nil `failure_user_message`:

```elixir
  test "Failed renders the localized message for :internal_error from failure_code" do
    failed = %State.Failed{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z], failed_at: ~U[2026-06-02 12:00:01Z],
      failure_code: :internal_error, failure_user_message: nil, failure_repair_action: nil,
      tool_trace: [], artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
    html = render_component(ReceiptLive, id: "r", run: failed)
    assert html =~ "Tore kunde inte slutföra det — inget ändrades"
  end

  test "Failed renders a fallback message for an unknown failure_code" do
    failed = %State.Failed{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z], failed_at: ~U[2026-06-02 12:00:01Z],
      failure_code: :some_unknown, failure_user_message: nil, failure_repair_action: nil,
      tool_trace: [], artifacts: [],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
    html = render_component(ReceiptLive, id: "r", run: failed)
    assert html =~ "Tore kunde inte slutföra det"
    refute html =~ "inget ändrades"
  end
```

Confirm the existing Failed test in the file (the one asserting `"kunde inte"` / `"That slot is pinned."`): it sets `failure_user_message: "That slot is pinned."`. After this change the body comes from `failure_code`, NOT `failure_user_message`. That existing test's `failure_code` — check what it is. If it's `:slot_locked` (a code with no `failure_message/1` clause), the body becomes the fallback "Tore kunde inte slutföra det", so `assert html =~ "That slot is pinned."` will FAIL. Update that existing test in Step 5.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: the two new tests FAIL (body still reads `failure_user_message`, which is nil → empty), and the pre-existing Failed test likely fails too (body no longer shows its `failure_user_message`).

- [ ] **Step 3: Change the Failed body clause to translate failure_code**

In `lib/tore_web/components/receipt_live.ex`, replace:

```elixir
  defp body(%State.Failed{failure_user_message: msg}), do: escape(msg)
```

with:

```elixir
  defp body(%State.Failed{failure_code: code}), do: escape(failure_message(code))
```

- [ ] **Step 4: Add failure_message/1 (placed near phase_label/1)**

```elixir
  defp failure_message(:internal_error),
    do: gettext("Tore couldn't finish that — nothing was changed.")

  defp failure_message(_),
    do: gettext("Tore couldn't finish that.")
```

- [ ] **Step 5: Update the pre-existing Failed test**

The existing test `"renders failure for Failed with header text and user message"` (around line 69) builds a `%State.Failed{failure_code: :slot_locked, failure_user_message: "That slot is pinned."}` and asserts:

```elixir
    assert html =~ "kunde inte"
    assert html =~ "That slot is pinned."
```

After this change the body derives from `failure_code`, and `:slot_locked` has no `failure_message/1` clause → it hits the fallback ("Tore kunde inte slutföra det"), so `"That slot is pinned."` is no longer rendered. The `"kunde inte"` assertion still passes (it now matches the fallback body, and/or the header). Replace the two assertions with:

```elixir
    assert html =~ "kunde inte"
    refute html =~ "That slot is pinned."
```

The `refute` documents the intentional behavior change: the receipt no longer renders the raw `failure_user_message`. Do NOT delete the test. (Optionally rename it from "...and user message" since it no longer asserts a user_message — but keep the rename minimal if you do.)

- [ ] **Step 6: Run to verify pass**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: PASS — note the new internal_error test asserts the Swedish string, which only resolves AFTER Task 3 adds the translation. So at THIS point, the `:internal_error` test will fail on the Swedish assertion (it'll render the English source string since no sv translation exists yet). To keep this task self-contained and green, temporarily assert the English source in Step 1's first test (`assert html =~ "Tore couldn't finish that — nothing was changed."`) and Task 3 will flip it to Swedish after adding the translation. ADJUST Step 1's first assertion to the English source string now; Task 3 Step 5 updates it to Swedish.

- [ ] **Step 7: Compile clean**

Run: `mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(web): receipt translates failure_code instead of baked message"
jj new
```

---

## Task 3: i18n the failure strings + full verification

**Files:**
- Modify: `priv/gettext/sv/LC_MESSAGES/default.po` (+ `default.pot`, `en/...default.po` from extract)
- Modify: `test/tore_web/components/receipt_live_test.exs` (flip the assertion to Swedish)

- [ ] **Step 1: Extract + merge**

Run: `mix gettext.extract && mix gettext.merge priv/gettext`
Expected: reports new messages added (the two `failure_message/1` strings).

- [ ] **Step 2: Add Swedish translations**

In `priv/gettext/sv/LC_MESSAGES/default.po`, find the two new msgids and fill their msgstr (and strip any `, fuzzy` flag the merge added on these entries — gettext ignores fuzzy at runtime):

```
msgid "Tore couldn't finish that — nothing was changed."
msgstr "Tore kunde inte slutföra det — inget ändrades."

msgid "Tore couldn't finish that."
msgstr "Tore kunde inte slutföra det."
```

Verify: `grep -c fuzzy priv/gettext/sv/LC_MESSAGES/default.po` should not have increased on account of these two (clear them if so). Confirm both msgstrs are non-empty.

- [ ] **Step 3: Flip the Task 2 test assertion to Swedish**

In `test/tore_web/components/receipt_live_test.exs`, the `:internal_error` test (temporarily asserting the English source from Task 2) now asserts Swedish:

```elixir
    assert html =~ "Tore kunde inte slutföra det — inget ändrades"
```

(The fallback test already asserts `"Tore kunde inte slutföra det"` + `refute "inget ändrades"`, which now matches the Swedish fallback. Confirm it still holds: the fallback msgstr is "Tore kunde inte slutföra det." — contains "Tore kunde inte slutföra det", does not contain "inget ändrades". Good.)

- [ ] **Step 4: Run the receipt tests**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: PASS (all, with Swedish assertions).

- [ ] **Step 5: Full verification sweep**

Run: `mix test test/tore/harness/ test/tore_web/ 2>&1 | tail -6`
Expected: 0 failures.

Run: `mix test 2>&1 | tail -4`
Expected: failures only in `Tore.Groceries.*` / `Tore.HouseholdTest` (the known floor). No new failures elsewhere.

Run: `mix compile --force --warnings-as-errors 2>&1 | tail -3`
Expected: clean.

Run: `grep -c fuzzy priv/gettext/sv/LC_MESSAGES/default.po`
Expected: 0.

- [ ] **Step 6: Manual smoke (user-run; agent must NOT handle OPENROUTER_API_KEY)**

Ask the user to cold-restart the server (`OPENROUTER_API_KEY=… iex -S mix phx.server` — full restart, no `recompile()`), then in `iex` force a failure to confirm the run closes as Failed and the receipt shows the Swedish message. Simplest: temporarily nothing needed in prod — instead, verify the happy path still works (a normal planner command applies) AND, for the failure path, the user can trust the tests. Optionally the user can simulate a failure by pointing OPENROUTER at a bad key for one command and confirming the receipt reads "Tore kunde inte slutföra det…" and `Tore.Harness.Run.load(<latest run sid>).__struct__ == Tore.Harness.Run.State.Failed`.

- [ ] **Step 7: Final commit**

```bash
jj describe -m "i18n: Swedish for orchestrator failure messages"
jj new
```

---

## Self-Review Notes

**Spec coverage:**
- Typed error ADT (`:step_failed`/`:run_crashed`) → Task 1 Step 3.
- Restore rails in absorb_trace/absorb_usage/close → Task 1 Steps 6–8.
- try/rescue boundary + failure tee → Task 1 Step 4.
- record_failure/2 (Running-only, best-effort) → Task 1 Step 5.
- Receipt translates failure_code via closed map + fallback → Task 2 Steps 3–4.
- Orchestrator records `code: :internal_error`, no baked message → Task 1 Step 5.
- i18n + clear fuzzy → Task 3.
- Tests (step_failed + run_crashed via MockLLM; receipt internal_error + fallback) → Task 1 Step 1, Task 2 Step 1.
- Success criteria → Task 1 (1–4), Task 2 (5), Task 3 (6).

**Type consistency:** `dispatch_error :: {:step_failed, term()} | {:run_crashed, Exception.t()}` used in the @spec and asserted in tests. `absorb_trace/absorb_usage` now return `{:ok, state} | {:error, reason}`; `absorb_loop` chains them with `with`; `dispatch`'s `with` consumes `{:ok, state} <- absorb_loop(...)`. `close/4` clauses return `{:ok,_}|{:error,_}`. `record_failure/2` uses `Commands.RecordFailure{code:, user_message:, repair_action:}` matching the struct, and matches `%State.Running{}` (the only state the Decider accepts RecordFailure from). `failure_message/1` matches `failure_code` atoms (rehydrated via safe_atom).

**Cross-task ordering:** Task 2's `:internal_error` test temporarily asserts the English source string (Step 6 note), Task 3 flips it to Swedish after adding the translation — so each task is independently green. Task 1 is self-contained (no i18n dependency; its failure code is `:internal_error` and tests assert on the state struct + error tuple, not on receipt text).
