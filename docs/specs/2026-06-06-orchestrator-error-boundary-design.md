# Orchestrator error boundary — design

**Date:** 2026-06-06
**Status:** approved (pending spec review)
**Sub-spec of:** harness (see `2026-06-02-harness-foundation-design.md`)

## Problem

`Tore.Harness.Orchestrator.dispatch/2` runs a planner command through a `with`
chain. The top-level chain propagates `{:error, _}` correctly, but three
helpers — `absorb_trace/3`, `absorb_usage/3`, and the two `close/4` clauses —
bare-match `{:ok, acc} = apply_command(...)` inside a plain `Enum.reduce`. If any
`apply_command` returns `{:error, reason}` (e.g. `Run.append` hits a DB failure
mid-trace), that match **raises a `MatchError`**:

- `dispatch/2` raises instead of returning `{:error, _}`.
- The run has a partial event log persisted (`Opened` + some `ToolStepRecorded`,
  no `Committed`). On replay, `Run.load` rebuilds it as `%State.Running{}` — a
  **dangling open run** the Projector treats as live forever and replays on every
  boot.

The PlannerLive `Task.start` `try/rescue` stops a UI crash but never records a
terminal state, so the dangling run persists. A raised exception inside dispatch
(e.g. the `cost_usd` Decimal bug we hit during smoke) has the same effect.

## Goal

Any failure during `dispatch/2` — a step *returning* `{:error, _}` or a step
*raising* — funnels into one path: record the run as `%State.Failed{}` (if it
reached `Running`), then return a typed `{:error, dispatch_error()}`. No
`MatchError`, no dangling open run. The failure surfaces in the receipt via the
existing `Failed` variant, localized.

## Non-goals

- No change to the Decider, the `RecordFailure`/`FailureRecorded`/`Failed`
  machinery (it already exists and works), persistence, or the Projector.
- Not removing `failure_user_message` from the `Failed` state/event (out of
  scope; the receipt simply stops reading it).
- No app-wide error-taxonomy work; the only failure code produced is
  `:internal_error`.

## Design — railway-oriented with a typed error channel

The happy path is already ROP (the `with` chain is the bind). The fix restores
the rails where the bare matches broke them, adds a typed error ADT, rescues
exceptions only at the boundary, and tees the failure track to record `Failed`.

### Error ADT

```elixir
@type dispatch_error :: {:step_failed, term()} | {:run_crashed, Exception.t()}
@spec dispatch(atom(), map()) :: {:ok, State.t()} | {:error, dispatch_error()}
```

- `:step_failed` — an interior step *returned* `{:error, reason}` (append/agent/
  decide error).
- `:run_crashed` — a step *raised*; the boundary rescued it.

This replaces the loose `{:error, reason}` grab-bag so callers can distinguish a
genuine crash (a bug) from an expected error.

### Restore the rails (interior helpers)

`absorb_trace/3`, `absorb_usage/3`, and both `close/4` clauses currently fold
with bare `{:ok, acc} = apply_command(...)`. Convert each to an error-respecting
fold that threads `{:ok, state} | {:error, reason}` and stops on the first error
— `Enum.reduce_while/3` for the loops, and a `with` chain for `close/4`'s
sequential `apply_command` calls. No `try/rescue` in these helpers (the skill:
"crash loudly at the boundary, not in the interior"). `apply_command/4` is
already ROP-shaped and unchanged.

Each helper's signature becomes `(state, ...) :: {:ok, State.t()} | {:error, term()}`.
`absorb_loop/3` chains `absorb_trace` then `absorb_usage` with `with`.

### Boundary (dispatch/2)

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

- The `try/rescue` is the **only** exception catch, at the boundary. A rescued
  exception becomes `{:error, {:run_crashed, e}}`.
- The `else` converts any returned step error to `{:error, {:step_failed, reason}}`.
- On any error, a single failure-track tee calls `record_failure/2`, then
  re-propagates the typed error. `dispatch` never returns `{:ok, failed_state}` —
  the failure receipt comes from the Projector reloading the now-`Failed` run
  after the `RecordFailure` append broadcasts (same mechanism Applied uses).

### record_failure/2

```elixir
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

- Records `Failed` **only if** the run reached `%State.Running{}` (the Decider
  rejects `RecordFailure` from other states). A pre-`Running` failure (e.g. the
  first `Open` append failed) means little/nothing persisted, so there's no
  dangling run to close — skip.
- Best-effort: the `_ = apply_command(...)` ignores a further error (if
  persistence is truly down, the `RecordFailure` append also fails; we still
  return the original typed error). `record_failure/2` never raises and never
  changes `dispatch`'s return value.
- No baked `user_message` — `code: :internal_error` carries the meaning; the
  receipt translates it.

## Receipt: translate failure_code (not the baked string)

`failure_code` is a machine-readable atom already on `%State.Failed{}` (and
rehydrated via `safe_atom/1` in `Run.load`). The receipt translates it in the
web layer instead of rendering a baked `failure_user_message`.

`lib/tore_web/components/receipt_live.ex` — change the `Failed` body clause:

```elixir
defp body(%State.Failed{failure_code: code}), do: escape(failure_message(code))

