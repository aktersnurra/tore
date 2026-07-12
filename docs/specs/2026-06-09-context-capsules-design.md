# Context Capsules (A.4) Design

**Date:** 2026-06-09
**Spec section:** SPEC.md §A.4 (Context capsules, not one big prompt)
**Scope:** The capsule contract + composition mechanism, the 4 capsules that
have a real consumer today, and migration of both `SystemPrompt.build/0` callers
onto capsules. Deletes `Tore.Chat.SystemPrompt.build/0`.

## Goal

Replace the single junk-drawer system prompt (`Tore.Chat.SystemPrompt.build/0`)
with a set of named, typed **context capsules** that a run declares explicitly.
Each capsule is a struct with a `to_prompt/1`; a run composes its declared list
into the prompt. This makes the model's inputs auditable ("what did the model
see?" = the run's capsule list), independently testable, and free of ambient
string-concatenation.

This is foundational harness infrastructure — the next feature
(`:weekly_planning_run`) and every future run consumes it. It is **not** part of
weekly planning; it is parked ahead of it deliberately (correct dependency
order).

## Scope

**Build now** (have a real consumer today — they are the 4 data sections
`SystemPrompt.build/0` actually assembles):

| Capsule | Provides | Source |
|---|---|---|
| `HouseholdPreferencesCapsule` | Diet/allergies/dislikes guidance string | `Tore.Household.get_preferences/0` + `prefs_to_dietary_guidance/1` |
| `ActiveInsightsCapsule` | Up to 5 active `HouseholdInsight` bodies | `Tore.Household.list_active_insights/0` |
| `WeekPlanCapsule` | The current week's per-slot dinner state (empty/assigned/skipped) | `Tore.Handlers.PlanningHandler.load_plan/1` |
| `PantryBeliefsCapsule` | Approximate inventory (names, capped at 20 + count) | `Tore.Pantry.list_inventory/0` |

**Deferred** (no consuming run yet; need invented aggregation/scoring or a
nonexistent preference — same YAGNI logic as the deferred repeat-window check):
`DealsDigestCapsule`, `RecipeAffinityCapsule`, `RecentHistoryCapsule`,
`CostIntentCapsule`. The contract is designed so each is a small drop-in when
its feature lands and can specify its exact fields. Weekly planning will be the
natural consumer that pins down the history/affinity shapes later.

## The capsule contract

```elixir
defmodule Tore.Harness.Capsule do
  @moduledoc "A named, typed unit of run context. Struct + to_prompt/1."

  @doc "Build the capsule struct from a context map (household_id, plan_stream_id, ...)."
  @callback build(ctx :: map()) :: struct()

  @doc "Render the capsule struct to compact prompt text, or nil if it contributes nothing."
  @callback to_prompt(struct()) :: String.t() | nil
end
```

- Each capsule is a module implementing `@behaviour Tore.Harness.Capsule`, with
  a `defstruct` of **typed fields** (per §A.4: "a struct, not a string" — so UI
  and verifiers can read the struct directly).
- `build/1` does the data fetch and summarisation (the compactness/token-budget
  rule lives **in the capsule**, e.g. PantryBeliefs caps at 20 + a count).
- `to_prompt/1` returns the compact text, or `nil` when the capsule has nothing
  to contribute (empty pantry, no insights) — mirroring how `build/0`'s sections
  return `nil` and get rejected today.

### Composition

```elixir
defmodule Tore.Harness.Capsules do
  @doc """
  Build each declared capsule from ctx, render it, drop nils, join with blank
  lines. `capsule_modules` is the run's explicit, static capsule list.
  """
  @spec compose([module()], map()) :: String.t()
  def compose(capsule_modules, ctx) do
    capsule_modules
    |> Enum.map(fn mod -> mod.to_prompt(mod.build(ctx)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
```

`compose/2` is the *only* way run context is assembled. There is no ambient
context: a capsule a run did not list is not in its prompt.

### The ctx map

`build/1` receives a plain map carrying what the capsules need to fetch their
data:

```elixir
%{
  household_id: integer(),
  plan_stream_id: String.t(),   # WeekPlanCapsule loads this
  week_start: Date.t()
}
```

Capsules read only the keys they need (`HouseholdPreferencesCapsule` ignores
`plan_stream_id`, etc.). The orchestrator already has all of these when it
dispatches a run.

## Migration: deleting `SystemPrompt.build/0`

`build/0` assembles **7 sections**. They split into three kinds:

1. **Four data capsules** (the table above): `dietary_section` →
   `HouseholdPreferencesCapsule`, `insights_section` → `ActiveInsightsCapsule`,
   `week_context_section`/`format_plan_state` → `WeekPlanCapsule`,
   `pantry_section` → `PantryBeliefsCapsule`. Each capsule's `to_prompt/1`
   reproduces that section's exact text shape.
2. **Run-role preamble** (`role_section`): not a capsule — it is the run's
   *identity*, not household data. Each run owns its role text. The planner run
   already has its own `agent_preamble` (today it is **doubly** prefixed — its
   own preamble *plus* `build/0`'s `role_section`; this migration removes that
   duplication). The chat handler keeps a short role preamble inline.
3. **Transient framing** (`date_section`, `week_mode_section`): `date` is a
   one-liner; `week_mode` is a per-run modifier, not standing context. These
   stay as small inline strings the run prepends — **not** capsules (a capsule is
   standing, declared context; the date and the active week-mode are neither).

So a run's system prompt becomes:

```
<run role preamble>  <>  <date line>  <>  [week-mode line if any]  <>  compose(capsules, ctx)
```

### Caller changes

