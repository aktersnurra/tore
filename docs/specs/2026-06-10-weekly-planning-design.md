# Weekly Auto-Planning (`:weekly_planning_run` — PlanMyWeek) Design

**Date:** 2026-06-10
**Spec section:** SPEC.md §The Six LLM-Native Features (`:weekly_planning_run`),
§A.6 Kitchen Skills (`PlanMyWeek`), §Quantum Schedule.
**Scope:** The slot-fill core of `:weekly_planning_run` (the `PlanMyWeek` skill),
triggered by the Saturday cron only. Replaces the old `generate_plan/1` path.

## Goal

A new harness run kind that fills the empty, unpinned dinner slots of a target
week with suitable recipes, by driving the existing pure planner tool loop with
higher caps, gated by `PlanVerifier`, producing a `PlanDiff`. It is the second
real consumer of the harness (after `:planner_command_run`) and the first
consumer of the context-capsule subsystem in a non-interactive run.

It **replaces** the current non-harness `PlanningHandler.generate_plan/1` +
`Planning.Commands.GeneratePlan` + `Planning.Events.PlanGenerated`, whose
`evolve` clause replaces the entire `slots` map and ignores `pins` — i.e. it
clobbers pinned slots. The new run respects pins (the verifier enforces it) and
applies atomically.

## Scope

**In scope** — the `PlanMyWeek` slot-fill run, exactly:

- A `:weekly_planning_run` dispatch clause in the Orchestrator.
- Filling **empty, unpinned** dinner slots only; assigned and pinned slots are
  left untouched. Idempotent: running twice does not churn existing choices.
- Reusing the existing pure planner tools, the 4 existing context capsules, and
  `PlanVerifier`, via a shared private loop helper.
- A single trigger: the **Saturday Quantum cron**, headless, planning the
  **upcoming** week. The result surfaces via the Projector when the user next
  opens `/plan`.
- Removing the old `generate_plan/1` / `GeneratePlan` / `PlanGenerated` path.

**Out of scope** (deferred, each its own later spec):

