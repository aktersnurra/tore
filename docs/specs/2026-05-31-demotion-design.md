# Demotion Design

> Spec for the demotion track of the AI-native rewrite. Covers the
> Family→Household rename, the pantry/costs route demotion, and the
> deletion of the HomeNote stub. Authoritative requirements; the
> implementation plan derives from this.

## Status

- **Date:** 2026-05-31
- **Supersedes:** SPEC.md §"Auth and Multi-Tenancy" (which currently makes Family canonical) and §"Removed in Rewrite" (which lists Household as deleted). Those sections must flip when this spec lands.
- **Related:** SPEC.md §"Removed in Rewrite" rows for pantry CRUD UI, /pantry, /costs, and the hardcoded home-note string.

## Goal

Three independent housekeeping tracks bundled into one work session because they all serve the same intent: reduce surface area before the next round of feature work.

1. **Naming rename.** Restore `Tore.Household` as the canonical context. Delete `Tore.Family.*`. Rename DB tables `families` → `households`, `family_insights` → `household_insights`. Rename FK column `family_id` → `household_id` on `users` and `household_preferences`.
2. **Route demotion.** Remove `/pantry` and `/costs` from main nav. Move both under the `/settings/...` route scope. Strip `pantry_live.ex` from 445 lines of full CRUD to ~80 lines of read-only list + per-item remove. Move `cost_live.ex` verbatim — no functional change.
3. **HomeNote deletion.** Remove the daily Quantum job `Tore.Jobs.HomeNote`, the `CounterNotes.build_home_note/1` function, and the corresponding cron entry. Accepts a temporary gap in the Home surface's counter-note list until AmbientScan ships in a later plan.

## Philosophy

The previous rewrite chose "Family" as the canonical name and demoted "Household" to a deprecated shim. That choice was hasty. "Household" is the more natural word for what this context represents — the shared kitchen state, prefs, and members — and the user prefers it on reflection. Reverting is more work than staying the course, but the codebase will end clearer.

The pantry and costs demotion is the SPEC's "more wrong about your kitchen" axis made concrete: pantry CRUD invites maintenance drift; cost dashboards encourage weekly auditing. Both move under Settings where occasional access is fine and daily access is impossible.

The HomeNote stub was always a placeholder. Removing it now removes a code path that lies to the user.

## §1 — Family→Household Rename

### Database

A single Ecto migration runs all three table/column renames. SQLite supports `ALTER TABLE RENAME TO` and `ALTER TABLE RENAME COLUMN` (3.25+). Indexes are auto-renamed by `ALTER TABLE`. No data movement.

```
ALTER TABLE families                 RENAME TO households;
ALTER TABLE family_insights          RENAME TO household_insights;
ALTER TABLE users                    RENAME COLUMN family_id TO household_id;
ALTER TABLE household_preferences    RENAME COLUMN family_id TO household_id;
```

The migration is reversible — the `down` clause renames back. Test DB rebuilds from scratch via `mix ecto.reset` and so does not need data preservation.

### Modules

| From | To |
|---|---|
| `Tore.Family` (`lib/tore/family.ex`) | `Tore.Household` (`lib/tore/household.ex`) |
| `Tore.Family.FamilySchema` (`lib/tore/family/family_schema.ex`) | `Tore.Household.HouseholdSchema` (`lib/tore/household/household_schema.ex`) |
| `Tore.Family.FamilyInsight` (`lib/tore/family/family_insight.ex`) | `Tore.Household.HouseholdInsight` (`lib/tore/household/household_insight.ex`) |
| `Tore.Household` (the 14-line shim) | **Deleted.** Its delegates become the real implementations on the new `Tore.Household` context. |

`Tore.Household.Preferences` (already correctly namespaced) stays. Its `belongs_to :family` association becomes `belongs_to :household`, and its `:family_id` column becomes `:household_id` via the migration above.

### Call sites

All of these change their alias and any direct module references:

- `lib/tore/family.ex` → file moves to `lib/tore/household.ex`
- `lib/tore/chat/system_prompt.ex` (any `Tore.Family.*` calls)
- `lib/tore/chat/week_context.ex` (verify via grep)
- `lib/tore/handlers/insights_handler.ex`
- `lib/tore_web/live/planner_live.ex` (two `Tore.Family.get_preferences` calls)
- `lib/tore_web/live/prep_live.ex`
- `lib/tore_web/live/settings_live.ex` (the `forget_insight` handler)
- All tests that reference `Tore.Family*`

