# Named per-change receipt lines — design

**Date:** 2026-06-05
**Status:** approved (pending spec review)
**Sub-spec of:** harness (see `2026-06-02-harness-foundation-design.md`, `2026-06-05-real-plan-diff-design.md`)

## Problem

The run receipt (`ToreWeb.Components.ReceiptLive`, the `Applied` variant) renders
a bare count rollup like "1 swapped, 1 skipped" via
`RunSummary.summary/1.text_fallback`. The recipe names and slots are already
captured in the `PlanDiff` artifact, but `RunSummary` collapses them to counts,
so the receipt can't name what changed.

## Goal

When a planner command applies changes, the receipt lists one localized line per
change, naming the recipe and the day — e.g. "Swapped in Ugnsraggmunk on
Saturday" / "Skipped Sunday" — reading like a real confirmation from Tore.

## Non-goals

- No change to `PlanDiff`, `RunSummary`, the Orchestrator, the Decider, or
  persistence. `PlanDiff.summarise/1` already returns everything needed.
- No app-wide locale wiring (see "Locale" below — out of scope).
- Only the `Applied` variant's body changes. Running/NeedsUser/Failed/Reverted
  are untouched.

## Data path

`PlanDiff.summarise/1` already returns per-slot rollup entries:

```elixir
%{slot_key: String.t(), change: rollup_change(), label: String.t() | nil, rationale: [String.t()]}
```

where `change ∈ :added | :swapped | :skipped | :leftover | :removed | :servings`.

`ReceiptLive`'s `Applied` branch finds the `PlanDiff` artifact in
`state.artifacts`, calls `summarise/1`, and maps each rollup entry to one
localized line. `RunSummary` is not consulted for the Applied body and is left
unchanged (it remains the count rollup used elsewhere).

If the `Applied` state has no `PlanDiff` artifact, or `summarise/1` returns `[]`,
the receipt shows a single line: `gettext("No changes")`.

## Rendering shape change

Today `ReceiptLive.update/2` assigns a single `body_html` string (rendered via
`Phoenix.HTML.raw`). For the `Applied` variant, the body becomes a **list of
lines**. Concretely:

- `update/2` computes, for an `%State.Applied{}` run, a `body_lines` list of
  plain strings (each already localized + plain text — no HTML).
- For all other variants, `body_lines` is `nil` and the existing single-string
  `body_html` is used as before.
- `render/2` renders a `<ul>` of `<li>` items when `@body_lines` is a non-empty
  list; otherwise it renders the existing single `body_html` block.

Each line is plain text rendered with `{line}` (auto-escaped by HEEx) — no
`raw`, no manual `html_escape`. (The current `escape/1` + `raw` dance exists
because the single body could contain pre-escaped content; line items are plain
strings and need no such handling.)

## Line wording

All strings go through `gettext` so they are localizable. The day is derived
from `slot_key` (`"sat_dinner"` → `"sat"` → localized day name).

### Day name

`ReceiptLive` defines its own private `day_name/1` — a closed 7-value `gettext`
map:

```elixir
defp day_name("mon"), do: gettext("Monday")
defp day_name("tue"), do: gettext("Tuesday")
defp day_name("wed"), do: gettext("Wednesday")
defp day_name("thu"), do: gettext("Thursday")
defp day_name("fri"), do: gettext("Friday")
defp day_name("sat"), do: gettext("Saturday")
defp day_name("sun"), do: gettext("Sunday")
defp day_name(other), do: String.capitalize(other)
```

The day token is `slot_key |> String.split("_", parts: 2) |> hd()`. (This
duplicates PlannerLive's private `day_name/1`. Intentional — a tiny closed
`gettext` map; reaching into another module's private helper would couple the
two. Do not extract a shared module.)

### Per-change line

A private `line_for/1` takes a rollup entry and returns the localized string.
`:added` and `:swapped` choose a with-label or no-label form based on whether
`label` is a non-empty binary; the others are always day-only.

