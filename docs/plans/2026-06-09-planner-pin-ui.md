# Planner Pin UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-facing pin/unpin control to the planner so the existing `PlanVerifier` `:slot_pinned` protection is reachable from the UI.

**Architecture:** Pure LiveView + i18n. The pin backend (`PlanningHandler.pin_slot/3`/`unpin_slot/3` → `SlotPinned`/`SlotUnpinned` → `Planning.State.pins`) and `PlanVerifier.check_pins` already exist and are proven. We add: a "Pin this day" toggle in the slot editor modal (persists immediately in its own handler, mirroring `toggle_skipped`), and a read-only lock indicator on the day row. The `{:events, _}` PubSub broadcast from `pin_slot`/`unpin_slot` flows through the existing `handle_info({:events, _}, ...)` (planner_live.ex:332), reloading `plan_state` so the day-row indicator stays in sync.

**Tech Stack:** Elixir, Phoenix LiveView (HEEx), gettext (en/sv, test locale is `sv`). VCS is **jj** (Jujutsu), never git. Push to master per repo convention.

**Spec:** `docs/specs/2026-06-09-planner-pin-ui-design.md`

---

## Conventions

- Test: `mix test test/tore_web/live/planner_live_test.exs`.
- Commit each task with jj: `jj describe -m "<msg>"` then `jj new`. Controller pushes at the end.
- Touch only `lib/tore_web/live/planner_live.ex` + the two `.po` files + the planner test (CLAUDE.md: touch only what the task requires).
- **No backend changes** — `pin_slot/3`, `unpin_slot/3`, `State.pins`, `check_pins` already exist.

---

### Task 1: Pin toggle handler + modal seed

**Files:**

- Modify: `lib/tore_web/live/planner_live.ex`
  - `handle_event("open_slot", ...)` (~line 63): add `pinned` to the initial `slot_action` map.
  - new `handle_event("toggle_pinned", ...)`: place it right after the existing `handle_event("toggle_skipped", ...)` (~line 163-166).
