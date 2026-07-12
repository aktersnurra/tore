# All-Handlers Tiger-Style Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the `Tore.Handlers.*Handler` family — fold context-backed handlers into their existing context modules, turn Planning/Groceries into bare imperative-shell context modules over their pure aggregates, and make Insights a plain module.

**Architecture:** Pure rename/move refactor. No behavior changes. Each handler is moved to a name that asserts what it does; every call-site is updated; the test suite stays at the 483/0 baseline (tests are moved/retargeted, never added or removed). One handler per commit.

**Tech Stack:** Elixir, Phoenix LiveView, event-sourcing (EventStore + Decider pattern), Mox for LLM stubbing, jj (Jujutsu) for VCS — **never git**.

**Spec:** `docs/specs/2026-06-12-all-handlers-rename-design.md`

---

## Critical Conventions (read before starting)

- **VCS is jj, NOT git.** Commit with `jj commit -m "<msg>"` (this describes `@`
  and starts a fresh change). Never run any `git` command.
- **Commit message footer:** end every commit message with:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Test env runs in the `sv` locale.** Not relevant here (no user-facing
  strings change), but don't be surprised by Swedish in unrelated output.
- **Baseline:** `mix test` is **483 tests, 0 failures** before you start. It must
  stay exactly 483/0 after every task. Run `mix test` to confirm the baseline now.
- **Dependency order matters.** `Tore.Costs.confirm_receipt` calls
  `Tore.Pantry.confirm_items`, and `Tore.Prep.generate_guide` calls
  `Tore.Planning.load_plan`. Do tasks in the order given so each fold's
  dependencies already carry their new names.
- After each handler is moved, **delete the old handler file** and its **old test
  file** in the same task. At the end, `lib/tore/handlers/` must not exist.

---

## File Structure (what changes)

**Deleted at the end:** the entire `lib/tore/handlers/` directory (8 files) and
`test/tore/handlers/` (7 test files).

**Modified context modules (folds):** `lib/tore/recipes.ex`, `lib/tore/costs.ex`,
`lib/tore/pantry.ex`, `lib/tore/deals.ex`, `lib/tore/prep.ex`.

**New files:** `lib/tore/planning.ex` (bare context), `lib/tore/shop.ex` (bare
context), `lib/tore/insights.ex` (new module).

**Moved/retargeted tests:** see each task.

**Call-site updates:** `lib/tore/photo_pipeline.ex`, `lib/tore/llm/planner_tools.ex`,
`lib/tore/harness/orchestrator.ex`, `lib/tore/harness/capsules/week_plan_capsule.ex`,
`lib/tore_web/live/{home,kiosk,planner,shop,prep,review,deals,cost}_live.ex`,
`config/config.exs`, and several test files.

---

## Task 1: Planning → `Tore.Planning` (bare context)

`Tore.Handlers.PlanningHandler` becomes `Tore.Planning` — the imperative shell
over the pure `Tore.Planning.{Decider,Events,State,Commands}` submodules. This is
first because Prep (Task 8) and the most call-sites depend on it.

**Files:**

- Create: `lib/tore/planning.ex` (moved from `lib/tore/handlers/planning_handler.ex`)
- Delete: `lib/tore/handlers/planning_handler.ex`
- Modify (call-sites): `lib/tore/llm/planner_tools.ex:12,82`,
  `lib/tore/harness/orchestrator.ex:9,121,194`,
  `lib/tore/harness/capsules/week_plan_capsule.ex:4,15`,
  `lib/tore_web/live/home_live.ex:4,14,123,124`,
  `lib/tore_web/live/kiosk_live.ex:4,17,51,76`,
  `lib/tore_web/live/planner_live.ex:4,22,97,174,175,194,208,283,286,346,1075`,
  `config/config.exs:63`
- Modify (tests): `test/tore/harness/orchestrator_test.exs`,
  `test/tore/harness/weekly_planning_run_test.exs`,
  `test/tore_web/live/planner_live_test.exs`

- [ ] **Step 1: Move the file and rename the module**

```bash
mv lib/tore/handlers/planning_handler.ex lib/tore/planning.ex
```

Change line 1 of `lib/tore/planning.ex` from:

```elixir
defmodule Tore.Handlers.PlanningHandler do
```

to:

```elixir
defmodule Tore.Planning do
```

The body is unchanged — its aliases (`Tore.Planning.Decider`, `.Commands`,
`.State`, `.Events`) already reference the pure submodules and are unaffected.

- [ ] **Step 2: Update production call-sites**

`lib/tore/llm/planner_tools.ex` line 12 — change:

```elixir
  alias Tore.Handlers.PlanningHandler
```

to:

```elixir
  alias Tore.Planning
```