defp failure_message(:internal_error),
  do: gettext("Tore couldn't finish that — nothing was changed.")

defp failure_message(_),
  do: gettext("Tore couldn't finish that.")
```

- Closed map + catch-all fallback, so an unmapped or rehydration-mangled code
  can never `FunctionClauseError` the receipt (cold-boot-safe, per the harness's
  atom-round-trip lesson).
- The receipt stops reading `failure_user_message`. No current code path sets a
  non-nil `user_message` (only test fixtures did), so nothing regresses. A future
  domain failure wanting bespoke text adds a `failure_message/1` clause for its
  code.

## i18n

Two new gettext strings ("Tore couldn't finish that — nothing was changed.",
"Tore couldn't finish that."). Run `mix gettext.extract && mix gettext.merge
priv/gettext`, add Swedish to `priv/gettext/sv/LC_MESSAGES/default.po`, clear any
`fuzzy` flags on the new entries (gettext ignores fuzzy at runtime). Swedish:
"Tore kunde inte slutföra det — inget ändrades." / "Tore kunde inte slutföra det."

## PlannerLive

Unchanged. Its `Task.start` `try/rescue` stays as the outer net, but `dispatch`
is now the real boundary; the existing `{:run_dispatched, {:error, _}}` handler
already clears the spinner and flashes. `dispatch` returning the typed
`{:error, dispatch_error()}` matches that handler's `{:error, _reason}` pattern.

## Testing

Test seams (concrete — no Repo mocking needed). `Tore.MockLLM` is the injection
point for both failure classes, since `PlannerAgent.run/4` is a top-level `with`
step that runs after the run has reached `%State.Running{}` (so the
record-Failed tee fires):

- **`PlannerAgent.run` returns `{:error, _}`** → the `with` `else` converts it to
  `{:step_failed, reason}`. Drive via `Mox.stub(Tore.MockLLM, :chat_with_tools,
  fn _,_,_,_ -> {:error, :boom} end)` (PlannerAgent.run propagates the LLM
  `{:error, _}`).
- **A step raises** → the `try/rescue` yields `{:run_crashed, e}`. Drive via
  `Mox.stub(Tore.MockLLM, :chat_with_tools, fn _,_,_,_ -> raise "boom" end)`.

`test/tore/harness/orchestrator_test.exs` (extend):

- **step_failed, no raise + records Failed:** with the `{:error, :boom}` stub,
  `dispatch` returns `{:error, {:step_failed, :boom}}` (NOT a raise), and
  `Run.load(stream_id)` returns `%State.Failed{failure_code: :internal_error}`.
  (Capture the stream_id: the run reached Running, so the latest `stream_type:
  "run"` stream is it — query as the existing tests do, or assert via the
  Projector/`Run.load` of the most-recent run stream.)
- **run_crashed + records Failed:** with the `raise "boom"` stub, `dispatch`
  returns `{:error, {:run_crashed, %RuntimeError{}}}` and the run loads as
  `%State.Failed{}`.
- **Happy path unchanged:** existing dispatch tests still pass (the skip_meal
  PlanDiff test, etc.).

Note: the pre-`Running` failure case (first `Open` append fails) and the
interior `absorb_*` append-mid-trace failure are not cheaply injectable without
Repo mocking, and the agent-error test above already exercises the
error-threading + record-Failed tee end to end. So do NOT add a Repo mock or a
contrived test-only command; the two MockLLM-driven tests cover the boundary
behavior. `record_failure/2`'s non-Running skip is covered by reading the
guard — it is a pure `case` on `Run.load`, not worth a contrived test.

`test/tore_web/components/receipt_live_test.exs` (extend):

- A `%State.Failed{failure_code: :internal_error}` run renders the localized
  internal-error message (sv locale already pinned in this file's setup).
- A `%State.Failed{failure_code: :some_unknown}` renders the fallback message,
  not a crash.

## Success criteria

1. A mid-run step error makes `dispatch` return `{:error, {:step_failed, _}}` —
   never a `MatchError`/raise.
2. A raised exception makes `dispatch` return `{:error, {:run_crashed, _}}`.
3. A run that reached `Running` and then failed loads back as `%State.Failed{}`
   (no dangling open run for the Projector to replay).
4. A pre-`Running` failure returns `{:error, _}` and attempts no `RecordFailure`.
5. The receipt renders a localized failure message from `failure_code`.
6. Happy-path dispatch unchanged; full suite green vs the `Groceries*`/Household
   floor; `mix compile --warnings-as-errors` clean; 0 fuzzy in the sv catalog.