### SPEC.md updates

- §"Auth and Multi-Tenancy": replace every "family" with "household".
- §"Removed in Rewrite": delete the row listing Household as deprecated. Add a row noting `Tore.Family` was deleted in favour of Household.
- §"Module Map (target state)": replace `family.ex`, `family/family_schema.ex`, `family/family_insight.ex` with their Household equivalents.
- §"Status": note the reversal date.

### Validation

- `mix compile --warnings-as-errors` is clean.
- `mix test` runs to the same failure floor as today (5–7 pre-existing in `Groceries*` + flaky SQLite race). No new failures.
- A single commit lands the entire rename. Partial = broken build.

### Hard rules

- No backwards-compatibility shims. Do not leave `Tore.Family` as a delegate to `Tore.Household`. The point of the demotion is reduction.
- DB column renames must use `ALTER TABLE RENAME COLUMN`, not drop-and-add. Drop would lose data even in dev.
- The migration is committed in the same commit as the code rename.

## §2 — Route + Nav + Pantry/Costs Demotion

### Routes

`lib/tore_web/router.ex` changes:

```elixir
# REMOVED from the main :authenticated scope:
live "/pantry", PantryLive
live "/costs", CostLive

# ADDED to a new /settings scope:
scope "/settings", ToreWeb do
  pipe_through [:browser, :require_auth]

  live_session :settings,
    on_mount: [{ToreWeb.Live.Auth, :require_authenticated}] do
    live "/pantry", PantryLive
    live "/costs", CostLive
  end
end
```

Direct visits to `/pantry` and `/costs` return 404 — Phoenix's default no-route response. No redirect.

### Nav layout

`lib/tore_web/components/layouts.ex:16-18` drops two entries:

```elixir
# REMOVED:
{"/pantry", gettext("Pantry"), "nav-pantry"},
{"/costs", gettext("Costs"), "nav-costs"},
```

Remaining nav: Home, Plan, Recipes, Groceries, Prep, Deals, Settings.

### `pantry_live.ex` strip

The file shrinks from 445 lines to ~80 lines. **Kept:**

- `mount/3` — fetches `Tore.Pantry.list_inventory_grouped/0`.
- `handle_event("remove_item", %{"id" => id}, socket)` — calls `Tore.Pantry.remove_item/1`, re-fetches the list.
- `render/1` — a list grouped by category, each row showing item name, quantity/unit, and a small "remove" button.

**Deleted:**

- The `allow_upload :pantry_photo` clause and any `handle_progress/3` callback.
- `handle_event("add_item", ...)`, `handle_event("set_category", ...)`, `handle_event("set_preview_category", ...)`, `handle_event("discard_scan", ...)`.
- Photo scan preview state (`scanning`, `preview`, `scan_error`, `new_category` assigns).
- The private helpers `parse_decimal/1`, `parse_date/1`, `nilify/1` and any others used only by deleted handlers.
- The add-item form, the photo-scan UI, the preview cards, the category management UI.

The page header text changes from "Pantry" to "Approximate inventory" (Swedish translation also updated) — a small visual cue that this view is inferred state, not authoritative.

### `cost_live.ex` move

No code changes. The module mounts under the new settings scope. The route path changes from `/costs` to `/settings/costs`. Any existing test asserting the path gets its path updated.

### Settings page

`settings_live.ex` gains two `<.link>` rows pointing to `/settings/pantry` and `/settings/costs`. Suggested labels: "Pantry" and "Spending". Placement: a new "Other" or "More" section below the existing Kitchen Memory and user-management blocks. No other Settings changes.

### Tests

