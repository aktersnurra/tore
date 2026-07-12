# All-Handlers Tiger-Style Rename — Design

**Date:** 2026-06-12
**Status:** Approved design, ready for implementation plan

## Goal

Retire the `Tore.Handlers.*Handler` family. Tiger Style holds that "handler" is
filler — a name must assert what the thing *is* or *does*. Every one of the
eight handlers is really either (a) the same concept as an existing context
module, or (b) the imperative shell over a pure event-sourcing aggregate. Rename
each so its name is a true assertion, and delete `lib/tore/handlers/`.

This is a **pure rename/move refactor. Behavior must not change.** The test suite
is the safety net: the run-count stays at the 483/0 baseline (nothing added or
removed, only moved/renamed).

## The rule applied

A handler wraps a domain in LLM and/or event-sourcing orchestration. Resolve each
by which of three shapes it has:

- **Fold** — a sibling context module already exists and already mixes
  persistence, queries, and LLM work (e.g. `Tore.Recipes` already has
  `scrape_from_url/2`). The handler is a second name for the same concept. Move
  its functions into the context; delete the handler.
- **Bare context module** — the sibling is a *pure* aggregate living in dotted
  submodules (`Tore.Planning.Decider/.Events/.State/.Commands`,
  `Tore.Shop.Decider/.Aggregator/...`). The bare module (`Tore.Planning`,
  `Tore.Shop`) does not exist yet. Create it as the imperative shell that drives
  the pure submodules against the EventStore + PubSub — exactly how `Tore.Recipes`
  ties schemas to the Repo. The pure submodules stay untouched.
- **New module** — no sibling at all. Give it a plain domain name.

## The eight renames

| # | Handler | → Target | Strategy | Public functions |
|---|---|---|---|---|
| 1 | `Tore.Handlers.RecipeHandler` | `Tore.Recipes` | fold | `scrape_and_create/2`, `generate_image/2` |
| 2 | `Tore.Handlers.CostsHandler` | `Tore.Costs` | fold | `parse_receipt_image/1`, `parse_and_log_receipt/2`, `confirm_receipt/2`, `log_dining_out/2` |
| 3 | `Tore.Handlers.PantryHandler` | `Tore.Pantry` | fold | `parse_image/1`, `confirm_items/1` |
| 4 | `Tore.Handlers.DealsHandler` | `Tore.Deals` | fold | `scrape_all/0`, `scrape_url/3`, `parse_pdf/1` |
| 5 | `Tore.Handlers.PrepHandler` | `Tore.Prep` | fold | `generate_guide/3` |
| 6 | `Tore.Handlers.InsightsHandler` | `Tore.Insights` | new module | `synthesise_weekly/0` |
| 7 | `Tore.Handlers.PlanningHandler` | `Tore.Planning` | bare context | all 15 (`load_plan`, `plan_upcoming_week`, `assign_recipe`, `assign_with_leftovers`, `swap_events`, `swap_slots`, `apply_events`, `remove_recipe`, `set_servings`, `pin_slot`, `unpin_slot`, `skip_meal`, `mark_leftover`, `suggest_recipes_for_slot`) |
| 8 | `Tore.Handlers.GroceriesHandler` | `Tore.Shop` | bare context | all 7 (`load_list`, `build_list`, `add_item`, `remove_item`, `check_item`, `uncheck_item`, `export_list`) |

Note the asymmetry resolved here: `Tore.Shop` was renamed from `Tore.Groceries`
in the prior cycle (aggregate only); this cycle gives it its imperative shell, so
the aggregate and its operations finally share one name.

## Clash analysis (verified against the code)

- **No arity clashes** in Recipes, Pantry, Deals, Prep, Insights folds — all
  folded function names are distinct from the existing context functions.
- **`Tore.Costs.log_dining_out`:** the context already has
  `log_dining_out/1` (the persistence primitive), and the handler has
  `log_dining_out/2` (adds `user_id`, then calls down to `/1`). The `/1` form has
  **live callers** — `cost_live.ex:150` and `costs_test.exs` — so it must stay.
  **Resolution: keep both arities.** Fold the handler's `/2` in beside the
  existing `/1`; `/2` continues to call `/1`. No merge, no behavior change.
- **`Tore.Recipes` self-call:** `recipes.ex:98` and `recipes.ex:209` currently
  call `Tore.Handlers.RecipeHandler.{scrape_and_create,generate_image}`. After
  the fold these become **local in-module calls** — the apparent cycle dissolves.
- **Cross-handler call:** `CostsHandler.confirm_receipt` calls
  `PantryHandler.confirm_items`. After both fold, this is
  `Tore.Pantry.confirm_items` (`Tore.Costs` → `Tore.Pantry`, a normal context
  dependency).

## Call-site updates

Every reference, by file. (All are simple module-name substitutions except the
two `Tore.Recipes` self-calls, which become local.)

### Production — `lib/`