Line 82 — change `PlanningHandler.swap_events(...)` to `Planning.swap_events(...)`.

`lib/tore/harness/orchestrator.ex` line 9 — change:

```elixir
  alias Tore.Handlers.PlanningHandler
```

to:

```elixir
  alias Tore.Planning
```

Lines 121, 194 — change `PlanningHandler.load_plan` → `Planning.load_plan`,
`PlanningHandler.apply_events` → `Planning.apply_events`.

`lib/tore/harness/capsules/week_plan_capsule.ex` line 4 — change
`alias Tore.Handlers.PlanningHandler` → `alias Tore.Planning`; line 15
`PlanningHandler.load_plan` → `Planning.load_plan`.

`lib/tore_web/live/home_live.ex` line 4 — change:

```elixir
  alias Tore.{Recipes, Handlers.PlanningHandler, CounterNotes}
```

to:

```elixir
  alias Tore.{Recipes, Planning, CounterNotes}
```

Lines 14, 123, 124 — `PlanningHandler` → `Planning`.

`lib/tore_web/live/kiosk_live.ex` line 4 — change:

```elixir
  alias Tore.{Recipes, Handlers.PlanningHandler}
```

to:

```elixir
  alias Tore.{Recipes, Planning}
```

Lines 17, 51, 76 — `PlanningHandler` → `Planning`.

`lib/tore_web/live/planner_live.ex` line 4 — change:

```elixir
  alias Tore.{Recipes, Handlers.PlanningHandler, Handlers.GroceriesHandler, PlanHealth}
```

to (note: GroceriesHandler is handled in Task 2; for now keep it referencing the
old name to keep this task compiling — change ONLY the Planning part):

```elixir
  alias Tore.{Recipes, Planning, Handlers.GroceriesHandler, PlanHealth}
```

Lines 22, 97, 174, 175, 194, 208, 283, 286, 346, 1075 — `PlanningHandler` →
`Planning`. (Line 317 is `GroceriesHandler.build_list` — leave it for Task 2.)

`config/config.exs` line 63 — change:

```elixir
    {"0 18 * * 6", {Tore.Handlers.PlanningHandler, :plan_upcoming_week, []}},
```

to:

```elixir
    {"0 18 * * 6", {Tore.Planning, :plan_upcoming_week, []}},
```

- [ ] **Step 3: Update test call-sites**

`test/tore/harness/orchestrator_test.exs` lines 66, 161, 190, 208, 217, 218, 256
— replace `Tore.Handlers.PlanningHandler` with `Tore.Planning`.

`test/tore/harness/weekly_planning_run_test.exs` line 9 — change:

```elixir
  alias Tore.{Handlers.PlanningHandler, Recipes}
```

to:

```elixir
  alias Tore.{Planning, Recipes}
```

Lines 42, 43, 44, 69 — `PlanningHandler` → `Planning`.

`test/tore_web/live/planner_live_test.exs` line 6 — change:

```elixir
  alias Tore.{Accounts, Recipes, Handlers.PlanningHandler}
```

to:

```elixir
  alias Tore.{Accounts, Recipes, Planning}
```

Lines 61, 78, 89, 98, 194, 201, 210, 217, 248 — `PlanningHandler` → `Planning`.

- [ ] **Step 4: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. (A leftover `PlanningHandler` reference would surface as
an undefined-module warning.) Note `Tore.Handlers.PrepHandler` still references
`PlanningHandler` at this point — **you must also update it now** so compilation
stays clean: in `lib/tore/handlers/prep_handler.ex` line 2 change
`Tore.{Handlers.PlanningHandler, Prep, Recipes, SpendGuard}` to
`Tore.{Planning, Prep, Recipes, SpendGuard}`, and line 8
`PlanningHandler.load_plan` → `Planning.load_plan`. (Prep is fully folded in
Task 8; this keeps it compiling in the meantime.)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 6: Commit**

```bash
jj commit -m "refactor(planning): PlanningHandler -> Tore.Planning (bare context shell)

The imperative shell over the pure Planning.Decider/.Events/.State/.Commands
submodules now lives in the bare Tore.Planning module, matching the
Tore.Recipes context pattern. Pure rename, all call-sites updated, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Groceries → `Tore.Shop` (bare context)

`Tore.Handlers.GroceriesHandler` becomes `Tore.Shop` — the imperative shell over
the pure `Tore.Shop.{Decider,Events,State,Commands,Aggregator}` submodules.

**Files:**

- Create: `lib/tore/shop.ex` (moved from `lib/tore/handlers/groceries_handler.ex`)
- Delete: `lib/tore/handlers/groceries_handler.ex`
- Move test: `test/tore/handlers/groceries_handler_test.exs` →
  `test/tore/shop_test.exs`
- Modify (call-sites): `lib/tore_web/live/shop_live.ex:4,15,33,35,42,47,66,79`,
  `lib/tore_web/live/planner_live.ex:4,317`

- [ ] **Step 1: Move the file and rename the module**

```bash
mv lib/tore/handlers/groceries_handler.ex lib/tore/shop.ex
```

Change line 1 of `lib/tore/shop.ex` from:

```elixir
defmodule Tore.Handlers.GroceriesHandler do
```

to:

```elixir
defmodule Tore.Shop do
```

The body is unchanged — aliases (`Tore.Shop.Decider`, `.Commands`, `.Aggregator`)
already reference the pure submodules. **Do not** add a `Tore.Shop.List` or any
name shadowing a kernel module.

- [ ] **Step 2: Update production call-sites**

`lib/tore_web/live/shop_live.ex` line 4 — change:

```elixir
  alias Tore.Handlers.GroceriesHandler