- `live(conn, "/pantry")` returns a 404 (or the test framework's equivalent for "no route"). Same for `/costs`.
- `live(conn, "/settings/pantry")` mounts successfully.
- `live(conn, "/settings/pantry")` with a fixture item supports `phx-click="remove_item"` and the row disappears from the next render.
- Pre-existing pantry tests that asserted add/scan/category get **deleted** with the handlers — not adapted.
- Pre-existing cost test (if any) updates its path string.
- Pre-existing planner/home/cooking/recipe tests do NOT reference `/pantry` or `/costs` directly — verify via grep.

### Hard rules

- No redirect from `/pantry` to `/settings/pantry`. 404 is correct — the route is gone.
- Pantry strip is opportunistic: only delete what becomes unreachable. Do not refactor adjacent code in the file.
- Costs page is moved verbatim. Any rebuild of cost analytics is a separate future plan.

## §3 — HomeNote Stub Deletion

### Deletions

| File | Change |
|---|---|
| `config/config.exs:60` | Delete the line `{"0 6 * * *", {Tore.Jobs.HomeNote, :run, []}},` from the `Tore.Scheduler` jobs list. |
| `lib/tore/jobs/home_note.ex` | Delete the entire file (~3 lines). |
| `lib/tore/counter_notes.ex` | Delete `build_home_note/1` (lines 43-71). |
| Any test referencing `build_home_note` | Delete the test entirely (not adapt). |

### Survivors

`CounterNotes.list_for_surface/1`, `create/1`, `accept/1`, `ignore/1`, `expire_stale/0` stay. The `CounterNote` schema and table stay. The Home/Plan/Kiosk surfaces continue to render counter notes from `list_for_surface/1` — they just return `[]` until AmbientScan starts writing notes in a future plan.

### HomeLive

No changes needed. `home_live.ex:45` already uses `:if={@home_notes != []}` to guard the render — an empty list is already handled.

### Hard rules

- No replacement stub. The HomeNote function does not become a `:ok` no-op; it is removed entirely.
- The Quantum schedule entry is removed in the same commit as the function deletion.

## Cross-section Testing Strategy

Each section ends with a commit and a green `mix test` run. The current pre-existing failure count (5–7 in `Groceries*` and the SQLite race in `FamilyTest`, which becomes `HouseholdTest` after §1) is the floor — anything new is a regression.

- **§1** is largely compile-time validation: after renames, either the suite still passes or specific tests show the missed call sites. New tests: none.
- **§2** adds three LiveView tests (404 for old routes, mount + remove for the new pantry, optional mount for the new costs path).
- **§3** is verified by `mix test` still passing plus `grep build_home_note` finding zero remaining references.

No new LLM tests. No new Mox setups. No new migrations beyond §1's single rename.

## Manual Smoke

After all three sections land, in dev:

1. Log in. Confirm the main nav shows only Home, Plan, Recipes, Groceries, Prep, Deals, Settings. No Pantry. No Costs.
2. Navigate to `/pantry` directly. Expect 404 (or whatever Phoenix's default-no-route page is).
3. Navigate to `/settings`. Confirm new links for "Pantry" and "Spending".
4. Click Pantry → see read-only inventory list, grouped by category. Click "remove" on an item — it disappears.
5. Click Spending → see the full cost dashboard verbatim.
6. Open `iex -S mix`, run `Tore.Household.get_preferences()` — confirm it returns prefs from the `household_preferences` table.

## Out of Scope

- Rebuilding cost analytics. (Future plan.)
- `AmbientScan` and its four trigger rules. (Future plan.)
- Receipt → pantry closed loop. (Future plan: `receipt_to_pantry`.)
- Grocery checkoff → pantry closed loop. (Future plan.)
- Adding `Pantry.last_seen_at` field. (Future plan: pantry-as-inference.)
- Updating `SystemPrompt.build/0` to frame pantry as approximate. (Future plan.)
- Fridge photo → suggestions completion. (Future plan.)

## Success Criteria

The demotion is done when:

1. `mix compile --warnings-as-errors` is clean.
2. `mix test` passes with the same failure floor as before this work started.
3. No file in the repo contains `Tore.Family` as a module path (verified by `grep -rn "Tore.Family" lib/ test/`).
4. No file in the repo contains `family_id` outside of the migration that renames it (verified by `grep -rn family_id lib/ test/`).
5. The main nav layout contains no `/pantry` or `/costs` entry.
6. `live(conn, "/pantry")` returns a no-route response in tests.
7. `lib/tore/jobs/home_note.ex` does not exist.
8. `CounterNotes.build_home_note/1` is undefined.
9. `Tore.Scheduler` jobs list contains no entry referencing `Tore.Jobs.HomeNote`.
10. SPEC.md's §"Auth and Multi-Tenancy" and §"Removed in Rewrite" reflect the inverted naming convention.
11. The dev server runs and the manual smoke checklist above passes.