| change | label present | label nil/blank |
|---|---|---|
| `:added` | `gettext("Added %{recipe} on %{day}", recipe: label, day: day)` | `gettext("Added a meal on %{day}", day: day)` |
| `:swapped` | `gettext("Swapped in %{recipe} on %{day}", recipe: label, day: day)` | `gettext("Swapped %{day}", day: day)` |
| `:skipped` | (n/a) | `gettext("Skipped %{day}", day: day)` |
| `:removed` | (n/a) | `gettext("Cleared %{day}", day: day)` |
| `:leftover` | (n/a) | `gettext("Leftovers on %{day}", day: day)` |
| `:servings` | (n/a) | `gettext("Adjusted servings on %{day}", day: day)` |

"label present" means `is_binary(label) and label != ""`. For `:skipped`,
`:removed`, `:leftover`, `:servings`, the label is ignored (these changes never
carry a recipe name).

### Empty

When the rollup is `[]` (no PlanDiff, or a PlanDiff with no events), `body_lines`
is `[gettext("No changes")]` — a single-item list, so the `<ul>` still renders
uniformly.

## Locale (known limitation, out of scope)

Every line is built with `gettext`, so the copy is fully localizable. However,
actually rendering in the household's chosen language requires
`Gettext.put_locale/1` to be set at LiveView mount from `current_user.locale`.
`PlannerLive` does not currently do this, so today these lines render in the app
default locale (`sv`). Wiring per-user locale at mount affects the whole app
(every gettext string), not just the receipt, and is therefore **not** part of
this sub-spec. This spec only guarantees the lines are *localizable*; switching
the active locale is a separate change.

## Components touched

- `lib/tore_web/components/receipt_live.ex` — the only file changed:
  - `update/2`: assign `body_lines` = `applied_lines(run)` for `%State.Applied{}`
    (always a non-empty list — at minimum `["No changes"]`), and `nil` for every
    other variant. Keep assigning `body_html` via `body/1` for the non-Applied
    variants.
  - `render/2`: when `@body_lines` is a list, render the `<ul>`/`<li>`; otherwise
    render the existing single `Phoenix.HTML.raw(@body_html)` block.
  - Remove the now-dead `body(%State.Applied{...})` clause and the
    `summary_text/1` helper (the Applied path always goes through `body_lines`,
    so neither is reachable). Leave `RunSummary` alias only if still referenced;
    after removing `summary_text/1`, the `alias Tore.Harness.Artifact.RunSummary`
    becomes unused — remove it to keep `--warnings-as-errors` clean. `alias
    Tore.Harness.Artifact` is still needed (for `Artifact.summary`? no — the
    rollup comes from `PlanDiff.summarise/1`; check and remove `Artifact` alias
    too if unused, add `alias Tore.Harness.Artifact.PlanDiff`).
  - new private helpers: `applied_lines/1` (state → [string]),
    `line_for/1` (rollup entry → string), `day_name/1`, `day_of/1`
    (slot_key → day token).

## Testing

`test/tore_web/components/receipt_live_test.exs` (extend):

- An `Applied` run whose PlanDiff has a `RecipeSwapped` event with `label`
  renders a line containing the recipe name and the day (e.g. matches
  "Ugnsraggmunk" and the day word).
- An `Applied` run with a `MealSkipped` event renders a "Skipped <day>" line and
  does NOT render a recipe name.
- An `Applied` run with a `RecipeAssigned` + label renders "Added <recipe> on
  <day>".
- An `Applied` run whose PlanDiff has no events (or no PlanDiff artifact) renders
  the "No changes" line.
- An `:added`/`:swapped` entry whose `label` is nil renders the no-label form
  ("Added a meal on <day>" / "Swapped <day>"), never a blank or the string
  "nil".
- Multiple changes render multiple `<li>` lines, one per slot rollup entry.
- The other variants (Running/NeedsUser/Failed/Reverted) still render their
  existing single-line bodies (regression — these tests already exist; confirm
  they pass unchanged).

Render via `render_component/2`, as the existing receipt tests do.

## Success criteria

1. An applied run with named changes shows one localized line per change,
   naming the recipe (for add/swap) and the day.
2. Skip/remove/leftover/servings lines render day-only, correctly phrased.
3. A nil/blank label on add/swap degrades to the day-only form.
4. An empty/absent PlanDiff renders a single "No changes" line.
5. Non-Applied variants are unchanged.
6. All copy is via `gettext`. Day names localized.
7. `mix test test/tore_web/components/receipt_live_test.exs` green;
   `mix compile --warnings-as-errors` clean; no new full-suite failures vs the
   `Groceries*` floor.
