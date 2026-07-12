# Anticipation Layer Implementation Plan (plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Predictions replace generic affordances — a daily/debounced ambient scan materializes actionable CounterNotes with a `proposed_run` payload, surfaces render them instantly (hero card action, shop placeholder, tray half state, slot sheet), one tap dispatches; long-press raises object sheets on the tonight card and grocery rows; a deterministic `resolve_slot` closes the NL slot-reference gap.

**Architecture:** The scan is a headless Tier-0 harness run (`:ambient_scan_run`) modeled 1:1 on `:kitchen_memory_synthesis_run`: capsules → one `Tore.LLM.text` call → pure `CounterNoteVerifier` → materialized `counter_notes` rows. Surfaces never call the LLM on load (Rule 2); they render whatever notes exist and fall back to their generic affordances. A note's `proposed_run` is either a deterministic direct apply (`add_item` — code disposes, no LLM) or a `planner_command` dispatched through the existing `:planner_command_run` path with Plan 2's `scoped_slot` machinery. Dismissal (`ignore`) is fed back into the next scan prompt as "do not re-propose" (Rule 3). `resolve_slot` is pure code, no LLM: slot keys are a closed domain (`{day}_dinner`), so the resolver returns structural keys + labels, not ref handles — consistent with Plan 2's locked decision that slots stay structural.

**Tech Stack:** Phoenix LiveView + HEEx, Ecto/SQLite, Quantum cron, Phoenix.PubSub, Mox (`Tore.MockLLM`), gettext (sv default in tests), one small vanilla-JS LiveView hook.

**Design source:** `docs/specs/2026-07-04-surface-consolidation-design.md` §3 (rules 1–3), §4 (tray half state), §4.1 (object sheets), §10 amendments #3/#4, §12 steps 6–7.

---

## Execution conventions (controller + subagents)

- **Subagents NEVER run `git` or `jj`. No commits by subagents.** All task changes accumulate in one working copy; the controller makes a single commit at the end (Task 11).
- `mix` may fail in the sandbox with `failed to acquire filesystem lock using TCP, reason: :eperm` — rerun the identical command with sandbox bypass; it is environmental.
- Tests run with Swedish as default gettext locale: every new user-facing gettext msgid needs an sv translation (`mix gettext.extract --merge`, then fill `priv/gettext/sv/LC_MESSAGES/default.po`).
- Known flake: sporadic `Database busy` (Exqlite) under full-suite parallel load — rerun the failing file in isolation to confirm; do not chase.
- LLM prompts are English; the household locale is threaded as a parameter for output language (never bake Swedish into prompts).

## Ground truth (verified 2026-07-18 — trust this over the design doc's optimism)

- `lib/tore/counter_notes/counter_note.ex`: fields `surface, kind, title, body, commands (dead — never read/written), confidence, status, expires_at`; `@valid_surfaces ~w(home week groceries pantry deals)`; `@valid_kinds ~w(deal_opportunity plan_repair pantry_assumption habit_pattern)`; statuses `pending accepted ignored expired`. **No `proposed_run`, no dispatch wiring, no verifier, nothing creates notes in production.**
- `lib/tore/counter_notes.ex`: `list_for_surface/1` (pending, non-expired, limit 3), `create/1`, `accept/1`, `ignore/1`, `expire_stale/0` (**not on cron**).
- **No ambient scan exists.** Template: `lib/tore/harness/kitchen_memory_synthesis.ex` (`synthesise_weekly/0` builds ctx and calls `Orchestrator.dispatch(:kitchen_memory_synthesis_run, ctx)`; orchestrator clause at `orchestrator.ex:144`).
- Capsules in `lib/tore/harness/capsules/`: `WeekPlanCapsule`, `PantryBeliefsCapsule`, `ActiveInsightsCapsule`, `RecentHistoryCapsule`, `RecipeAffinityCapsule`, `HouseholdPreferencesCapsule`; composed via `Tore.Harness.Capsules.compose(capsule_modules, ctx)` → String.
- Scheduler: Quantum (`Tore.Scheduler`), jobs in `config/config.exs` lines ~61–72.
- SpendGuard: `lib/tore/spend_guard.ex` — `allow?(feature)`, `log_usage(feature, usage)`, `@feature_defaults %{suggest_recipe: {6_000, 3}}`.
- PubSub topics: `"plan"` (`lib/tore/planning.ex` `@topic`, broadcasts `{:events, events}`), `"shop_list"` (`lib/tore/shop.ex` `@topic`, same shape).
- `home_live.ex`: hero card lines ~61–103; buttons "Start cooking" (link → /recipes) and `<button phx-click="something_else">`; `today_key` assign = `"#{day}_dinner"`; `home_notes = CounterNotes.list_for_surface("home")` rendered as plain divs lines ~42–49.
- `shop_live.ex`: `add_item` form lines ~181–209 (placeholder `gettext("Add item…")`, handler line 57 → `Shop.add_item/5`); `item_row/1` component lines ~217–267 (the `<li>` is the long-press target); no CounterNotes usage.
- `capture_live.ex`: pure capture form (messages/input/photos → `Tore.Capture.Router.route(text, images, ctx, history)`); no predictions; `return_to` from `ToreWeb.SafeReturn.path/2`.
- `planner_live.ex`: `slot_action` assign holds the open slot; `slot_command` handler lines ~261–292 dispatches `:planner_command_run` with `scoped_slot` (Plan 2); `counter_notes: list_for_surface("week")` rendered with Accept/Ignore at ~495–523 (handlers `accept_note`/`ignore_note` ~211–220).
- `orchestrator.ex`: `dispatch(:planner_command_run, ctx)` at line ~34 reads `scoped_slot`, seeds `handles:` via `scoped_handles/1` (~864), prefixes user text via `scoped_user_text/2` (~68); `humanize_slot/1` at ~75.
- Handles (Plan 2): `Handles.slot(slot_key, label)`, `Handles.recipe/4`, `register/2`, `fetch/2`. Resolvers: only `resolve_recipe/1` (`@accept 0.7, @floor 0.45, @clear_gap 0.1`).
- Planner tools: `assign_recipe, swap_recipe, skip_meal, mark_leftover, set_servings, remove_recipe, ask_user, search_recipes, resolve_recipe, pantry_snapshot, active_deals`. Action tools take `slot_key` strings (by design). Tool run contract: `fn args, ctx, plan -> {:ok, result, events, plan}`; read-tool results may carry `__handles__`.
- JS: `assets/js/app.js` only; no hooks anywhere; colocated-hooks import exists but unused. Long-press is fully greenfield.
- Test idioms: `test/tore/harness/weekly_planning_run_test.exs` for Mox-driven orchestrator runs; `test/tore/counter_notes_test.exs` for the context; `Recipes.create` fires an async image-prompt task — stub `Tore.MockLLM.text` globally in any test that creates recipes (idiom in `test/tore/harness/resolvers_test.exs:16`).

## Scope decisions (locked)