```

to:

```elixir
  alias Tore.Shop
```

Lines 15, 33, 35, 42, 47, 66, 79 — replace `GroceriesHandler` with `Shop`.

`lib/tore_web/live/planner_live.ex` line 4 — change:

```elixir
  alias Tore.{Recipes, Planning, Handlers.GroceriesHandler, PlanHealth}
```

to:

```elixir
  alias Tore.{Recipes, Planning, Shop, PlanHealth}
```

Line 317 — change `GroceriesHandler.build_list(...)` to `Shop.build_list(...)`.

- [ ] **Step 3: Move and retarget the test**

```bash
mv test/tore/handlers/groceries_handler_test.exs test/tore/shop_test.exs
```

In `test/tore/shop_test.exs`:
- Line 1: `defmodule Tore.Handlers.GroceriesHandlerTest do` →
  `defmodule Tore.ShopTest do`
- Line 6: `alias Tore.{Handlers.GroceriesHandler, Recipes}` →
  `alias Tore.{Shop, Recipes}`
- Replace every `GroceriesHandler.` call (lines 24, 29, 30, 38, 43, 44, 47, 48,
  55, 59, 60, 63, 75, 76) with `Shop.`. The event struct asserts
  (`%Tore.Shop.Events.ItemAdded{}`, `ItemChecked`, `ListBuilt`) are already
  correct — leave them.

- [ ] **Step 4: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 6: Commit**

```bash
jj commit -m "refactor(shop): GroceriesHandler -> Tore.Shop (bare context shell)

The shop-list command surface now lives in the bare Tore.Shop module over its
pure Shop.Decider/.Aggregator submodules — aggregate and operations share one
name. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Insights → `Tore.Insights` (new module)

`Tore.Handlers.InsightsHandler` has no sibling context; it becomes the plain
module `Tore.Insights`. Fully independent of every other task.

**Files:**

- Create: `lib/tore/insights.ex` (moved from `lib/tore/handlers/insights_handler.ex`)
- Delete: `lib/tore/handlers/insights_handler.ex`
- Move test: `test/tore/handlers/insights_handler_test.exs` →
  `test/tore/insights_test.exs`
- Modify: `config/config.exs:61`

- [ ] **Step 1: Move the file and rename the module**

```bash
mv lib/tore/handlers/insights_handler.ex lib/tore/insights.ex
```

Change line 1 of `lib/tore/insights.ex` from:

```elixir
defmodule Tore.Handlers.InsightsHandler do
```

to:

```elixir
defmodule Tore.Insights do
```

Body unchanged.

- [ ] **Step 2: Update the cron call-site**

`config/config.exs` line 61 — change:

```elixir
    {"0 6 * * 6", {Tore.Handlers.InsightsHandler, :synthesise_weekly, []}},
```

to:

```elixir
    {"0 6 * * 6", {Tore.Insights, :synthesise_weekly, []}},
```

- [ ] **Step 3: Move and retarget the test**

```bash
mv test/tore/handlers/insights_handler_test.exs test/tore/insights_test.exs
```

In `test/tore/insights_test.exs`:
- Line 1: `defmodule Tore.Handlers.InsightsHandlerTest do` →
  `defmodule Tore.InsightsTest do`
- Line 5: `alias Tore.Handlers.InsightsHandler` → `alias Tore.Insights`
- Replace every `InsightsHandler.` call (lines 32, 44, 45, 54) with `Insights.`.

- [ ] **Step 4: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 6: Commit**