- `GroceryDiff` (the week's shopping list with source-recipe attribution) — a
  follow-on spec; this run produces only `PlanDiff` + `RunSummary`.
- The weighted variants `UseTheDeals` (deal-weighted) and `LowEnergyWeek`
  (low-effort weighted).
- **Deal-awareness entirely.** This run uses **no** `DealsDigestCapsule`. Deal
  context belongs to `UseTheDeals`, which is also where the real-world
  deal-timing problem lives: ICA refreshes deals on Mondays, so a Saturday plan
  for a Monday-start week would otherwise plan against soon-to-expire deals.
  Keeping deals out sidesteps this until deal-weighted planning is designed.
- The two deferred capsules `RecentHistoryCapsule` / `RecipeAffinityCapsule`.
  This run reuses only the 4 existing capsules; variety/affinity emerge from
  insights + the model's judgement until a later quality pass builds them.
- A "Plan my week" button / any `/plan` UI. Weekly planning is purely ambient;
  the user edits individual slots afterward via the **existing** slot modal
  (assign/swap/skip/pin — all already shipped).
- The ambient `:unplanned_week` trigger (depends on the unbuilt
  `:ambient_scan_run`).

## Architecture

### The run

A new clause:

```elixir
def dispatch(:weekly_planning_run, ctx) do ... end
```

`ctx` for this run: `%{household_id, plan_stream_id, week_start, user_id}` where
`user_id` is `nil` (no interactive user). The clause mirrors the
`:planner_command_run` lifecycle (open → gathering_context → proposing →
verifying → close) but differs in three ways:

1. **No user command.** Instead of `ctx.command`, the run uses a fixed internal
   instruction as the "user text" fed to the agent loop:

   > "Fill every empty, unplanned dinner this week with a suitable recipe.
   > Leave days that already have a meal, and days the household has pinned,
   > exactly as they are. Use leftovers across days where it makes sense.
   > When you are done, stop."

   This is a private builder (e.g. `weekly_fill_instruction/0`) in the
   Orchestrator. The system prompt is composed exactly as the planner's is
   (`agent_preamble` + date/week-mode framing + `Capsules.compose(@planner_capsules, ...)`).

2. **Higher loop caps.** `PlannerAgent.run/4` is called with
   `max_round_trips: 10, max_action_calls: 25` (a week is 7 slots plus leftover
   propagation; the planner's default 6/12 is tuned for a single utterance).
   These are passed via the existing `opts` keyword the agent already supports.

3. **Headless trigger** (see below). No LiveView session.

The fill policy ("empty + unpinned only") needs no new enforcement: pinned slots
are rejected by `PlanVerifier`'s existing pin check, and the instruction directs
the model to skip already-assigned slots. The model proposes against the
in-memory working plan via the pure tools; the Orchestrator applies the
accumulated events once, post-loop, only if the verifier passes — the same
verify-then-mutate atomicity already in place.

### Shared loop helper

`:planner_command_run` and `:weekly_planning_run` now share their entire core:
the same pure tools, the same `PlannerAgent.run/4`, the same capsule list, the
same `PlanVerifier`, the same verify-then-mutate close. The only per-run
differences are the **system-prompt's instruction text**, the **caps**, and the
**trigger**.

Factor the shared sequence into a private helper:

```elixir
defp run_planner_loop(state, ctx, user_text, opts)
```

It performs: `PlanningHandler.load_plan(ctx.plan_stream_id)` →
`PlannerAgent.run(system_prompt(ctx), user_text, agent_ctx(ctx, ...), opts)` →
`absorb_loop` → `enter(:verifying)` → `close`. Each dispatch clause is then thin:
it opens the run, then calls `run_planner_loop` with its own `user_text`
(`ctx.command` for the planner; `weekly_fill_instruction()` for weekly) and
`opts` (`[]` for the planner; the higher caps for weekly).

This is a **private helper, not a DSL.** At two run kinds, extracting the shared
contract into a helper is the right granularity; the `KitchenRunDSL` idea stays
deferred until 3–4 run kinds make a declaration layer pay for itself.

`@planner_capsules` (the 4 existing capsules) is reused unchanged for both runs.

### Trigger: Saturday cron (only)

Re-point the existing Quantum entry — currently:

```elixir
{"0 18 * * 6", fn -> Tore.Handlers.PlanningHandler.generate_plan("plan:current", Date.utc_today()) end},
```

to dispatch the harness run for the **upcoming** week (next Monday–Sunday):

```elixir
{"0 18 * * 6", {Tore.Handlers.PlanningHandler, :plan_upcoming_week, []}},
```

`PlanningHandler.plan_upcoming_week/0` resolves the single household
(`Tore.Household.get_household!`), computes the upcoming week's `week_start` and
`plan_stream_id` (`"plan:<iso week_start>"`), builds `ctx` (with `user_id: nil`),
and calls `Orchestrator.dispatch(:weekly_planning_run, ctx)`. This also fixes the
old entry's bugs (it planned `"plan:current"` for *today's* week via the
pin-clobbering path).

Because the cron has no LiveView session, there is no live receipt. The harness
persists the run and its artifacts; the filled week surfaces through the
**Projector** when the user next opens `/plan`. The user then edits any
individual slot through the existing slot modal.

## Data flow

```
Sat 18:00 cron
  → PlanningHandler.plan_upcoming_week/0
      household = get_household!()
      week_start = upcoming Monday
      ctx = %{household_id, plan_stream_id: "plan:<week_start>", week_start, user_id: nil}
  → Orchestrator.dispatch(:weekly_planning_run, ctx)
      open run → gathering_context → proposing
      run_planner_loop(state, ctx, weekly_fill_instruction(), max_round_trips: 10, max_action_calls: 25)
        load working plan
        PlannerAgent.run(system_prompt(ctx), instruction, agent_ctx, caps)
          model calls pure tools: search_recipes / pantry_snapshot (read),
          assign_recipe / mark_leftover (action) against the working plan
        absorb tool trace + usage
      verifying → PlanVerifier.verify(plan_diff, verify_ctx)
        :ok   → apply accumulated events once; add PlanDiff + RunSummary; Commit
        :fail → RecordFailure(code, repair); apply nothing
  → persisted; Projector replays; /plan shows the filled week on next open
```

## Error handling

Reuses the harness error boundary already in `dispatch`:

- **LLM / tool failure mid-loop:** handled exactly as the planner — a tool error
  is fed back to the model; the model retries or alters; the loop may cap out.
- **Verifier failure:** the run is closed `Failed` with a structured code and a
  repair action; **nothing is applied** (verify-then-mutate atomicity). For a
  headless run this is silent — the week stays in its pre-run (empty) state.
- **Cron-context failure** (e.g. no household resolvable, dispatch raises): the
  `try/rescue` logs via `Logger.error` and `record_failure` closes any open run;
  the scheduler is not crashed. A failed background run is a no-op from the
  user's perspective.

No new error types. The headless nature means failure degrades to "week not
filled," which equals the starting state — acceptable for a background job.

## Removal of the old path

Delete (the new run fully replaces them, and the `PlanGenerated` evolve is a
latent pin-clobbering footgun):

- The Prep page's **"generate plan" button** and its `handle_event("generate_plan", …)`
  in `lib/tore_web/live/prep_live.ex` (lines ~23–35) plus its template button
  (~line 109). This is the in-app consumer of the old one-shot path. The Prep
  page keeps its separate **"generate guide"** button — `PrepHandler.generate_guide`
  is fully independent (it only *reads* the plan via `load_plan/1` and calls
  `@llm.generate_prep_guide`; it does not call `generate_plan`) and is untouched.
- `Tore.Handlers.PlanningHandler.generate_plan/3` and its private helpers used
  only by it (`build_plan_context/4`, `parse_llm_slots/1` — verify no other
  callers before removing).
- `Tore.Planning.Commands.GeneratePlan`.
- `Tore.Planning.Events.PlanGenerated` and its `Decider.decide`/`Decider.evolve`
  clauses.
- The `@llm.generate_plan/1` callback in `Tore.LLM`, its `Tore.Adapters.OpenRouter`
  implementation, and the Mock expectations — confirmed to have no remaining
  caller once the cron + Prep button are re-pointed/removed.
- The `:generate_plan` SpendGuard budget entry (`lib/tore/spend_guard.ex`) and the
  `feature_label("generate_plan")` clause in `settings_live.ex`, IFF nothing else
  references the `:generate_plan` feature key after removal (the prep guide uses
  its own feature key — verify).
- Their tests (`planning_handler_test.exs` generate_plan cases; the
  `open_router_test.exs` generate_plan case; SpendGuard test cases that use the
  `:generate_plan` key only if that key is fully removed — otherwise leave them).

## File structure

```
Modify: lib/tore/harness/orchestrator.ex       # add :weekly_planning_run clause;
                                                #   extract run_planner_loop/4 shared helper;
                                                #   refactor :planner_command_run to use it;
                                                #   add weekly_fill_instruction/0
        lib/tore/handlers/planning_handler.ex   # add plan_upcoming_week/0;
                                                #   remove generate_plan/3 + build_plan_context/4 + parse_llm_slots/1
        lib/tore/planning/commands.ex           # remove GeneratePlan
        lib/tore/planning/events.ex             # remove PlanGenerated
        lib/tore/planning/decider.ex            # remove GeneratePlan/PlanGenerated clauses
        lib/tore/llm.ex                          # remove @callback generate_plan/1
        lib/tore/adapters/open_router.ex         # remove generate_plan/1 implementation
        lib/tore/spend_guard.ex                  # remove :generate_plan @feature_defaults entry
        lib/tore_web/live/prep_live.ex           # remove "generate_plan" handle_event + template button
        lib/tore_web/live/settings_live.ex       # remove feature_label("generate_plan") clause
        config/config.exs                        # re-point the Sat 18:00 Quantum job (line ~63)
Delete tests: planning_handler_test.exs generate_plan cases;
              open_router_test.exs generate_plan case
Modify tests: spend_guard_test.exs (switch the :generate_plan test key to the
              default fallback or :generate_prep_guide — it tests the guard, not the feature)
New: test/tore/harness/weekly_planning_run_test.exs
```

**Confirmed against live code (2026-06-10):** the live Quantum schedule is in
`config/config.exs` (not `runtime.exs`); the Sat 18:00 entry currently calls
`generate_plan("plan:current", Date.utc_today())`. The `@llm.generate_plan/1`
callback's only callers are `PlanningHandler.generate_plan/3` (being removed) and
the Prep "generate plan" button (being removed) — so the callback + adapter impl
are safely removable. The prep guide (`PrepHandler.generate_guide` →
`@llm.generate_prep_guide`, SpendGuard key `:generate_prep_guide`) is independent
and untouched.

## Testing

- **Shared-helper regression:** the existing `:planner_command_run` tests
  (including `test/tore/harness/orchestrator_system_prompt_test.exs` and the
  planner LiveView command-bar tests) stay green after the `run_planner_loop`
  extraction — the planner run's behaviour is unchanged.
- **New weekly-run dispatch test** (`MockLLM`): seed a plan with one pinned slot
  and one already-assigned slot; the mock returns tool calls assigning recipes
  to a couple of the empty slots and then a final message. Assert:
  - dispatch returns `{:ok, %State.Applied{}}` (the terminal committed state);
  - the empty slots the mock targeted are now assigned in the persisted plan;
  - the **pinned** slot and the **pre-assigned** slot are unchanged;
  - a `PlanDiff` artifact and a `RunSummary` were produced.
- **Verifier-failure path:** a mock that proposes a change to the pinned slot →
  run closes `Failed`, nothing applied (mirrors the existing planner
  verifier-failure test).
- **Cron entry:** `plan_upcoming_week/0` resolves the household, targets the
  upcoming Monday's `plan_stream_id`, and dispatches `:weekly_planning_run`
  (assert the dispatch is invoked with the right `week_start`; the loop itself is
  covered by the dispatch test).
- **Full suite green.** No gettext: the internal instruction and capsule prompts
  are model-facing English; this run adds no user-facing UI copy.

## Success criteria

- The Saturday cron dispatches a harness `:weekly_planning_run` for the upcoming
  week; the old `generate_plan` path is gone.
- A run fills empty, unpinned dinner slots and leaves pinned/assigned slots
  untouched; the change is atomic (verifier-gated).
- The filled week appears on `/plan` via the Projector with no live session, and
  the user can edit individual slots with the existing modal.
- `:planner_command_run` behaviour is unchanged (shared-helper extraction is a
  pure refactor for it).