| File | Lines | Change |
|---|---|---|
| `lib/tore/recipes.ex` | 98, 209 | `Tore.Handlers.RecipeHandler.X` → local `X` (now in-module) |
| `lib/tore/photo_pipeline.ex` | 48, 56, 64 | `CostsHandler.parse_receipt_image` → `Tore.Costs.…`; `PantryHandler.parse_image` → `Tore.Pantry.…` (×2) |
| `lib/tore/llm/planner_tools.ex` | 12, 82 | `PlanningHandler.swap_events` → `Tore.Planning.swap_events` |
| `lib/tore/harness/orchestrator.ex` | 9, 121, 194 | `PlanningHandler` → `Tore.Planning` (`load_plan`, `apply_events`) |
| `lib/tore/harness/capsules/week_plan_capsule.ex` | 4, 15 | `PlanningHandler.load_plan` → `Tore.Planning.load_plan` |
| `lib/tore_web/live/home_live.ex` | 4, 14, 123, 124 | `PlanningHandler` → `Tore.Planning` |
| `lib/tore_web/live/kiosk_live.ex` | 4, 17, 51, 76 | `PlanningHandler` → `Tore.Planning` |
| `lib/tore_web/live/planner_live.ex` | 4, 22, 97, 174, 175, 194, 208, 283, 286, 317, 346, 1075 | `PlanningHandler` → `Tore.Planning`; `GroceriesHandler.build_list` → `Tore.Shop.build_list` (line 317) |
| `lib/tore_web/live/shop_live.ex` | 4, 15, 33, 35, 42, 47, 66, 79 | `GroceriesHandler` → `Tore.Shop` |
| `lib/tore_web/live/prep_live.ex` | 4, 31 | `PrepHandler.generate_guide` → `Tore.Prep.generate_guide` |
| `lib/tore_web/live/review_live.ex` | 55, 62 | `CostsHandler.confirm_receipt` → `Tore.Costs.…`; `PantryHandler.confirm_items` → `Tore.Pantry.…` |
| `lib/tore_web/live/deals_live.ex` | 4, 175, 187, 246 | `DealsHandler` → `Tore.Deals` |
| `lib/tore_web/live/cost_live.ex` | 5, 123, 204 | `CostsHandler` → `Tore.Costs` |

### Config — Quantum cron MFAs

| File | Lines | Change |
|---|---|---|
| `config/config.exs` | 61 | `{Tore.Handlers.InsightsHandler, :synthesise_weekly, []}` → `{Tore.Insights, …}` |
| `config/config.exs` | 62 | `{Tore.Handlers.DealsHandler, :scrape_all, []}` → `{Tore.Deals, …}` |
| `config/config.exs` | 63 | `{Tore.Handlers.PlanningHandler, :plan_upcoming_week, []}` → `{Tore.Planning, …}` |
| `config/config.exs` | 66 | `Tore.Handlers.PrepHandler.generate_guide(...)` → `Tore.Prep.generate_guide(...)` |

## Testing strategy

Pure rename — the suite stays **483 tests / 0 failures**, same count.

### Test file moves & retargets

| Old test file | Action |
|---|---|
| `test/tore/handlers/recipe_handler_test.exs` | move → `test/tore/recipes_scrape_test.exs`; `defmodule … RecipesScrapeTest`, drop `Tore.Handlers.` alias, calls → `Tore.Recipes.scrape_and_create` |
| `test/tore/handlers/costs_handler_test.exs` | move → `test/tore/costs_receipt_test.exs`; `defmodule … CostsReceiptTest`, retarget to `Tore.Costs` |
| `test/tore/handlers/deals_handler_test.exs` | move → `test/tore/deals_scrape_test.exs`; retarget to `Tore.Deals` |
| `test/tore/handlers/insights_handler_test.exs` | move → `test/tore/insights_test.exs`; retarget to `Tore.Insights` |
| `test/tore/handlers/prep_handler_test.exs` | move → `test/tore/prep_guide_test.exs`; retarget to `Tore.Prep` |
| `test/tore/handlers/groceries_handler_test.exs` | move → `test/tore/shop_test.exs`; `defmodule … ShopTest`, retarget to `Tore.Shop`, event structs already `Tore.Shop.Events.*` |
| (no `pantry_handler_test.exs` exists) | — |
| (no standalone `planning_handler_test.exs`) | — |

`Tore.Planning` is exercised indirectly; retarget those call-sites:

| Test file | Lines | Change |
|---|---|---|
| `test/tore/harness/orchestrator_test.exs` | 66, 161, 190, 208, 217, 218, 256 | `Tore.Handlers.PlanningHandler` → `Tore.Planning` |
| `test/tore/harness/weekly_planning_run_test.exs` | 9, 42, 43, 44, 69 | `Handlers.PlanningHandler` → `Tore.Planning` |
| `test/tore_web/live/planner_live_test.exs` | 6, 61, 78, 89, 98, 194, 201, 210, 217, 248 | `Handlers.PlanningHandler` → `Tore.Planning` |

### Gates

1. **Per-fold clash check** — before each fold, confirm no remaining arity clash.
   Only `log_dining_out` is special, and the resolution (keep both `/1` and `/2`)
   means no merge.
2. **Compile clean** — `mix compile --warnings-as-errors`. A missed reference
   surfaces as an undefined-function warning.
3. **Green gate** — `mix test` stays **483/0**. No test count change.
4. **Grep gate** — `grep -rn "Handlers\.\|Handler\b" lib/ test/ config/` returns
   nothing (incidental English words aside), and `lib/tore/handlers/` is deleted.

## Out of scope

- No behavior changes, no new functions, no signature changes (the `/2`
  `log_dining_out` already existed on the handler — folding it in is not a new
  signature).
- No touching the pure aggregate submodules (`Planning.Decider`, `Shop.Decider`,
  etc.).
- Cross-feature grocery vocabulary (`GroceryDiff`, `GroceryVerifier`,
  `:grocery_checkoff`, etc.) is unaffected — it names the grocery *concept*, not
  any handler.

## Sequencing note for the plan

Order the folds so cross-module calls land correctly:
**Pantry before Costs** (Costs.confirm_receipt calls Pantry.confirm_items), and
**Recipes' self-calls** updated in the same task as the fold. The two bare-context
creations (Planning, Shop) are independent and can go in any order. Insights is
fully independent.