```bash
jj commit -m "refactor(insights): InsightsHandler -> Tore.Insights

No sibling context existed; the weekly insight synthesis becomes the plain
Tore.Insights module. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Pantry fold → `Tore.Pantry`

Fold `PantryHandler.{parse_image,confirm_items}` into `Tore.Pantry`. Done before
Costs because `Tore.Costs.confirm_receipt` calls `confirm_items`.

**Files:**

- Modify: `lib/tore/pantry.ex` (add two functions + the `@llm` attribute)
- Delete: `lib/tore/handlers/pantry_handler.ex`
- Modify (call-sites): `lib/tore/photo_pipeline.ex:56,64`,
  `lib/tore_web/live/review_live.ex:62`
- (no `pantry_handler_test.exs` exists)

- [ ] **Step 1: Add the two functions to `Tore.Pantry`**

At the top of `lib/tore/pantry.ex`, after the `defmodule Tore.Pantry do` line, add
the LLM client attribute (check it is not already present first):

```elixir
  @llm Application.compile_env(:tore, :llm_client)
```

Add these two functions to the module (anywhere among the public functions):

```elixir
  def parse_image(image_binary) do
    @llm.parse_pantry_image(image_binary)
  end

  def confirm_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case add_item(item) do
        {:ok, pantry_item} -> {:cont, {:ok, [pantry_item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
      error -> error
    end
  end
```

Note `confirm_items` calls `add_item` (now a local call, since `Tore.Pantry`
already defines `add_item/1`).

- [ ] **Step 2: Delete the handler**

```bash
rm lib/tore/handlers/pantry_handler.ex
```

- [ ] **Step 3: Update call-sites**

`lib/tore/photo_pipeline.ex` lines 56, 64 — change
`Tore.Handlers.PantryHandler.parse_image(image)` →
`Tore.Pantry.parse_image(image)` (both occurrences).

`lib/tore_web/live/review_live.ex` line 62 — change
`Tore.Handlers.PantryHandler.confirm_items(...)` →
`Tore.Pantry.confirm_items(...)`.

- [ ] **Step 4: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. (`Tore.Costs.confirm_receipt` still references
`Tore.Handlers.PantryHandler.confirm_items` — update it now so compilation stays
clean: in `lib/tore/handlers/costs_handler.ex` line 38 change
`Tore.Handlers.PantryHandler.confirm_items(items)` →
`Tore.Pantry.confirm_items(items)`. Costs is fully folded in Task 5.)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 6: Commit**

```bash
jj commit -m "refactor(pantry): fold PantryHandler into Tore.Pantry

parse_image/1 and confirm_items/1 move into the Pantry context; confirm_items
now calls the local add_item/1. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Costs fold → `Tore.Costs`

Fold `CostsHandler.{parse_receipt_image,parse_and_log_receipt,confirm_receipt,log_dining_out}`
into `Tore.Costs`. `Tore.Costs.log_dining_out/1` already exists and has live
callers — **keep it**; add the handler's `/2` beside it.

**Files:**

- Modify: `lib/tore/costs.ex` (add four functions + `@llm` + two private helpers)
- Delete: `lib/tore/handlers/costs_handler.ex`
- Move test: `test/tore/handlers/costs_handler_test.exs` →
  `test/tore/costs_receipt_test.exs`
- Modify (call-sites): `lib/tore/photo_pipeline.ex:48`,
  `lib/tore_web/live/review_live.ex:55`,
  `lib/tore_web/live/cost_live.ex:5,123,204`

- [ ] **Step 1: Add the four functions + helpers to `Tore.Costs`**

At the top of `lib/tore/costs.ex`, after `defmodule Tore.Costs do`, add (if not
already present):

```elixir
  @llm Application.compile_env(:tore, :llm_client)
```

Add these public functions to the module:

```elixir
  def parse_receipt_image(image_binary) do
    @llm.parse_receipt_for_pantry(image_binary)
  end

  def parse_and_log_receipt(image_binary, user_id) do
    image_path = store_receipt_image(image_binary)

    with {:ok, line_items, _usage} <- @llm.parse_receipt_image(image_binary) do
      total =
        line_items
        |> Enum.map(fn item -> item.total_price || Decimal.new(0) end)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      log_receipt(%{
        date: Date.utc_today(),
        image_path: image_path,
        total_amount: total,
        user_id: user_id,
        line_items: line_items
      })
    end
  end

  def confirm_receipt(%{total: total, store_name: store_name, items: items, date: date}, user_id) do
    total_decimal = receipt_to_decimal(total)

    with {:ok, _receipt} <-
           log_receipt(%{
             date: date,
             store_name: store_name,
             total_amount: total_decimal,
             user_id: user_id,
             line_items: []
           }) do
      Tore.Pantry.confirm_items(items)
    end
  end

  def log_dining_out(attrs, user_id) do
    log_dining_out(Map.put(attrs, :user_id, user_id))
  end
```

Note: `log_receipt` is a local call (already defined in `Tore.Costs`);
`log_dining_out/2` calls the existing `log_dining_out/1` (keep both arities).

Add these two private helpers (rename them from the handler's generic names to
avoid colliding with anything in `Tore.Costs`):

```elixir
  defp receipt_to_decimal(nil), do: nil
  defp receipt_to_decimal(%Decimal{} = d), do: d
  defp receipt_to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp receipt_to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp receipt_to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp store_receipt_image(binary) do
    filename = "#{System.unique_integer([:positive])}.jpg"
    dir = Path.join([:code.priv_dir(:tore), "static", "uploads", "receipts"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), binary)
    "/uploads/receipts/#{filename}"
  end
```

(If `Tore.Costs` already defines a private `to_decimal/1`, prefer reusing it and
drop `receipt_to_decimal`. Check first; the handler used its own `to_decimal`.)

- [ ] **Step 2: Delete the handler**

```bash
rm lib/tore/handlers/costs_handler.ex
```

- [ ] **Step 3: Update call-sites**

`lib/tore/photo_pipeline.ex` line 48 — change
`Tore.Handlers.CostsHandler.parse_receipt_image(image)` →
`Tore.Costs.parse_receipt_image(image)`.

`lib/tore_web/live/review_live.ex` line 55 — change
`Tore.Handlers.CostsHandler.confirm_receipt(...)` →
`Tore.Costs.confirm_receipt(...)`.

`lib/tore_web/live/cost_live.ex` line 5 — change:

```elixir
  alias Tore.Handlers.CostsHandler
```

to (check whether `Tore.Costs` is already aliased in this file; `cost_live.ex:150`
already calls `Costs.log_dining_out`, so an alias `Costs` likely exists — if so,
just delete the `CostsHandler` alias line and use `Costs` below):

```elixir
  alias Tore.Costs
```

Lines 123, 204 — change `CostsHandler.confirm_receipt` → `Costs.confirm_receipt`,
`CostsHandler.parse_receipt_image` → `Costs.parse_receipt_image`.

- [ ] **Step 4: Move and retarget the test**

```bash
mv test/tore/handlers/costs_handler_test.exs test/tore/costs_receipt_test.exs
```

In `test/tore/costs_receipt_test.exs`:
- Line 1: `defmodule Tore.Handlers.CostsHandlerTest do` →
  `defmodule Tore.CostsReceiptTest do`
- Replace every `Tore.Handlers.CostsHandler.` call (lines 26, 36, 47) with
  `Tore.Costs.`.

- [ ] **Step 5: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 7: Commit**

```bash
jj commit -m "refactor(costs): fold CostsHandler into Tore.Costs

Receipt parsing/logging and dining-out logging move into the Costs context;
confirm_receipt now calls Tore.Pantry.confirm_items. log_dining_out/1 is kept
(live callers) with the folded /2 beside it. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Recipes fold → `Tore.Recipes`

Fold `RecipeHandler.{scrape_and_create,generate_image}` into `Tore.Recipes`. The
two existing self-calls in `recipes.ex` become local calls.

**Files:**

- Modify: `lib/tore/recipes.ex` (add two functions + `import Ecto.Query` already
  present; add `@http`, `@llm`, `@image_gen` attributes; update lines 98, 209)
- Delete: `lib/tore/handlers/recipe_handler.ex`
- Move test: `test/tore/handlers/recipe_handler_test.exs` →
  `test/tore/recipes_scrape_test.exs`

- [ ] **Step 1: Add the two functions to `Tore.Recipes`**

At the top of `lib/tore/recipes.ex` (after `alias` lines), add the three client
attributes (check none are already present):

```elixir
  @http Application.compile_env(:tore, :http_client)
  @llm Application.compile_env(:tore, :llm_client)
  @image_gen Application.compile_env(:tore, :image_gen_client)
```

Add these public functions and their private helpers to the module:

```elixir
  @spec scrape_and_create(String.t(), String.t() | nil) ::
          {:ok, Recipe.t()} | {:error, term()}
  def scrape_and_create(url, locale \\ nil) do
    with {:ok, html} <- @http.fetch(url),
         {:ok, attrs} <- parse_or_extract(html, locale) do
      create(Map.put(attrs, :source_url, url))
    end
  end

  @spec generate_image(Recipe.t(), String.t() | nil) :: :ok | {:error, term()}
  def generate_image(recipe, image_url) do
    storage = Tore.Storage.client()
    key = "recipes/#{recipe.id}/#{Ecto.UUID.generate()}.jpg"

    with {:ok, binary} <- fetch_or_generate(recipe, image_url),
         {:ok, url} <-
           storage.put_object(Tore.Storage.Buckets.recipes(), key, binary,
             content_type: "image/jpeg"
           ) do
      Repo.update_all(
        from(r in Recipe, where: r.id == ^recipe.id),
        set: [image_path: url]
      )

      :ok
    end
  end

  defp parse_or_extract(html, locale) do
    with {:error, :not_found} <- Tore.Recipes.Parser.parse_html(html) do
      @llm.extract_recipe_from_html(html, locale)
    end
  end

  defp fetch_or_generate(_recipe, image_url) when is_binary(image_url) and image_url != "" do
    @http.fetch(image_url)
  end

  defp fetch_or_generate(recipe, _image_url) do
    @image_gen.generate_food_image(recipe.title, recipe.instructions)
  end
```

Note: `create`, `Repo`, `Recipe`, and `from` are all already in scope in
`Tore.Recipes` (`import Ecto.Query` and the aliases at the top).

- [ ] **Step 2: Convert the two self-calls to local calls**

`lib/tore/recipes.ex` line 98 — change:

```elixir
    Tore.Handlers.RecipeHandler.scrape_and_create(url, locale)
```

to:

```elixir
    scrape_and_create(url, locale)
```

Line 209 — change:

```elixir
      Tore.Handlers.RecipeHandler.generate_image(loaded, image_url)
```

to:

```elixir
      generate_image(loaded, image_url)
```

- [ ] **Step 3: Delete the handler**

```bash
rm lib/tore/handlers/recipe_handler.ex
```

- [ ] **Step 4: Move and retarget the test**

```bash
mv test/tore/handlers/recipe_handler_test.exs test/tore/recipes_scrape_test.exs
```

In `test/tore/recipes_scrape_test.exs`:
- Line 1: `defmodule Tore.Handlers.RecipeHandlerTest do` →
  `defmodule Tore.RecipesScrapeTest do`
- Line 4: `alias Tore.Handlers.RecipeHandler` → `alias Tore.Recipes`
- Replace every `RecipeHandler.` call (lines 23, 37, 45) with `Recipes.`.

- [ ] **Step 5: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 7: Commit**

```bash
jj commit -m "refactor(recipes): fold RecipeHandler into Tore.Recipes

scrape_and_create/2 and generate_image/2 move into the Recipes context; the two
former cross-module self-calls become local. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Deals fold → `Tore.Deals`

Fold `DealsHandler.{scrape_all,scrape_url,parse_pdf}` into `Tore.Deals`.

**Files:**

- Modify: `lib/tore/deals.ex` (add three public functions + private helpers +
  `require Logger`, `@http`, `@llm`, and the `Alerts`/`StoreConfig` aliases)
- Delete: `lib/tore/handlers/deals_handler.ex`
- Move test: `test/tore/handlers/deals_handler_test.exs` →
  `test/tore/deals_scrape_test.exs`
- Modify (call-sites): `lib/tore_web/live/deals_live.ex:4,175,187,246`

- [ ] **Step 1: Add scraping functions to `Tore.Deals`**

At the top of `lib/tore/deals.ex`, ensure these are present (add any missing;
`Tore.Deals` already aliases `Repo` and defines `upsert_deals`):

```elixir
  require Logger
  alias Tore.{Alerts, Deals.StoreConfig}

  @http Application.compile_env(:tore, :http_client)
  @llm Application.compile_env(:tore, :llm_client)
```

(Do not re-alias `Tore.Deals` from inside `Tore.Deals`, and do not re-alias `Repo`
if already aliased — check the existing header.)

Add these public functions:

```elixir
  @spec scrape_all() :: :ok
  def scrape_all do
    StoreConfig
    |> Repo.all()
    |> Enum.filter(& &1.scrape_enabled)
    |> Enum.each(&scrape_store/1)

    :ok
  end

  @spec scrape_url(String.t(), atom(), String.t() | nil) :: {:ok, integer()} | {:error, term()}
  def scrape_url(url, chain, store_name \\ nil) do
    parser = parser_for(chain)

    with {:ok, html} <- @http.fetch(url),
         {:ok, deals} <- parser.parse(html) do
      deals =
        if store_name do
          Enum.map(deals, fn d ->
            d
            |> Map.put(:store, store_name)
            |> Map.put_new(:chain, to_string(chain))
          end)
        else
          Enum.map(deals, &Map.put_new(&1, :chain, to_string(chain)))
        end

      case deals do
        [] ->
          Logger.warning("scrape returned 0 deals — parser may be broken",
            url: url,
            chain: chain
          )

          Alerts.scrape_zero_results(url, chain)
          {:ok, 0}

        _ ->
          upsert_deals(deals)
      end
    end
  end

  @spec parse_pdf(binary()) :: {:ok, integer()} | {:error, term()}
  def parse_pdf(pdf_binary) do
    with {:ok, deals} <- @llm.parse_deals_pdf(pdf_binary) do
      case deals do
        [] ->
          Logger.warning("PDF parse returned 0 deals")
          {:ok, 0}

        _ ->
          upsert_deals(deals)
      end
    end
  end
```

Add these private helpers:

```elixir
  defp scrape_store(store_config) do
    case scrape_url(store_config.url, store_config.chain, store_config.name) do
      {:ok, count} ->
        Logger.info("scraped #{count} deals", store: store_config.name, url: store_config.url)

      {:error, reason} ->
        Logger.error("scrape failed",
          store: store_config.name,
          url: store_config.url,
          reason: inspect(reason)
        )
    end
  end

  defp parser_for(:ica), do: Tore.Deals.Parsers.ICA
  defp parser_for(:coop), do: Tore.Deals.Parsers.Coop
```

Note `upsert_deals` is a local call (already in `Tore.Deals`).

- [ ] **Step 2: Delete the handler**

```bash
rm lib/tore/handlers/deals_handler.ex
```

- [ ] **Step 3: Update call-sites**

`lib/tore_web/live/deals_live.ex` line 4 — change:

```elixir
  alias Tore.{Deals, Handlers.DealsHandler}
```

to:

```elixir
  alias Tore.Deals
```

Lines 175, 187, 246 — change `DealsHandler.scrape_url` → `Deals.scrape_url`,
`DealsHandler.scrape_all` → `Deals.scrape_all`, `DealsHandler.parse_pdf` →
`Deals.parse_pdf`.

`config/config.exs` line 62 — change:

```elixir
    {"0 8 * * 6", {Tore.Handlers.DealsHandler, :scrape_all, []}},
```

to:

```elixir
    {"0 8 * * 6", {Tore.Deals, :scrape_all, []}},
```

- [ ] **Step 4: Move and retarget the test**

```bash
mv test/tore/handlers/deals_handler_test.exs test/tore/deals_scrape_test.exs
```

In `test/tore/deals_scrape_test.exs`:
- Line 1: `defmodule Tore.Handlers.DealsHandlerTest do` →
  `defmodule Tore.DealsScrapeTest do`
- Replace every `Tore.Handlers.DealsHandler.` call (lines 18, 28, 32) with
  `Tore.Deals.`.

- [ ] **Step 5: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 7: Commit**

```bash
jj commit -m "refactor(deals): fold DealsHandler into Tore.Deals

scrape_all/0, scrape_url/3, parse_pdf/1 and their helpers move into the Deals
context; upsert_deals is now a local call. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Prep fold → `Tore.Prep`

Fold `PrepHandler.generate_guide` into `Tore.Prep`. Done last because it depends
on `Tore.Planning` (Task 1). Its alias was already updated to `Tore.Planning` in
Task 1 Step 4 — confirm that before starting.

**Files:**

- Modify: `lib/tore/prep.ex` (add `generate_guide/3` + private helper + `@llm` +
  aliases)
- Delete: `lib/tore/handlers/prep_handler.ex`
- Move test: `test/tore/handlers/prep_handler_test.exs` →
  `test/tore/prep_guide_test.exs`
- Modify (call-sites): `lib/tore_web/live/prep_live.ex:4,31`,
  `config/config.exs:66`

- [ ] **Step 1: Add `generate_guide/3` to `Tore.Prep`**

At the top of `lib/tore/prep.ex`, after `defmodule Tore.Prep do`, add (check the
existing header — `Tore.Prep` already defines `save_guide`):

```elixir
  alias Tore.{Planning, Recipes, SpendGuard}

  @llm Application.compile_env(:tore, :llm_client)
```

Add the public function and its private helper:

```elixir
  def generate_guide(plan_id, week_start, locale \\ nil) do
    with :ok <- SpendGuard.allow?(:generate_prep_guide),
         {:ok, plan_state} <- Planning.load_plan(plan_id) do
      plan_for_prompt = build_plan_for_prompt(plan_state, week_start)

      with {:ok, guide_data, usage} <- @llm.generate_prep_guide(plan_for_prompt, locale),
           :ok <- SpendGuard.log_usage(:generate_prep_guide, usage) do
        attrs = Map.put(guide_data, "week_start", week_start)
        save_guide(attrs)
      end
    end
  end

  defp build_plan_for_prompt(plan_state, week_start) do
    days =
      Enum.map(plan_state.slots, fn {slot_key, slot} ->
        recipe = if slot.recipe_id, do: Recipes.get!(slot.recipe_id), else: nil
        %{slot_key: slot_key, recipe_title: recipe && recipe.title, servings: slot.servings}
      end)

    %{week_start: week_start, days: days}
  end
```

Note `save_guide` is a local call (already in `Tore.Prep`).

- [ ] **Step 2: Delete the handler**

```bash
rm lib/tore/handlers/prep_handler.ex
```

- [ ] **Step 3: Update call-sites**

`lib/tore_web/live/prep_live.ex` line 4 — change:

```elixir
  alias Tore.{Handlers.PrepHandler, Prep}
```

to:

```elixir
  alias Tore.Prep
```

Line 31 — change `PrepHandler.generate_guide(...)` → `Prep.generate_guide(...)`.

`config/config.exs` line 66 — change:

```elixir
       Tore.Handlers.PrepHandler.generate_guide("plan:current", Date.utc_today())
```

to:

```elixir
       Tore.Prep.generate_guide("plan:current", Date.utc_today())
```

- [ ] **Step 4: Move and retarget the test**

```bash
mv test/tore/handlers/prep_handler_test.exs test/tore/prep_guide_test.exs
```

In `test/tore/prep_guide_test.exs`:
- Line 1: `defmodule Tore.Handlers.PrepHandlerTest do` →
  `defmodule Tore.PrepGuideTest do`
- Line 6: `alias Tore.Handlers.PrepHandler` → `alias Tore.Prep`
- Replace every `PrepHandler.` call (lines 40, 48, 59) with `Prep.`.

- [ ] **Step 5: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: **483 tests, 0 failures.**

- [ ] **Step 7: Commit**

```bash
jj commit -m "refactor(prep): fold PrepHandler into Tore.Prep

generate_guide/3 moves into the Prep context, calling Tore.Planning.load_plan
and the local save_guide. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Cleanup gate — delete `Tore.Handlers`, prove totality

By now `lib/tore/handlers/` should hold no files and `test/tore/handlers/` should
hold none either. This task verifies the rename is total and removes the empty
directories.

**Files:**

- Delete: `lib/tore/handlers/` (empty dir), `test/tore/handlers/` (empty dir)
- Modify: `SPEC.md` (module map), `CHANGELOG.md` (append entry)

- [ ] **Step 1: Prove no handler references remain**

Run:

```bash
grep -rn "Tore.Handlers\|Handler\b" lib/ test/ config/
```

Expected: **no matches** for `Tore.Handlers` or any `*Handler` module name. (If
the grep catches an incidental English word like "handler" in a comment, confirm
it is not a module reference and is acceptable. There should be none in this
codebase.)

- [ ] **Step 2: Confirm the directories are empty and remove them**

Run:

```bash
ls lib/tore/handlers/ test/tore/handlers/
```

Expected: both empty. Then:

```bash
rmdir lib/tore/handlers test/tore/handlers
```

- [ ] **Step 3: Update SPEC.md module map**

In `SPEC.md`, find the module-map section. Replace the `handlers/` entries with
the new homes. Specifically, remove any `lib/tore/handlers/*_handler.ex` listing
and ensure the map reflects: `planning.ex`, `shop.ex`, `insights.ex` as context
modules, and that Recipes/Costs/Pantry/Deals/Prep now own the former handler
functions. (Match the surrounding format of the existing map; if the map does not
enumerate handler files individually, only remove the `handlers/` directory line.)

- [ ] **Step 4: Append the CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add a new section after the most
recent one:

```markdown
### All-handlers Tiger-Style rename

The `Tore.Handlers.*Handler` family is retired — "handler" is filler; each
module now names what it does.

- Folded the context-backed handlers into their existing context modules:
  `RecipeHandler` → `Tore.Recipes`, `CostsHandler` → `Tore.Costs`,
  `PantryHandler` → `Tore.Pantry`, `DealsHandler` → `Tore.Deals`,
  `PrepHandler` → `Tore.Prep`. Their LLM/scraping/orchestration functions now
  sit beside the persistence and query functions they already called.
- `PlanningHandler` → `Tore.Planning` and `GroceriesHandler` → `Tore.Shop`:
  the bare context module is the imperative shell over the pure aggregate
  submodules (`*.Decider/.Events/.State/.Commands`), matching the `Tore.Recipes`
  pattern. The aggregate and its operations now share one name.
- `InsightsHandler` → `Tore.Insights` (no sibling context existed).
- `Tore.Costs.log_dining_out/1` is kept (live callers) with the folded `/2`
  beside it. `lib/tore/handlers/` is deleted. Pure rename — suite unchanged at
  483/0.
```

- [ ] **Step 5: Verify the full suite one final time**

Run: `mix test`
Expected: **483 tests, 0 failures.**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 6: Commit**

```bash
jj commit -m "refactor(handlers): delete Tore.Handlers namespace; SPEC + CHANGELOG

All eight handlers are renamed/folded; lib/tore/handlers/ removed. Grep proves
no Tore.Handlers or *Handler references remain. Pure rename, 483/0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final review

After Task 9, dispatch a final code reviewer over the whole change
(`jj log -r 'master..@'` to see the nine commits), then use
`superpowers:finishing-a-development-branch` to publish to master (push directly;
no workspace per project convention).