**`Tore.Harness.Orchestrator`** (`system_prompt/0`): currently
`agent_preamble() <> "\n\n" <> SystemPrompt.build()`. Becomes: declare the
planner run's capsule list (`@planner_capsules [HouseholdPreferencesCapsule,
ActiveInsightsCapsule, WeekPlanCapsule, PantryBeliefsCapsule]`), and build:

```elixir
defp system_prompt(ctx) do
  [
    agent_preamble(),
    date_line(),
    week_mode_line(),
    Capsules.compose(@planner_capsules, capsule_ctx(ctx))
  ]
  |> Enum.reject(&is_nil/1)
  |> Enum.join("\n\n")
end
```

where `date_line/0` and `week_mode_line/0` are the small moved fragments and
`capsule_ctx/1` maps the dispatch ctx to the capsule ctx map. (`system_prompt`
gains the `ctx` argument it needs for `plan_stream_id`/`week_start`; it is called
in `dispatch/2` where `ctx` is in scope.)

**`Tore.Chat.ChatHandler`** (`system = SystemPrompt.build()`): becomes
`system = chat_role_preamble() <> "\n\n" <> Capsules.compose(@chat_capsules, chat_ctx())`
with the same four capsules (chat wants the same household context). The chat
handler computes its own `chat_ctx` (today's current-week plan id, household).

**`Tore.Chat.SystemPrompt`** module is **deleted** (per §A.4 hard rule: "its
callers move to declaring capsules"). The `role`/`date`/`week_mode` text moves to
the two callers / small private helpers; the 4 data sections move into capsules.

`Tore.WeekMode.mode_prompt_fragment/1` and `Household.prefs_to_dietary_guidance/1`
are reused as-is by the moved fragments / capsules.

## File structure

```
New: lib/tore/harness/capsule.ex                          # the @behaviour
     lib/tore/harness/capsules.ex                          # compose/2
     lib/tore/harness/capsules/household_preferences_capsule.ex
     lib/tore/harness/capsules/active_insights_capsule.ex
     lib/tore/harness/capsules/week_plan_capsule.ex
     lib/tore/harness/capsules/pantry_beliefs_capsule.ex
Modify: lib/tore/harness/orchestrator.ex                   # declare @planner_capsules; system_prompt/1 uses compose; date/week_mode helpers
        lib/tore/chat/chat_handler.ex                       # role preamble + compose; chat_ctx
Delete: lib/tore/chat/system_prompt.ex
New: test/tore/harness/capsules/household_preferences_capsule_test.exs
     test/tore/harness/capsules/active_insights_capsule_test.exs
     test/tore/harness/capsules/week_plan_capsule_test.exs
     test/tore/harness/capsules/pantry_beliefs_capsule_test.exs
     test/tore/harness/capsules_test.exs                    # compose/2
Delete: test/tore/chat/system_prompt_test.exs            # exists today; its assertions move to the capsule + compose tests
```

`test/tore/chat/system_prompt_test.exs` exists; it is deleted with the module,
and its behavioral assertions (dietary/insights/week/pantry text) are reproduced
in the corresponding per-capsule tests + the compose test.

## Capsule struct shapes (typed, per §A.4)

```elixir
# HouseholdPreferencesCapsule
defstruct [:guidance]          # guidance :: String.t() | nil
# to_prompt: "Household preferences: <guidance>." | nil

# ActiveInsightsCapsule
defstruct [:bodies]            # bodies :: [String.t()] (≤5)
# to_prompt: "Household patterns:\n- <body>\n- ..." | nil

# WeekPlanCapsule
defstruct [:week_start, :slots]  # slots :: [%{day, date, status}] status ∈ :empty|:assigned|:skipped
# to_prompt: "This week's dinner plan:\n  Monday <date>: empty\n  ..." | nil

# PantryBeliefsCapsule
defstruct [:names, :total]     # names :: [String.t()] (≤20), total :: non_neg_integer
# to_prompt: "Pantry has: a, b, c and N more." | nil
```

The structs are deliberately typed (not bare maps) so a future verifier/UI can
read `WeekPlanCapsule.slots` directly — this is the §A.4 "read the struct, not
the prose" property.

## Testing

- **Per-capsule unit tests** (one file each): `build/1` returns the struct with
  correct fields from seeded data; `to_prompt/1` produces the expected compact
  text; the empty case (`no prefs`/`no insights`/`empty pantry`/`unloaded plan`)
  returns `nil`. Pantry test asserts the 20-item cap + "and N more". Insights
  test asserts the ≤5 cap.
- **`compose/2` test**: given a list of capsule modules + a ctx, returns the
  joined non-nil prompts; a capsule whose `to_prompt` is `nil` is dropped; order
  follows the declared list.
- **Orchestrator integration**: an existing planner-run test still passes —
  i.e. dispatching `:planner_command_run` still produces a working system prompt
  (the migration is behavior-preserving for the model's standing context). Assert
  the composed prompt contains the household/week context for a seeded household
  (e.g. a known dietary guidance string or "This week's dinner plan").
- **Chat handler**: its existing test (if any) still passes with the composed
  prompt; otherwise a focused test that the chat system prompt includes the
  composed capsule text.
- Full suite green; gettext untouched (these are model-facing English prompts,
  not user-facing UI copy — no i18n).

## Out of scope

- The 4 deferred capsules (DealsDigest, RecipeAffinity, RecentHistory,
  CostIntent) — added with their consuming features.
- Any per-capsule formal token-budget accounting beyond the existing caps
  (20 pantry / 5 insights). The "budget lives in the capsule" rule is honored by
  those caps; a richer budget system is deferred.
- A `use Tore.Harness.Capsule` authoring macro / the broader DSL layer — captured
  separately as a future refactor once there are more run kinds; not built here.
- Weekly planning (`:weekly_planning_run`) — the next spec, built on these
  capsules.