- Test: `test/tore_web/live/planner_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/tore_web/live/planner_live_test.exs` (reuse the file's `setup` `%{user: user}` + `defp authed(conn, user)`; the file aliases `PlanningHandler`). Add a `describe` block:

```elixir
describe "pinning a slot" do
  test "toggling pin in the modal persists a SlotPinned event", %{conn: conn, user: user} do
    conn = authed(conn, user)
    plan = this_plan_id()
    {:ok, lv, _html} = live(conn, "/plan")

    lv |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"])) |> render_click()
    lv |> element(~s(button[phx-click="toggle_pinned"])) |> render_click()

    {:ok, state} = PlanningHandler.load_plan(plan)
    assert Map.has_key?(state.pins, "mon_dinner")
  end

  test "toggling pin off persists a SlotUnpinned event", %{conn: conn, user: user} do
    conn = authed(conn, user)
    plan = this_plan_id()
    PlanningHandler.pin_slot(plan, "mon_dinner", true)
    {:ok, lv, _html} = live(conn, "/plan")

    lv |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"])) |> render_click()
    lv |> element(~s(button[phx-click="toggle_pinned"])) |> render_click()

    {:ok, state} = PlanningHandler.load_plan(plan)
    refute Map.has_key?(state.pins, "mon_dinner")
  end
end
```

(Confirm `this_plan_id/0` exists in the test file — it does, used by other tests — and returns the current week's plan id, which is what `/plan` mounts. If the modal markup uses a different selector for the slot row, inspect the rendered html and adjust the `open_slot` selector; the day_row `<div phx-click="open_slot" phx-value-slot_key=...>` is the click target.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: FAIL — no `toggle_pinned` handler / no pin button to click (`element/2` finds nothing).

- [ ] **Step 3: Seed `pinned` in `open_slot`**

In `handle_event("open_slot", %{"slot_key" => sk}, socket)`, the `initial` map (~line 77-87) currently ends with `flipped: false`. Add `pinned`:

```elixir
    initial = %{
      slot_key: sk,
      search: "",
      suggestions: [],
      loading_suggestions: true,
      selected_recipe_id: slot && slot.recipe_id,
      servings: (slot && slot.servings) || 4,
      leftover_days: existing_leftover_days,
      skipped: (slot && slot.skipped) || false,
      flipped: false,
      pinned: Map.has_key?(socket.assigns.plan_state.pins, sk)
    }
```

- [ ] **Step 4: Add the `toggle_pinned` handler**

Place immediately after `handle_event("toggle_skipped", ...)` (~line 166):

```elixir
  def handle_event("toggle_pinned", _, socket) do
    %{slot_key: sk, pinned: was_pinned} = socket.assigns.slot_action
    plan_id = socket.assigns.plan_id

    if was_pinned,
      do: PlanningHandler.unpin_slot(plan_id, sk),
      else: PlanningHandler.pin_slot(plan_id, sk, true)

    {:noreply, update_slot(socket, fn s -> %{s | pinned: !was_pinned} end)}
  end
```

(`update_slot/2` already exists — it maps over `slot_action`. `unpin_slot/3` is actually `unpin_slot(plan_id, slot_key)` — confirm arity by reading `planning_handler.ex`; it's `unpin_slot(plan_id, slot_key)`.)

- [ ] **Step 5: Add the toggle button to the modal**

In `slot_modal/1`, after the "Skip dinner" button (the `<button ... phx-click="toggle_skipped">...</button>` ending ~line 859), still inside the same action-row `<div>` (which closes at ~line 860), add a sibling pin button mirroring the skip toggle's styling:

```heex
              <button
                type="button"
                phx-click="toggle_pinned"
                class={[
                  "inline-flex items-center gap-2 rounded-[var(--r-pill)] px-3 h-8 transition-colors",
                  @slot_action.pinned &&
                    "bg-[color:var(--accent-soft)] text-[color:var(--accent)] font-medium",
                  !@slot_action.pinned &&
                    "text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
                ]}
                style="font-size: var(--t-meta);"
              >
                <.icon
                  name={if @slot_action.pinned, do: "hero-lock-closed", else: "hero-lock-open"}
                  class="size-4"
                />
                {if @slot_action.pinned, do: gettext("Pinned"), else: gettext("Pin this day")}
              </button>
```

(Place it right before the action-row's closing `</div>`. If `--accent-soft` isn't a defined CSS var in this project, use the same neutral active style the skip button uses with `--accent`/`--accent-soft`; check an existing usage — `--accent-soft` is used elsewhere in this file, e.g. the day-row hover, so it's valid.)

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: PASS (both new tests + all existing).

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(web): pin/unpin toggle in the planner slot editor"
jj new
```

---

### Task 2: Day-row pin indicator

**Files:**

- Modify: `lib/tore_web/live/planner_live.ex` (`day_row/1`, ~line 550)
- Test: `test/tore_web/live/planner_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to the `describe "pinning a slot"` block:

```elixir
test "the day row shows a lock indicator when the slot is pinned", %{conn: conn, user: user} do
  conn = authed(conn, user)
  plan = this_plan_id()
  PlanningHandler.pin_slot(plan, "mon_dinner", true)
  {:ok, _lv, html} = live(conn, "/plan")

  # the pinned row carries the lock indicator id
  assert html =~ ~r/id="slot-mon_dinner".*?data-pinned="true"/s
end

test "the day row shows no lock indicator when not pinned", %{conn: conn, user: user} do
  conn = authed(conn, user)
  {:ok, _lv, html} = live(conn, "/plan")
  refute html =~ ~s(data-pinned="true")
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: FAIL — no `data-pinned` attribute rendered.

- [ ] **Step 3: Compute `pinned` in `day_row/1` and render the indicator**

In `day_row/1` (~line 550), the function computes `slot`/`recipe`/`is_today` then `assign`s them. Add `pinned`:

```elixir
  defp day_row(assigns) do
    slot = Map.get(assigns.plan_state.slots, assigns.slot_key)
    recipe = recipe_by_id(assigns.recipes, slot[:recipe_id])
    is_today = assigns.date == assigns.today
    pinned = Map.has_key?(assigns.plan_state.pins, assigns.slot_key)
    assigns = assign(assigns, slot: slot, recipe: recipe, is_today: is_today, pinned: pinned)
```

Then render a lock indicator. Place it inside the date column `<div class="flex flex-col items-center">` block, after the "Today" `<div :if={@is_today}>` (~line 600), so it shows for both empty and filled pinned slots.

**Important:** this project's `icon/1` component (`lib/tore_web/components/core_components.ex:389-393`) renders only `<span class={[@name, @class]} />` and does **not** forward arbitrary attributes — a `data-pinned` placed on `<.icon>` would be silently dropped. So wrap the icon in a `<span>` that carries the `data-pinned` test hook and a `title` tooltip:

```heex
          <span
            :if={@pinned}
            data-pinned="true"
            title={gettext("Pinned")}
            class="mt-1 text-[color:var(--subtle)]"
          >
            <.icon name="hero-lock-closed" class="size-3.5" />
          </span>
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(web): day-row lock indicator for pinned slots"
jj new
```

---

### Task 3: Swedish translations

**Files:**

- Modify: `priv/gettext/en/LC_MESSAGES/default.po`, `priv/gettext/sv/LC_MESSAGES/default.po`
- Test: `test/tore_web/live/planner_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to the `describe "pinning a slot"` block (test env runs in `sv`):

```elixir
test "the pin toggle renders its Swedish label", %{conn: conn, user: user} do
  conn = authed(conn, user)
  {:ok, lv, _html} = live(conn, "/plan")
  html = lv |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"])) |> render_click()
  assert html =~ "Lås dagen"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: FAIL — renders the English "Pin this day" (no sv translation yet).

- [ ] **Step 3: Extract and translate**

Run:
```bash
mix gettext.extract && mix gettext.merge priv/gettext
```
Then edit `priv/gettext/sv/LC_MESSAGES/default.po`: fill the Swedish msgstr for the two new msgids and **delete the `#, fuzzy` flag line** above each (THE FUZZY TRAP — gettext renders the English msgid for fuzzy entries; the test asserts Swedish and would fail):

- `"Pin this day"` → `"Lås dagen"`
- `"Pinned"` → `"Låst"`

(The `en` .po gets the msgids with empty msgstr — fine, en falls back to msgid. Don't leave en entries fuzzy either.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: PASS.

Verify no fuzzy leaked: `grep -B1 "Lås dagen\|Låst" priv/gettext/sv/LC_MESSAGES/default.po | grep fuzzy` → no output.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(web): Swedish translations for the pin toggle"
jj new
```

---

### Task 4: Full suite + finish

- [ ] **Step 1: Run the full suite**

Run: `mix test`
Expected: 0 failures (a rare intermittent SQLite "Database busy" flake in an unrelated LiveView test can appear under parallel load — if you see ONLY that, re-run once to confirm it's the flake).

- [ ] **Step 2: Final review + push**

Dispatch a final code review over the change, then use **superpowers:finishing-a-development-branch** to set `master` to the work tip and `jj git push -b master`.

**Manual smoke (user-run):** open the planner, tap a slot, toggle "Lås dagen" on → the day row shows the lock; ask Tore to change that slot → the receipt shows the `:slot_pinned` failure + "Redigera planen" link (this exercises the full chain the verifier work built). Toggle off → the slot is editable by the agent again.