1. **`proposed_run` is a map column** on `counter_notes` with a `"kind"` discriminator:
   - `%{"kind" => "planner_command", "command" => String, "scoped_slot" => String | nil}` → dispatched through `:planner_command_run`, `started_by: "counter_note_followup"`.
   - `%{"kind" => "add_item", "name" => String, "quantity" => String | nil, "unit" => String | nil}` → applied directly via `Shop.add_item` — no LLM run for a deterministic add.
   - `nil` → informational note (today's behavior).
   The dead `commands` string column is left untouched (removing it is cleanup outside this plan's need).
2. **New kinds:** `swap_suggestion`, `freezer_fallback`, `missing_ingredient`, `usual_item_missing` (design §10.3). Scan notes use only these four; "replace previous scan output" is scoped by kind ∈ these four.
3. **Scan cadence:** Quantum daily 05:00 + a PubSub debouncer (5-min quiet period after `"plan"`/`"shop_list"` events). SpendGuard feature `:ambient_scan` `{8_000, 600}` — the 600 s cooldown is the storm backstop. `expire_stale` joins cron at 04:30.
4. **Rule 1 wiring:** home hero's "Something else" button label is replaced by the top actionable home note; Shop's add-field placeholder becomes the predicted item and an **empty submit accepts it** (typed text always wins); tray half state lists the origin surface's actionable notes above the input; slot sheet lists week notes scoped to that slot. No new persistent elements.
5. **Max-one on the hero card**; the tray/slot-sheet lists keep `list_for_surface`'s limit 3.
6. **Long-press:** one plain `app.js` hook (`LongPress`, 500 ms) — no colocated hooks (none exist in the codebase; don't introduce a second idiom). Tonight card long-press → home slot sheet scoped to `today_key` (reuses Plan 2 `scoped_slot` dispatch verbatim). Grocery row long-press → item sheet whose input routes through `Capture.Router` with a text-prefix referent. **Deferred:** `ResolvedGroceryItem` handles (no grocery action tools exist to consume them — text prefix is the honest v1), item-scoped predictions on the grocery sheet, cooking-view substitution hints (design §11 leaves cooking unchanged), `resolve_grocery_item`/`resolve_pantry_item`.
7. **`resolve_slot` returns structural slot keys, not handles.** The slot domain is closed (`mon..sun` × `dinner`) — the model cannot invent a usable key that the tools' existing validation wouldn't reject, so ref-token indirection buys nothing. Pure resolver (day words + "tonight/today/tomorrow" + Jaro over assigned recipe titles), exposed as a read tool. The model normalizes user language to English references (tool description says so); the resolver stays locale-free.

---

### Task 1: `proposed_run` column + new kinds + context API

**Files:**

- Create: `priv/repo/migrations/20260718000001_add_proposed_run_to_counter_notes.exs`
- Modify: `lib/tore/counter_notes/counter_note.ex`
- Modify: `lib/tore/counter_notes.ex`
- Test: `test/tore/counter_notes_test.exs` (extend)

- [ ] **Step 1: Write the failing tests** (append to the existing describe blocks in `counter_notes_test.exs`, matching its style):

```elixir
test "create accepts a proposed_run map and the new scan kinds" do
  {:ok, note} =
    CounterNotes.create(%{
      surface: "home",
      kind: "swap_suggestion",
      title: "Swap with Thursday?",
      body: "Tuesdays go quick — Thursday's dish is faster.",
      proposed_run: %{
        "kind" => "planner_command",
        "command" => "swap tuesday's dinner with thursday's",
        "scoped_slot" => "tue_dinner"
      }
    })

  assert note.proposed_run["kind"] == "planner_command"
end

test "create rejects an unknown kind" do
  assert {:error, changeset} =
           CounterNotes.create(%{surface: "home", kind: "nonsense", title: "t", body: "b"})

  assert %{kind: _} = errors_on(changeset)
end

test "replace_scan_notes expires previous pending scan notes and inserts the new set" do
  {:ok, old} =
    CounterNotes.create(%{surface: "home", kind: "swap_suggestion", title: "old", body: "b"})

  {:ok, keeper} =
    CounterNotes.create(%{surface: "home", kind: "habit_pattern", title: "manual", body: "b"})

  {:ok, [new_note]} =
    CounterNotes.replace_scan_notes([
      %{surface: "groceries", kind: "usual_item_missing", title: "Oat milk?", body: "You always buy it.",
        proposed_run: %{"kind" => "add_item", "name" => "oat milk", "quantity" => nil, "unit" => nil}}
    ])

  assert Repo.get!(CounterNote, old.id).status == "expired"
  assert Repo.get!(CounterNote, keeper.id).status == "pending"
  assert new_note.kind == "usual_item_missing"
end

test "recently_ignored returns kind and title of recently ignored notes" do
  {:ok, note} =
    CounterNotes.create(%{surface: "home", kind: "freezer_fallback", title: "Frozen bolognese?", body: "b"})

  {:ok, _} = CounterNotes.ignore(note.id)

  assert [%{kind: "freezer_fallback", title: "Frozen bolognese?"}] = CounterNotes.recently_ignored(14)
end
```

(Check the file head for existing aliases — it already aliases `CounterNotes`; add `alias Tore.CounterNotes.CounterNote` and `Tore.Repo` if missing.)

- [ ] **Step 2: Run** `mix test test/tore/counter_notes_test.exs` — new tests FAIL (unknown field/kind, undefined functions).

- [ ] **Step 3: Implement.**

Migration:

```elixir
defmodule Tore.Repo.Migrations.AddProposedRunToCounterNotes do
  use Ecto.Migration

  def change do
    alter table(:counter_notes) do
      add :proposed_run, :map
    end
  end
end
```

Schema (`counter_note.ex`): add `field :proposed_run, :map` next to the existing fields; extend the catalog:

```elixir
@valid_kinds ~w(deal_opportunity plan_repair pantry_assumption habit_pattern
                swap_suggestion freezer_fallback missing_ingredient usual_item_missing)
```

Add `:proposed_run` to the `cast` list in `changeset/2`. Everything else unchanged.

Context (`counter_notes.ex`) — add:

```elixir
@scan_kinds ~w(swap_suggestion freezer_fallback missing_ingredient usual_item_missing)

@doc "One scan owns the scan-kind notes: expire the previous pending batch, insert the new one."
def replace_scan_notes(attrs_list) do
  Repo.transaction(fn ->
    from(n in CounterNote, where: n.status == "pending" and n.kind in @scan_kinds)
    |> Repo.update_all(set: [status: "expired"])

    Enum.map(attrs_list, fn attrs ->
      case create(attrs) do
        {:ok, note} -> note
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end)
end

@doc "Dismissal is signal: what the household recently swiped away, for the next scan prompt."
def recently_ignored(days) do
  since = DateTime.add(DateTime.utc_now(), -days, :day)

  from(n in CounterNote,
    where: n.status == "ignored" and n.inserted_at >= ^since,
    select: %{kind: n.kind, title: n.title}
  )
  |> Repo.all()
end
```

(Match the module's existing import/alias style — it already imports `Ecto.Query` and aliases `Repo`/`CounterNote`; verify before adding duplicates. SQLite via Ecto stores the map as JSON; string keys round-trip.)

- [ ] **Step 4: Run** `mix ecto.migrate`, then `mix test test/tore/counter_notes_test.exs` — all green.

---

### Task 2: `CounterNoteVerifier` (pure)

**Files:**

- Create: `lib/tore/harness/verifier/counter_note_verifier.ex`
- Test: `test/tore/harness/verifier/counter_note_verifier_test.exs`

Read `lib/tore/harness/verifier/memory_verifier.ex` first — mirror its module shape, naming, and return convention exactly (pure, `:ok | {:fail, code}`-style; adopt whatever exact failure tuple shape it uses, including a repair hint if it carries one).

- [ ] **Step 1: Write the failing tests:**

```elixir
defmodule Tore.Harness.Verifier.CounterNoteVerifierTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.Verifier.CounterNoteVerifier, as: V

  @valid %{
    "surface" => "home",
    "kind" => "swap_suggestion",
    "title" => "Swap with Thursday?",
    "body" => "Tuesdays go quick.",
    "confidence" => "medium",
    "scoped_slot" => "tue_dinner",
    "command" => "swap tuesday's dinner with thursday's"
  }
  @slot_keys MapSet.new(~w(mon_dinner tue_dinner wed_dinner thu_dinner fri_dinner sat_dinner sun_dinner))

  test "a valid proposal passes" do
    assert :ok = V.verify(@valid, @slot_keys)
  end

  test "unknown kind, unknown surface, blank title fail" do
    assert {:fail, _} = V.verify(%{@valid | "kind" => "prophecy"}, @slot_keys)
    assert {:fail, _} = V.verify(%{@valid | "surface" => "tv"}, @slot_keys)
    assert {:fail, _} = V.verify(%{@valid | "title" => "  "}, @slot_keys)
  end

  test "a scoped_slot outside the week's slot domain fails" do
    assert {:fail, _} = V.verify(%{@valid | "scoped_slot" => "mon_breakfast"}, @slot_keys)
  end

  test "swap_suggestion without a scoped_slot fails" do
    assert {:fail, _} = V.verify(Map.put(@valid, "scoped_slot", nil), @slot_keys)
  end

  test "informational note (no command) passes; empty-string command fails" do
    ok = @valid |> Map.put("command", nil) |> Map.put("kind", "missing_ingredient")
    assert :ok = V.verify(ok, @slot_keys)
    assert {:fail, _} = V.verify(%{@valid | "command" => ""}, @slot_keys)
  end

  test "usual_item_missing with an item passes; without fails" do
    item = %{
      "surface" => "groceries",
      "kind" => "usual_item_missing",
      "title" => "Oat milk?",
      "body" => "You always buy it and it's not on the list.",
      "confidence" => "high",
      "item" => %{"name" => "oat milk", "quantity" => nil, "unit" => nil}
    }

    assert :ok = V.verify(item, @slot_keys)
    assert {:fail, _} = V.verify(Map.delete(item, "item"), @slot_keys)
  end
end
```

- [ ] **Step 2: Run** `mix test test/tore/harness/verifier/counter_note_verifier_test.exs` — FAIL (module undefined).

- [ ] **Step 3: Implement.** Rules (pure function `verify(proposal_map, slot_keys_mapset)`):

- `surface` ∈ `~w(home week groceries)`; `kind` ∈ the four scan kinds.
- `title` and `body` present, non-blank after trim; `title` ≤ 80 chars, `body` ≤ 240 chars (LLM prompts request less; verifier enforces).
- `confidence` nil or ∈ `~w(low medium high)`.
- `scoped_slot` nil or a member of the given slot-key set. `swap_suggestion` and `freezer_fallback` require `scoped_slot`.
- `command` nil or non-blank string ≤ 300 chars.
- `usual_item_missing` requires `"item"` map with non-blank `"name"`; other kinds must not carry `"item"` (either–or with `command` is fine, both nil = informational).

Return `:ok` or the failure shape mirrored from `memory_verifier.ex`, with a distinct code per rule (e.g. `:unknown_kind`, `:unknown_surface`, `:blank_title`, `:invalid_slot`, `:missing_scoped_slot`, `:blank_command`, `:missing_item`).

- [ ] **Step 4: Run the file** — green.

---

### Task 3: Ambient scan run (`Tore.Harness.AmbientScan` + orchestrator + cron + SpendGuard)

**Files:**

- Create: `lib/tore/harness/ambient_scan.ex`
- Modify: `lib/tore/harness/orchestrator.ex` (new `dispatch(:ambient_scan_run, ctx)` clause)
- Modify: `lib/tore/spend_guard.ex` (`@feature_defaults` gains `ambient_scan: {8_000, 600}`)
- Modify: `config/config.exs` (two new Quantum jobs)
- Test: `test/tore/harness/ambient_scan_run_test.exs`

Read fully before editing: `lib/tore/harness/kitchen_memory_synthesis.ex` AND the orchestrator's `dispatch(:kitchen_memory_synthesis_run, ctx)` clause (~line 144) — the new run mirrors both structurally (Run open → gathering_context → proposing → verifying → applied; `ObserveModelUsage`; `started_by: "system"`; same surface value the synthesis run uses). Also read how that module builds ctx (`household_id`, `user_id: nil`, `plan_stream_id`, `week_start`) — `AmbientScan.scan/0` builds ctx the same way.

**Module design** (`Tore.Harness.AmbientScan`):

```elixir
@capsules [
  Tore.Harness.Capsules.WeekPlanCapsule,
  Tore.Harness.Capsules.PantryBeliefsCapsule,
  Tore.Harness.Capsules.ActiveInsightsCapsule,
  Tore.Harness.Capsules.RecentHistoryCapsule
]

def scan(opts \\ []) do
  with :ok <- Tore.SpendGuard.allow?(:ambient_scan) do
    ctx = build_ctx()          # mirror KitchenMemorySynthesis.synthesise_weekly/0's ctx exactly
    Tore.Harness.Orchestrator.dispatch(:ambient_scan_run, ctx)
  end
end
```

The orchestrator clause does the work (mirroring the synthesis clause's Run choreography):

1. Context = `Capsules.compose(@capsules, ctx)` + two appended sections built by `AmbientScan`:
   - current shopping list, serialized with the same loader `shop_live.ex` uses in mount (read that file for the function; render as `"- name (qty unit) [section]"` lines);
   - recently dismissed: `CounterNotes.recently_ignored(14)` rendered as `"- kind: title"` lines under the heading `"Recently dismissed by the household — do NOT re-propose these:"`.
2. One `Tore.LLM.text(system_prompt, context, [])` call. System prompt (English; thread locale the same way `kitchen_memory_synthesis.ex` does — read it; if it doesn't thread locale, fetch the household locale the way `Tore.Pantry.canonicalise/2` callers do and add one line `"Write title and body in #{locale}."`):

```
You are the ambient scanner for a single-household meal planner. From the
week plan, pantry beliefs, insights, recent history, and the current
shopping list, predict at most 3 interactions the household is about to
need — one per surface at most.

Return ONLY JSON:
{"notes": [{"surface": "home|week|groceries",
            "kind": "swap_suggestion|freezer_fallback|missing_ingredient|usual_item_missing",
            "title": "...", "body": "...",
            "confidence": "low|medium|high",
            "scoped_slot": "tue_dinner" | null,
            "command": "imperative planner command" | null,
            "item": {"name": "...", "quantity": null, "unit": null} | null}]}

Rules: kinds — swap_suggestion (a hard slot on a busy day; scoped_slot and
command required), freezer_fallback (a frozen leftover fits a busy slot;
scoped_slot and command required), missing_ingredient (tonight's recipe
needs something pantry beliefs say is absent; command optional),
usual_item_missing (a habitual purchase absent from the list; item
required, no command). Title ≤ 8 words, body ≤ 2 short sentences,
matter-of-fact, no greetings. Predict nothing rather than something
generic. Never re-propose a dismissed note. Empty list is a fine answer.
```

3. Parse `{:ok, %{"notes" => notes}, usage}`; for each note run `CounterNoteVerifier.verify(note, slot_keys)` where `slot_keys` = the keys of the loaded week plan's `state.slots` (fall back to the static 7-key set when the plan is empty — build it from the same `~w[mon tue wed thu fri sat sun]` day list the LiveViews use). Drop failures; cap at one note per surface (first wins).
4. Map survivors to `CounterNotes.replace_scan_notes/1` attrs: `proposed_run` = `%{"kind" => "planner_command", "command" => command, "scoped_slot" => scoped_slot}` when `command` is non-nil, `%{"kind" => "add_item", "name" => item["name"], "quantity" => item["quantity"], "unit" => item["unit"]}` when `item` is non-nil, else `nil`; `expires_at` = next 05:00 UTC (`DateTime.utc_now() |> DateTime.add(1, :day) |> then(&%{&1 | hour: 5, minute: 0, second: 0, microsecond: {0, 0}})`).
5. Record usage on the Run (`ObserveModelUsage`, as the synthesis clause does), `SpendGuard.log_usage(:ambient_scan, usage)`, drive the Run to applied. A malformed LLM payload or all-notes-rejected is a normal empty outcome (replace with `[]` still expires stale scan notes), not a crash.

Cron (`config/config.exs`, append to the existing `jobs:` list):

```elixir
{"30 4 * * *", {Tore.CounterNotes, :expire_stale, []}},
{"0 5 * * *", {Tore.Harness.AmbientScan, :scan, []}},
```

SpendGuard: add `ambient_scan: {8_000, 600}` to `@feature_defaults`.

- [ ] **Step 1: Write the failing test** (`test/tore/harness/ambient_scan_run_test.exs`; mirror `weekly_planning_run_test.exs` setup — `DataCase, async: false`, `import Mox`, `setup :verify_on_exit!`, household/admin creation as that file does):

```elixir
test "scan materializes verified notes with proposed runs and expires the previous batch" do
  {:ok, stale} =
    Tore.CounterNotes.create(%{surface: "home", kind: "swap_suggestion", title: "stale", body: "b"})

  expect(Tore.MockLLM, :text, fn _system, context, _opts ->
    assert context =~ "Recently dismissed"

    {:ok,
     %{
       "notes" => [
         %{
           "surface" => "home", "kind" => "freezer_fallback",
           "title" => "Frozen bolognese tonight?", "body" => "Busy evening.",
           "confidence" => "medium", "scoped_slot" => "mon_dinner",
           "command" => "assign the frozen bolognese to monday", "item" => nil
         },
         %{
           "surface" => "groceries", "kind" => "usual_item_missing",
           "title" => "Oat milk?", "body" => "You always buy it.",
           "confidence" => "high", "scoped_slot" => nil, "command" => nil,
           "item" => %{"name" => "oat milk", "quantity" => nil, "unit" => nil}
         },
         %{
           "surface" => "home", "kind" => "prophecy",
           "title" => "bad", "body" => "b", "confidence" => "low",
           "scoped_slot" => nil, "command" => nil, "item" => nil
         }
       ]
     }, %{prompt_tokens: 10, completion_tokens: 10, cost_usd: Decimal.new(0)}}
  end)

  assert {:ok, _} = Tore.Harness.AmbientScan.scan()

  home = Tore.CounterNotes.list_for_surface("home")
  groceries = Tore.CounterNotes.list_for_surface("groceries")

  assert [%{kind: "freezer_fallback", proposed_run: %{"kind" => "planner_command"}}] = home
  assert [%{kind: "usual_item_missing", proposed_run: %{"kind" => "add_item", "name" => "oat milk"}}] = groceries
  assert Tore.Repo.get!(Tore.CounterNotes.CounterNote, stale.id).status == "expired"
end

test "a malformed LLM payload yields an empty batch, not a crash" do
  expect(Tore.MockLLM, :text, fn _s, _u, _o ->
    {:ok, %{"unexpected" => true}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  assert {:ok, _} = Tore.Harness.AmbientScan.scan()
  assert Tore.CounterNotes.list_for_surface("home") == []
end
```

(If SpendGuard's cooldown blocks the second test in the same process/window, check how existing SpendGuard tests reset state — read `test/tore/spend_guard_test.exs` if it exists and follow its idiom; otherwise the cooldown table is per-DB-sandbox and both tests pass independently. If dispatch requires an open plan stream, mirror however `weekly_planning_run_test.exs` seeds the week's plan.)

- [ ] **Step 2: Run the file** — FAIL (module undefined).
- [ ] **Step 3: Implement per the design above.**
- [ ] **Step 4: Run** `mix test test/tore/harness/ambient_scan_run_test.exs`, then `mix test test/tore/harness` — green.

---

### Task 4: Scan debouncer (re-trigger on plan/shop mutation)

**Files:**

- Create: `lib/tore/harness/ambient_scan/debouncer.ex`
- Modify: `lib/tore/application.ex` (add child)
- Modify: `config/config.exs` + `config/test.exs` (quiet-period override)
- Test: `test/tore/harness/ambient_scan_debouncer_test.exs`

- [ ] **Step 1: Write the failing test:**

```elixir
defmodule Tore.Harness.AmbientScan.DebouncerTest do
  use ExUnit.Case, async: false

  alias Tore.Harness.AmbientScan.Debouncer

  test "coalesces bursts of mutations into one scan after the quiet period" do
    test_pid = self()

    {:ok, pid} =
      Debouncer.start_link(
        name: nil,
        quiet_ms: 30,
        scan_fun: fn -> send(test_pid, :scanned) end
      )

    send(pid, {:events, [:a]})
    send(pid, {:events, [:b]})
    send(pid, {:events, [:c]})

    refute_receive :scanned, 20
    assert_receive :scanned, 100
    refute_receive :scanned, 100
  end
end
```

- [ ] **Step 2: Run it** — FAIL.
- [ ] **Step 3: Implement:**

```elixir
defmodule Tore.Harness.AmbientScan.Debouncer do
  @moduledoc """
  Re-triggers the ambient scan after plan/shop mutations settle
  (design §10.4). Coalesces event bursts into one scan per quiet period;
  SpendGuard's :ambient_scan cooldown is the cost backstop.
  """
  use GenServer

  @topics ~w(plan shop_list)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    quiet_ms =
      Keyword.get(opts, :quiet_ms, Application.get_env(:tore, :ambient_scan_quiet_ms, :timer.minutes(5)))

    scan_fun = Keyword.get(opts, :scan_fun, fn -> Tore.Harness.AmbientScan.scan() end)

    if Keyword.get(opts, :subscribe?, false) do
      Enum.each(@topics, &Phoenix.PubSub.subscribe(Tore.PubSub, &1))
    end

    {:ok, %{quiet_ms: quiet_ms, scan_fun: scan_fun, timer: nil}}
  end

  @impl true
  def handle_info({:events, _}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :scan, state.quiet_ms)}}
  end

  def handle_info(:scan, state) do
    Task.start(state.scan_fun)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
```

Application child (after the scheduler, before the endpoint — read `application.ex` for list style): `{Tore.Harness.AmbientScan.Debouncer, subscribe?: true}`. In `config/test.exs`: `config :tore, :ambient_scan_quiet_ms, :timer.hours(24)` so app-level broadcasts in tests never fire a scan. Note the test above passes `subscribe?: false` implicitly (default) and drives messages directly — no PubSub races.

- [ ] **Step 4: Run the file, then** `mix test test/tore/harness` — green.

---

### Task 5: `follow_up/2` — one tap dispatches the proposed run

**Files:**

- Modify: `lib/tore/counter_notes.ex`
- Modify: `lib/tore/harness/orchestrator.ex` (`:planner_command_run` reads `started_by` from ctx)
- Test: `test/tore/counter_notes_test.exs` (extend)

Read first: the orchestrator's `:planner_command_run` clause (how the run input/`started_by` is built), `shop_live.ex`'s `add_item` handler (line ~57) for the exact `Shop.add_item/5` argument order, and `KitchenMemorySynthesis`'s ctx builder (for computing `plan_stream_id`/`week_start` for the current week).

- [ ] **Step 1: Write the failing tests** (in `counter_notes_test.exs`; this test creates no recipes, so no MockLLM stub needed for `add_item`; the planner-command test mocks the agent turn):

```elixir
describe "follow_up/2" do
  test "an add_item proposed_run adds the item directly and accepts the note" do
    {:ok, note} =
      CounterNotes.create(%{
        surface: "groceries", kind: "usual_item_missing", title: "Oat milk?", body: "b",
        proposed_run: %{"kind" => "add_item", "name" => "oat milk", "quantity" => nil, "unit" => nil}
      })

    assert {:ok, _} = CounterNotes.follow_up(note.id, %{household_id: household_id(), user_id: user_id()})
    assert Repo.get!(CounterNote, note.id).status == "accepted"
    # assert the item landed using the same list function shop_live uses (read its mount)
  end

  test "a planner_command proposed_run dispatches a scoped run with counter_note_followup provenance" do
    {:ok, note} =
      CounterNotes.create(%{
        surface: "home", kind: "freezer_fallback", title: "Frozen bolognese?", body: "b",
        proposed_run: %{"kind" => "planner_command", "command" => "skip monday", "scoped_slot" => "mon_dinner"}
      })

    expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
      user_msg = Enum.find(msgs, &(&1["role"] == "user" || &1[:role] == :user))
      content = user_msg["content"] || user_msg[:content]
      assert content =~ "mon_dinner"
      assert content =~ "skip monday"
      {:ok, {:message, "done"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    assert {:ok, _} = CounterNotes.follow_up(note.id, %{household_id: household_id(), user_id: user_id()})
    assert Repo.get!(CounterNote, note.id).status == "accepted"
  end

  test "a note without a proposed_run returns an error and stays pending" do
    {:ok, note} = CounterNotes.create(%{surface: "home", kind: "habit_pattern", title: "t", body: "b"})
    assert {:error, :no_proposed_run} = CounterNotes.follow_up(note.id, %{household_id: 1, user_id: 1})
    assert Repo.get!(CounterNote, note.id).status == "pending"
  end
end
```

(`household_id()`/`user_id()` — small private helpers using `Tore.Household.get_household!/0` and `Accounts.create_admin/1`, mirroring how `weekly_planning_run_test.exs` sets up actors. The message-shape access (`"role"` vs `:role`) — read one existing agent test asserting on `msgs` and copy its exact access pattern; `planner_live_test.exs`'s scoped-command test from Plan 2 does exactly this. This test file is `async: true` today — the Mox-using describe block may require `async: false`/`set_mox_from_context`; if so, split the follow_up describe into its own file `test/tore/counter_notes_follow_up_test.exs` with the `weekly_planning_run_test.exs` setup rather than de-asyncing the whole context file.)

- [ ] **Step 2: Run** — FAIL (undefined `follow_up/2`).
- [ ] **Step 3: Implement** in `counter_notes.ex`:

```elixir
@doc """
Accept the note and execute its proposed run. Deterministic proposals
(add_item) apply directly — code disposes; planner commands dispatch a
scoped run with counter_note_followup provenance.
"""
def follow_up(id, %{household_id: household_id, user_id: user_id}) do
  note = Repo.get!(CounterNote, id)

  case note.proposed_run do
    %{"kind" => "add_item", "name" => name} = pr ->
      {:ok, _} = accept(id)
      # exact arity/argument order from shop_live's add_item handler — read it
      Tore.Shop.add_item(name, pr["quantity"], pr["unit"], ...)

    %{"kind" => "planner_command", "command" => command} = pr ->
      {:ok, _} = accept(id)

      Tore.Harness.Orchestrator.dispatch(:planner_command_run, %{
        household_id: household_id,
        user_id: user_id,
        command: command,
        # plan_stream_id/week_start for the current week — same computation
        # as KitchenMemorySynthesis's ctx builder; extract a shared helper
        # there if one doesn't exist rather than duplicating the date math
        plan_stream_id: ...,
        week_start: ...,
        scoped_slot: pr["scoped_slot"],
        started_by: "counter_note_followup"
      })

    _ ->
      {:error, :no_proposed_run}
  end
end
```

The `...` are to be filled from the named files (exact `Shop.add_item` args; exact week/stream computation) — they are lookups, not design gaps. In `orchestrator.ex`'s `:planner_command_run` clause, change the hardcoded `started_by` to `Map.get(ctx, :started_by, "user")` (find where the Open command / run input sets it).

- [ ] **Step 4: Run the touched test files, then** `mix test test/tore/harness/orchestrator_test.exs` (started_by default must not regress) — green.

---

### Task 6: Rule-1 wiring — Today hero + slot-sheet predictions

**Files:**

- Modify: `lib/tore_web/live/home_live.ex`
- Modify: `lib/tore_web/live/planner_live.ex`
- Test: `test/tore_web/live/home_live_test.exs`, `test/tore_web/live/planner_live_test.exs` (extend both)

- [ ] **Step 1: Write the failing tests.**

`home_live_test.exs` (its setup already creates admin+session; creating notes needs no LLM):

```elixir
test "hero action is replaced by the top actionable prediction, and tapping follows it",
     %{conn: conn} do
  # seed a plan so tonight has a recipe — mirror however an existing test in this
  # file or planner_live_test.exs assigns a recipe to today's slot
  {:ok, note} =
    Tore.CounterNotes.create(%{
      surface: "home", kind: "swap_suggestion",
      title: "Swap with Thursday's gratäng", body: "Tuesdays go quick.",
      proposed_run: %{"kind" => "planner_command", "command" => "swap today with thursday",
                      "scoped_slot" => today_slot_key()}
    })

  {:ok, view, html} = live(conn, ~p"/")

  assert html =~ "Swap with Thursday&#39;s gratäng"
  refute html =~ "Something else"

  expect(Tore.MockLLM, :chat_with_tools, fn _s, _m, _t, _o ->
    {:ok, {:message, "done"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  view |> element(~s(button[phx-click="follow_note"])) |> render_click()
  assert Tore.Repo.get!(Tore.CounterNotes.CounterNote, note.id).status == "accepted"
end

test "hero keeps its generic action when no prediction exists", %{conn: conn} do
  # seed tonight's recipe as above
  {:ok, _view, html} = live(conn, ~p"/")
  assert html =~ "Something else"
end
```

(`today_slot_key/0` — compute `"#{day}_dinner"` from `Date.utc_today()` the way `home_live.ex:125` does; copy that expression into a test helper. The Mox expectation needs the file's Mox setup — add `import Mox` + `setup :set_mox_from_context` + the global `Tore.MockLLM.text` stub from `resolvers_test.exs:16` if recipe creation is involved. `follow_note` is dispatched in a `Task` from the LiveView — after `render_click`, await the status flip with a small retry loop or by asserting on the flash after `render(view)`; if racy, have the handler run `follow_up` synchronously (a one-tap accept is fast for add_item and the run dispatch itself is what's slow — see Step 2 note).)

`planner_live_test.exs` (inside the existing "slot modal" describe; reuse its open-slot helper):

```elixir
test "slot sheet lists predictions scoped to the touched slot and tapping follows",
     %{conn: conn} do
  {:ok, note} =
    Tore.CounterNotes.create(%{
      surface: "week", kind: "freezer_fallback", title: "Frozen bolognese for Monday?",
      body: "Busy evening.",
      proposed_run: %{"kind" => "planner_command", "command" => "assign frozen bolognese",
                      "scoped_slot" => "mon_dinner"}
    })

  {:ok, view, _} = live(conn, ~p"/plan")
  view |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"])) |> render_click()

  assert render(view) =~ "Frozen bolognese for Monday?"

  expect(Tore.MockLLM, :chat_with_tools, fn _s, _m, _t, _o ->
    {:ok, {:message, "done"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  view |> element(~s(button[phx-click="follow_note"][phx-value-id="#{note.id}"])) |> render_click()
  assert Tore.Repo.get!(Tore.CounterNotes.CounterNote, note.id).status == "accepted"
end

test "slot sheet shows no prediction rows for other slots", %{conn: conn} do
  {:ok, _} =
    Tore.CounterNotes.create(%{
      surface: "week", kind: "freezer_fallback", title: "Tuesday note", body: "b",
      proposed_run: %{"kind" => "planner_command", "command" => "x", "scoped_slot" => "tue_dinner"}
    })

  {:ok, view, _} = live(conn, ~p"/plan")
  view |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"])) |> render_click()
  refute render(view) =~ "Tuesday note"
end
```

- [ ] **Step 2: Run both files** — new tests FAIL.
- [ ] **Step 3: Implement.**

`home_live.ex`:
- In mount, derive `hero_note` — the first of `home_notes` with a non-nil `proposed_run` (max-one rule); keep `home_notes` (minus the hero note) rendering as today for informational notes.
- In the hero card's action row, replace the "Something else" button with (matching existing button classes):

```heex
<button
  :if={@hero_note}
  phx-click="follow_note"
  phx-value-id={@hero_note.id}
  class={...same classes as the current "Something else" button...}
>
  {@hero_note.title}
</button>
<button :if={is_nil(@hero_note)} phx-click="something_else" class={...unchanged...}>
  {gettext("Something else")}
</button>
```

- Handler (both LiveViews use the same shape; `follow_up` synchronously accepts + dispatches — the dispatch itself runs the LLM, so wrap the whole call in `Task.start` and mirror `slot_command`'s `{:run_dispatched, result}` handling; home_live gets a minimal `handle_info({:run_dispatched, result}, socket)` that reloads the plan and puts a flash — copy the outcome→flash mapping from `planner_live`'s existing `run_dispatched` handler):

```elixir
def handle_event("follow_note", %{"id" => id}, socket) do
  pid = self()
  actor = %{household_id: socket.assigns.current_user.household_id, user_id: socket.assigns.current_user.id}

  Task.start(fn ->
    result =
      try do
        Tore.CounterNotes.follow_up(String.to_integer(id), actor)
      rescue
        e -> {:error, e}
      end

    send(pid, {:run_dispatched, result})
  end)

  {:noreply, assign(socket, ...loading state per surface...)}
end
```

(If the home test races the Task, make `follow_up`'s `accept` happen before the dispatch — it already does — and have the test await with `assert eventually` style: loop `render(view)` up to ~50 × 10 ms until the status flips; `planner_live_test`'s Plan 2 scoped-command test shows the seam idiom.)

`planner_live.ex`:
- Mount already loads `counter_notes` for `"week"`. In `slot_modal`, above the Plan 2 `slot_command` form, render scoped predictions:

```heex
<div :for={note <- scoped_notes(@counter_notes, @slot_action.slot_key)} class="mt-3">
  <button
    phx-click="follow_note"
    phx-value-id={note.id}
    class={...quiet row styling matching the modal's action buttons...}
  >
    <span class="block text-sm">{note.title}</span>
    <span class="block text-xs text-[color:var(--muted)]">{note.body}</span>
  </button>
</div>
```

```elixir
defp scoped_notes(notes, slot_key) do
  Enum.filter(notes, fn n ->
    match?(%{"scoped_slot" => ^slot_key}, n.proposed_run)
  end)
end
```

- `follow_note` handler: same as home's, plus close the modal the way `slot_command` does (`auto_save_slot` first, then `slot_action: nil, quick_loading: true`).
- The existing "week" notes block (~495–523) keeps Accept/Ignore for informational notes; change its `accept_note` handler to call `follow_up` when the note has a `proposed_run`, falling back to plain `accept` otherwise. `ignore_note` is already the dismissal path (Rule 3) — unchanged.

- [ ] **Step 4: Run** `mix test test/tore_web/live/home_live_test.exs test/tore_web/live/planner_live_test.exs` — green. `mix gettext.extract --merge`; no new msgids expected (note content is dynamic), but verify.

---

### Task 7: Rule-1 wiring — Shop placeholder + tray half state

**Files:**

- Modify: `lib/tore_web/live/shop_live.ex`
- Modify: `lib/tore_web/live/capture_live.ex`
- Create: `test/tore_web/live/shop_live_test.exs` (none exists — new file)
- Test: `test/tore_web/live/capture_live_test.exs` (extend; read its existing setup first)

- [ ] **Step 1: Write the failing tests.**

`shop_live_test.exs` (new file — copy `home_live_test.exs`'s setup block verbatim for admin + session):

```elixir
defmodule ToreWeb.ShopLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.Accounts

  setup do
    {:ok, {user, _code}} = Accounts.create_admin("Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  test "add-field placeholder becomes the predicted item and empty submit accepts it",
       %{conn: conn} do
    {:ok, note} =
      Tore.CounterNotes.create(%{
        surface: "groceries", kind: "usual_item_missing", title: "Oat milk?",
        body: "You always buy it.",
        proposed_run: %{"kind" => "add_item", "name" => "oat milk", "quantity" => nil, "unit" => nil}
      })

    {:ok, view, html} = live(conn, ~p"/shop")
    assert html =~ ~s(placeholder="oat milk?)

    view |> form(~s(form[phx-submit="add_item"]), %{name: "", quantity: "", unit: ""}) |> render_submit()

    assert render(view) =~ "oat milk"
    assert Tore.Repo.get!(Tore.CounterNotes.CounterNote, note.id).status == "accepted"
  end

  test "typed text wins over the prediction", %{conn: conn} do
    {:ok, _} =
      Tore.CounterNotes.create(%{
        surface: "groceries", kind: "usual_item_missing", title: "Oat milk?", body: "b",
        proposed_run: %{"kind" => "add_item", "name" => "oat milk", "quantity" => nil, "unit" => nil}
      })

    {:ok, view, _} = live(conn, ~p"/shop")
    view |> form(~s(form[phx-submit="add_item"]), %{name: "bananas", quantity: "", unit: ""}) |> render_submit()

    html = render(view)
    assert html =~ "bananas"
    refute html =~ ">oat milk<"
  end

  test "empty submit without a prediction is a no-op", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/shop")
    before = render(view)
    view |> form(~s(form[phx-submit="add_item"]), %{name: "", quantity: "", unit: ""}) |> render_submit()
    assert render(view) == before
  end
end
```

(Adjust the placeholder assertion to the exact rendering you implement — the point is: prediction present ⇒ placeholder is the item name, not `"Add item…"`. Check `add_item`'s current empty-name behavior first — if it already rejects blanks, the third test documents that; if it creates blank items, guard the handler.)

`capture_live_test.exs` — read its existing tests for mount/session idiom, then add:

```elixir
test "tray half state lists the origin surface's actionable predictions and tapping follows",
     %{conn: conn} do
  {:ok, note} =
    Tore.CounterNotes.create(%{
      surface: "home", kind: "freezer_fallback", title: "Frozen bolognese tonight?", body: "b",
      proposed_run: %{"kind" => "planner_command", "command" => "assign frozen bolognese",
                      "scoped_slot" => "mon_dinner"}
    })

  {:ok, view, html} = live(conn, ~p"/capture?return_to=/")
  assert html =~ "Frozen bolognese tonight?"

  expect(Tore.MockLLM, :chat_with_tools, fn _s, _m, _t, _o ->
    {:ok, {:message, "done"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  view |> element(~s(button[phx-click="follow_note"][phx-value-id="#{note.id}"])) |> render_click()
  # await acceptance as in Task 6's home test
end

test "tray from /plan shows week predictions, not home ones", %{conn: conn} do
  {:ok, _} =
    Tore.CounterNotes.create(%{
      surface: "home", kind: "freezer_fallback", title: "Home note", body: "b",
      proposed_run: %{"kind" => "planner_command", "command" => "x", "scoped_slot" => "mon_dinner"}
    })

  {:ok, _view, html} = live(conn, ~p"/capture?return_to=/plan")
  refute html =~ "Home note"
end

test "predictions disappear once a message is sent" # render list only when messages == []
```

- [ ] **Step 2: Run both files** — FAIL.
- [ ] **Step 3: Implement.**

`shop_live.ex`:
- Mount (and the PubSub-refresh path) assigns `predicted_item` — first `"groceries"` note whose `proposed_run["kind"] == "add_item"`:

```elixir
predicted =
  Tore.CounterNotes.list_for_surface("groceries")
  |> Enum.find(&match?(%{"kind" => "add_item"}, &1.proposed_run))
```

- The name input's placeholder: `placeholder={(@predicted_item && "#{@predicted_item.proposed_run["name"]}?") || gettext("Add item…")}`.
- `add_item` handler: when the submitted name is blank and `@predicted_item` is set, call `Tore.CounterNotes.follow_up(@predicted_item.id, actor)` (synchronous — `add_item` is deterministic, no LLM) and clear `predicted_item`; when the name is blank and no prediction, no-op; otherwise existing behavior.

`capture_live.ex`:
- Mount: derive the origin surface from the already-computed `return_to`:

```elixir
defp surface_for("/"), do: "home"
defp surface_for("/plan" <> _), do: "week"
defp surface_for("/shop" <> _), do: "groceries"
defp surface_for(_), do: "home"
```

assign `predictions: Tore.CounterNotes.list_for_surface(surface) |> Enum.filter(& &1.proposed_run)`.
- Render, only when `@messages == []`, a list of quiet rows (matter-of-fact, **no AI branding/labels** per design §4) between the tray header and the input: each `<button phx-click="follow_note" phx-value-id={note.id}>` with title + body in muted text, styled like the existing message bubbles' container idiom.
- `follow_note` handler: `Task.start` → `follow_up` → reuse the existing loading + `handle_info` result path: append an assistant bubble with the outcome (map the dispatch result the same way `route_complete` maps router results — read that handler and mirror; a plain-text "Done — {note.title}" bubble on `{:ok, _}` and the error bubble shape on `{:error, _}` is sufficient).

- [ ] **Step 4: Run** `mix test test/tore_web/live/shop_live_test.exs test/tore_web/live/capture_live_test.exs`, then `mix test test/tore_web` — green. `mix gettext.extract --merge` + sv for any new msgid.

---

### Task 8: Long-press hook + tonight-card and grocery-row object sheets

**Files:**

- Create: `assets/js/long_press.js`
- Modify: `assets/js/app.js`
- Modify: `lib/tore_web/live/home_live.ex` (long-press → tonight sheet)
- Modify: `lib/tore_web/live/shop_live.ex` (long-press → item sheet)
- Test: extend `test/tore_web/live/home_live_test.exs`, `test/tore_web/live/shop_live_test.exs`

- [ ] **Step 1: Write the failing tests.**

`home_live_test.exs`:

```elixir
test "long-pressing the tonight card opens a sheet scoped to today with a scoped input",
     %{conn: conn} do
  # seed tonight's recipe (same helper as Task 6)
  {:ok, view, _} = live(conn, ~p"/")

  view |> element(~s([phx-hook="LongPress"][data-long-press-event="open_tonight_sheet"]))
       |> render_hook("open_tonight_sheet", %{})

  html = render(view)
  assert html =~ ~s(form[phx-submit="tonight_command"]) || html =~ ~s(phx-submit="tonight_command")

  expect(Tore.MockLLM, :chat_with_tools, fn _sys, msgs, _tools, _opts ->
    user_msg = ... # same access pattern as planner_live_test's scoped-command test
    assert user_msg =~ "The user is referring to"
    assert user_msg =~ today_slot_key()
    {:ok, {:message, "done"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
  end)

  view
  |> form(~s(form[phx-submit="tonight_command"]), %{command: "make it vegetarian"})
  |> render_submit()

  refute render(view) =~ ~s(phx-submit="tonight_command")  # sheet closed
end

test "escape closes the tonight sheet without dispatching", %{conn: conn} do
  # open as above, then send the close event, assert the sheet is gone
end
```

`shop_live_test.exs`:

```elixir
test "long-pressing a grocery row opens an item sheet whose input routes a scoped command",
     %{conn: conn, user: user} do
  # add an item first via the add_item form (name: "feta")
  {:ok, view, _} = live(conn, ~p"/shop")
  view |> form(~s(form[phx-submit="add_item"]), %{name: "feta", quantity: "", unit: ""}) |> render_submit()

  view |> element(~s([phx-hook="LongPress"][data-item-name="feta"]))
       |> render_hook("open_item_sheet", %{"item_id" => item_id_from_render(view)})

  assert render(view) =~ "feta"

  # the scoped input routes through Capture.Router — mock at the LLM seam the way
  # capture_live's own tests mock a routed text command (read them; if they use
  # Tore.MockLLM for classification, mirror that expectation here)
  view
  |> form(~s(form[phx-submit="item_command"]), %{command: "byt till Apetina 200 g"})
  |> render_submit()

  # assert the sheet closed and a flash/receipt indicator rendered
end
```

(`item_id_from_render/1`: parse the `phx-value-item_id` attribute from the rendered row, or restructure to fetch the id via the same list function shop_live uses. `render_hook` targets the element carrying `phx-hook` — the exact selector must match your markup; adapt when implementing.)

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**

`assets/js/long_press.js`:

```javascript
// Long-press (500 ms) → pushes the event named in data-long-press-event,
// with the element's data-* payload. Movement or release cancels.
const LongPress = {
  mounted() {
    const DURATION = 500
    let timer = null

    const start = () => {
      timer = setTimeout(() => {
        this.pushEvent(this.el.dataset.longPressEvent, {...this.el.dataset})
      }, DURATION)
    }
    const cancel = () => timer && (clearTimeout(timer), (timer = null))

    this.el.addEventListener("touchstart", start, {passive: true})
    this.el.addEventListener("touchend", cancel)
    this.el.addEventListener("touchmove", cancel)
    this.el.addEventListener("touchcancel", cancel)
    this.el.addEventListener("mousedown", start)
    this.el.addEventListener("mouseup", cancel)
    this.el.addEventListener("mouseleave", cancel)
    this.el.addEventListener("contextmenu", (e) => e.preventDefault())
  },
}

export default LongPress
```

`app.js`: `import LongPress from "./long_press"` and add `LongPress` to the `hooks:` map alongside `...colocatedHooks`.

`home_live.ex`:
- Hero card `<section>` (the tonight card wrapper) gains `id="tonight-card" phx-hook="LongPress" data-long-press-event="open_tonight_sheet"` (hooks require an id).
- `handle_event("open_tonight_sheet", _, socket)` → `assign(socket, tonight_sheet: true)` (only when `@tonight_recipe` — no sheet on the empty state).
- Sheet markup: a fixed bottom sheet matching `capture_live`'s tray idiom (same overlay/rounded-top classes — copy them), containing: header `{@tonight_recipe.title}`, the scoped predictions for today (`scoped_notes(@home_notes, @today_key)` — same filter helper as Task 6, rendered as `follow_note` rows), and the scoped input:

```heex
<form phx-submit="tonight_command" class="mt-4">
  <input type="text" name="command" autocomplete="off"
    placeholder={gettext("Anything about tonight…")}
    class={...same input classes as planner's slot_command input — copy them...} />
</form>
```

- `handle_event("tonight_command", %{"command" => command}, socket) when command != ""` — mirror `planner_live`'s `slot_command` dispatch exactly (same ctx map) with `scoped_slot: socket.assigns.today_key`, `plan_stream_id: socket.assigns.plan_id`, `week_start:` (already computed in mount — keep it in an assign), then `tonight_sheet: false` + the Task 6 `run_dispatched` handling. Escape/scrim close: `phx-window-keydown` Escape + a scrim `phx-click="close_tonight_sheet"`, mirroring how `capture_live` closes its tray.

`shop_live.ex`:
- `item_row/1`'s `<li>` gains `id={"item-#{item.id}"} phx-hook="LongPress" data-long-press-event="open_item_sheet" data-item-id={item.id} data-item-name={item.name}`.
- `handle_event("open_item_sheet", %{"item_id" => id}, socket)` → look the item up from the already-assigned list, `assign(socket, item_sheet: item)`.
- Sheet: same bottom-sheet idiom; header = item name (+ qty/unit muted); input:

```heex
<form phx-submit="item_command" class="mt-4">
  <input type="text" name="command" autocomplete="off"
    placeholder={gettext("Anything about this item…")}
    class={...same input classes...} />
</form>
```

- `handle_event("item_command", %{"command" => command}, socket) when command != ""`: `Task.start` →

```elixir
Tore.Capture.Router.route(
  "[The user is referring to the grocery item \"#{item.name}\" on the shopping list.] " <> command,
  [], ctx, []
)
```

with `ctx` built exactly as `capture_live.ex` builds it for `Capture.Router.route/4` (read that call and copy the map). Close the sheet, set a loading flag, and handle the result with a `handle_info` that maps the router result to a flash (reuse `capture_live`'s result→text mapping for the flash body; keep it minimal — the shop list itself refreshes via its existing PubSub subscription when the command mutates it).

- [ ] **Step 4: Run both LiveView test files, then** `mix test test/tore_web` — green. `mix gettext.extract --merge`; sv suggestions: `"Anything about tonight…"` → `"Något om ikväll…"`, `"Anything about this item…"` → `"Något om den här varan…"`.

---

### Task 9: `resolve_slot` — deterministic NL slot resolution + planner tool

**Files:**

- Modify: `lib/tore/harness/resolvers.ex`
- Modify: `lib/tore/llm/planner_tools.ex` (new read tool)
- Modify: `lib/tore/harness/orchestrator.ex` (planner prompt: mention resolve_slot)
- Test: `test/tore/harness/resolvers_test.exs`, `test/tore/llm/planner_tools_test.exs` (extend both)

- [ ] **Step 1: Write the failing tests.**

`resolvers_test.exs` (the file's setup already stubs `Tore.MockLLM.text` and creates "Salmon pasta"/"Salmon soup"/"Chicken skewers"):

```elixir
describe "resolve_slot/2" do
  # slots: %{slot_key => recipe title or nil}
  @slots %{
    "mon_dinner" => "Salmon pasta",
    "tue_dinner" => nil,
    "wed_dinner" => "Chicken skewers"
  }

  test "day words resolve structurally" do
    assert {:ok, %{slot_key: "mon_dinner", label: "Monday dinner"}} =
             Resolvers.resolve_slot("monday", slots: @slots, today: ~D[2026-07-15])

    assert {:ok, %{slot_key: "tue_dinner"}} =
             Resolvers.resolve_slot("Tuesday", slots: @slots, today: ~D[2026-07-15])
  end

  test "tonight/today and tomorrow resolve relative to today" do
    # 2026-07-15 is a Wednesday
    assert {:ok, %{slot_key: "wed_dinner"}} =
             Resolvers.resolve_slot("tonight", slots: @slots, today: ~D[2026-07-15])

    assert {:ok, %{slot_key: "thu_dinner"}} =
             Resolvers.resolve_slot("tomorrow", slots: @slots, today: ~D[2026-07-15])
  end

  test "a recipe reference resolves to the slot holding it" do
    assert {:ok, %{slot_key: "wed_dinner"}} =
             Resolvers.resolve_slot("the chicken skewers slot", slots: @slots, today: ~D[2026-07-15])
  end

  test "a reference matching multiple assigned recipes is ambiguous" do
    slots = Map.put(@slots, "fri_dinner", "Salmon soup")

    assert {:ambiguous, candidates} =
             Resolvers.resolve_slot("the salmon dinner", slots: slots, today: ~D[2026-07-15])

    assert Enum.map(candidates, & &1.slot_key) |> Enum.sort() == ["fri_dinner", "mon_dinner"]
  end

  test "garbage is not found" do
    assert :not_found = Resolvers.resolve_slot("xyzzy plugh", slots: @slots, today: ~D[2026-07-15])
  end
end
```

`planner_tools_test.exs`:

```elixir
test "resolve_slot tool resolves against the working plan", %{ctx: ctx} do
  %{id: rid} = make_recipe(%{title: "Chicken skewers"})
  state = %State{} |> with_slot("wed_dinner", rid)
  tool = find("resolve_slot")

  assert {:ok, %{slot_key: "wed_dinner", label: label}, [], ^state} =
           tool.run.(%{"reference" => "the chicken skewers slot"}, ctx, state)

  assert label =~ "dinner"
end

test "resolve_slot tool reports ambiguity with candidates", %{ctx: ctx} do
  r1 = make_recipe(%{title: "Salmon pasta"})
  r2 = make_recipe(%{title: "Salmon soup"})
  state = %State{} |> with_slot("mon_dinner", r1.id) |> with_slot("fri_dinner", r2.id)
  tool = find("resolve_slot")

  assert {:ok, %{ambiguous: candidates, note: note}, [], ^state} =
           tool.run.(%{"reference" => "the salmon one"}, ctx, state)

  assert length(candidates) == 2
  assert note =~ "ask_user"
end
```

- [ ] **Step 2: Run both files** — FAIL.
- [ ] **Step 3: Implement.**

`resolvers.ex` — add (reusing the module's existing `@accept/@floor/@clear_gap` and `similarity/2`; update the moduledoc's "slot references are covered by structural slot keys" sentence to say NL slot references are resolved here, structurally):

```elixir
@days ~w(mon tue wed thu fri sat sun)
@day_words %{
  "monday" => "mon", "tuesday" => "tue", "wednesday" => "wed", "thursday" => "thu",
  "friday" => "fri", "saturday" => "sat", "sunday" => "sun",
  "mon" => "mon", "tue" => "tue", "wed" => "wed", "thu" => "thu",
  "fri" => "fri", "sat" => "sat", "sun" => "sun"
}

@doc """
Resolve an English natural-language slot reference to a structural slot key.
Slots are a closed domain — no ref indirection needed (SPEC §A.6.2).
opts: slots: %{slot_key => recipe_title | nil}, today: Date.t()
"""
def resolve_slot(reference, opts) when is_binary(reference) do
  slots = Keyword.fetch!(opts, :slots)
  today = Keyword.fetch!(opts, :today)
  q = normalize(reference)

  cond do
    day = relative_day(q, today) -> ok_slot("#{day}_dinner")
    day = word_day(q) -> ok_slot("#{day}_dinner")
    true -> by_recipe(q, slots)
  end
end

defp relative_day(q, today) do
  cond do
    String.contains?(q, "tonight") or String.contains?(q, "today") -> day_of(today)
    String.contains?(q, "tomorrow") -> day_of(Date.add(today, 1))
    true -> nil
  end
end

defp day_of(date), do: Enum.at(@days, Date.day_of_week(date) - 1)

defp word_day(q) do
  Enum.find_value(@day_words, fn {word, day} ->
    if String.contains?(q, word), do: day
  end)
end

defp by_recipe(q, slots) do
  scored =
    slots
    |> Enum.reject(fn {_k, title} -> is_nil(title) end)
    |> Enum.map(fn {k, title} -> {similarity_containing(q, normalize(title)), k} end)
    |> Enum.sort_by(fn {s, _} -> s end, :desc)

  case scored do
    [] -> :not_found
    [{best, _} | _] when best < @floor -> :not_found
    [{best, k}] when best >= @accept -> ok_slot(k)
    [{best, k}, {second, _} | _] when best >= @accept and best - second >= @clear_gap -> ok_slot(k)
    plausible ->
      {:ambiguous,
       plausible
       |> Enum.take_while(fn {s, _} -> s >= @floor end)
       |> Enum.take(3)
       |> Enum.map(fn {_s, k} -> slot_result(k) end)}
  end
end

# "the chicken skewers slot" contains the title, not vice versa — check both ways
defp similarity_containing(q, title) do
  jaro = String.jaro_distance(q, title)
  if String.contains?(q, title) or String.contains?(title, q), do: max(jaro, 0.8), else: jaro
end

defp ok_slot(slot_key), do: {:ok, slot_result(slot_key)}

defp slot_result(slot_key) do
  [day, meal] = String.split(slot_key, "_", parts: 2)
  full = %{"mon" => "Monday", "tue" => "Tuesday", "wed" => "Wednesday", "thu" => "Thursday",
           "fri" => "Friday", "sat" => "Saturday", "sun" => "Sunday"}
  %{slot_key: slot_key, label: "#{full[day]} #{meal}"}
end
```

(Adjust threshold interplay to make the ambiguity test pass — "the salmon dinner" vs "salmon pasta"/"salmon soup" must land two candidates ≥ `@floor` without a clear winner; tune `similarity_containing`'s boost or add a token-overlap boost if Jaro alone under-scores. The tests are the contract; the internals may deviate.)

`planner_tools.ex` — new read tool after `resolve_recipe`, added to `all/0`:

```elixir
defp resolve_slot do
  %Tool{
    name: "resolve_slot",
    description:
      "Resolve a natural-language day/slot reference (in English — e.g. \"tonight\", " <>
        "\"tuesday\", \"the salmon dinner\") to a structural slot_key. " <>
        "Use before slot-targeting actions when the user did not name a slot key.",
    kind: :read,
    parameters: %{
      type: "object",
      properties: %{reference: %{type: "string"}},
      required: ["reference"]
    },
    run: fn args, ctx, plan ->
      slots =
        Map.new(plan.slots, fn {k, slot} ->
          {k, slot.recipe_id && recipe_title(slot.recipe_id)}
        end)

      today = Map.get(ctx, :today, Date.utc_today())

      result =
        case Tore.Harness.Resolvers.resolve_slot(args["reference"], slots: slots, today: today) do
          {:ok, res} -> res
          {:ambiguous, candidates} -> %{ambiguous: candidates, note: "multiple matches — ask_user or refine"}
          :not_found -> %{not_found: true}
        end

      {:ok, result, [], plan}
    end
  }
end
```

(`recipe_title/1` already exists in the module. No `__handles__`, no registry — slot keys are structural by design.)

`orchestrator.ex` planner instructions (~line 868 area): extend the resolve-then-act sentence: slots referenced in natural language ("tonight", a weekday, "the salmon dinner") are resolved with `resolve_slot` before slot-targeting actions; on ambiguity `ask_user`, never guess.

- [ ] **Step 4: Run** `mix test test/tore/harness/resolvers_test.exs test/tore/llm` — green.

---

### Task 10: Spec amendments

**Files:**

- Modify: `SPEC.md` (CounterNote catalog/§3 kind table, ambient scan, §A.6.2, §Status)
- Modify: `UI_SPEC.md` (prediction rules + surfaces touched)
- Modify: `docs/specs/2026-07-04-surface-consolidation-design.md` (shipped notes)

Doc-only task. Read the shipped code from Tasks 1–9 first and describe what IS, not what the design hoped. Match each document's voice and heading conventions (SPEC has a dated `## Status` log; the design doc uses bold-lead-in notes like `**Shipped** 2026-07 …`).

- [ ] **Step 1: SPEC.md.**
  - CounterNote section (find the kind table §3 references): add the four scan kinds with trigger rule + proposed_run shape each; document the `proposed_run` sum type (`planner_command` — dispatched via `:planner_command_run` with `started_by: "counter_note_followup"` and Plan 2 `scoped_slot` scoping; `add_item` — deterministic direct apply, no LLM; `nil` — informational) and the verified-before-materialize pipeline (`CounterNoteVerifier`, cap one per surface, scan-batch replacement, daily expiry).
  - New `:ambient_scan_run` run kind: Tier 0, `started_by: "system"`, capsules used, single text call, SpendGuard `:ambient_scan {8_000 tokens, 600 s cooldown}`, triggers (05:00 cron + 5-min-debounced plan/shop mutation), dismissal-feedback rule ("recently ignored" in prompt).
  - §A.6.2: move `resolve_slot` from the deferred list to shipped, with the structural-key decision recorded: slot keys are a closed domain, so the resolver returns `slot_key` + label directly — no ref token, invented keys dead-end on existing tool validation. Deferred list now: `resolve_grocery_item`, `resolve_pantry_item`, grocery-item handles.
  - `## Status`: dated entry (2026-07-18 or the execution date) recording all of the above + the long-press object-sheet extension.
- [ ] **Step 2: UI_SPEC.md.** In the relevant sections (grep for the counter-note / §2.3 anticipation text and each surface's section): the three prediction rules (replace-never-add; precomputed-never-awaited; dismissal-is-signal), hero-card max-one + follow/tap semantics, shop placeholder + empty-submit accept, tray half state (origin-surface predictions above the input, gone once a message is sent, no AI branding), tonight-card and grocery-row long-press sheets (calm rules as §6.2's slot sheet), Escape/scrim close.
- [ ] **Step 3: Design doc.** §3: `**Shipped** <date> — ambient scan + four kinds + follow_up dispatch; cooking-view inline substitutions deferred.` §4: half state shipped note. §4.1: extend the Plan 2 shipped note — tonight card and grocery rows shipped (grocery scoping via text referent; item handles deferred until grocery action tools exist); `resolve_slot` shipped as structural.
- [ ] **Step 4: Run** `mix test` (full suite) once — green (modulo the known Exqlite flake, verified in isolation).

---

### Task 11: Final review + single commit (controller)

- [ ] Dispatch one independent read-only reviewer over the whole uncommitted diff. Checklist:
  - Rule 2 holds: no LLM call in any mount/render path — predictions come only from `counter_notes` rows (grep the LiveViews for `Tore.LLM`/`Orchestrator.dispatch` outside event handlers' Tasks).
  - Rule 1 holds: hero card and shop form have the same element count with and without predictions; tray rows render only pre-input.
  - `follow_up` is the only accept-with-effect path; `ignore` never dispatches; a note without `proposed_run` can't dispatch.
  - The scan replaces only scan-kind pending notes; manual/informational notes survive; `expire_stale` and the scan are both on cron; the debouncer can't fire in tests (test-env quiet period) and SpendGuard gates the scan.
  - The verifier rejects out-of-domain `scoped_slot` before anything is materialized; `resolve_slot` returns only keys from the closed domain.
  - No AI branding/persona copy anywhere new (grep new strings for "AI", "assistant", sparkles).
  - Long-press hook: no duplicate event listeners across LiveView patches (hook lifecycle), `contextmenu` suppressed only on hook elements.
  - New msgids all have sv translations; specs match shipped code.
- [ ] Fix findings; rerun affected tests; full `mix test` once more.
- [ ] Controller only:

```bash
jj describe -m "feat(harness): anticipation layer — ambient scan, predictions, object sheets, resolve_slot

<summary paragraphs>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj new
jj bookmark move master --to @-
jj git push -b master
```

---

## Self-review notes (done at planning time)

- **Design §3 coverage:** Rule 1 (Tasks 6–7), Rule 2 (architecture — materialized notes only; reviewer check in Task 11), Rule 3 (`recently_ignored` → scan prompt, Task 1+3). All four §10.3 kinds (Tasks 1–3). §10.4 re-triggers (Tasks 3–4). §4 half state (Task 7). §4.1 long-press sheets (Task 8). NL `resolve_slot` (Task 9). Specs (Task 10).
- **Deliberate deviations from the design doc, recorded in Task 10:** notes carry `proposed_run` as a typed map (design's "proposed_run that one tap dispatches" had no mechanism at all in code); `add_item` proposals apply deterministically without an LLM run; `resolve_slot` returns structural keys, not handles (closed domain — consistent with Plan 2's locked slot decision); grocery sheets scope by text referent, not item handles; `started_by` is the string `"counter_note_followup"` matching the Run aggregate's existing string-typed field (design wrote it as an atom).
- **Type consistency:** `proposed_run` string-keyed everywhere (Ecto `:map` JSON round-trip); `follow_up(id, %{household_id, user_id})` used identically in Tasks 5–8; `scoped_notes/2` filter identical in Tasks 6 and 8; verifier consumes raw string-keyed LLM maps (pre-insert), context functions consume atom-keyed attrs (post-shape) — Task 3 step 4 is the explicit mapping point between them.
- **Known unknowns, named with their lookup source (not placeholders):** exact `Shop.add_item/5` argument order (`shop_live.ex:57`), ctx builder for current week (`kitchen_memory_synthesis.ex`), `Capture.Router.route/4` ctx map (`capture_live.ex`), message-shape access in Mox assertions (`planner_live_test.exs` Plan 2 test), Mox async constraints in `counter_notes_test.exs` (Task 5 names the split-file fallback).
