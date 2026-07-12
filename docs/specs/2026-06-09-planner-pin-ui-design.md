# Planner Pin UI Design

**Date:** 2026-06-09
**Scope:** A user-facing pin/unpin control in the planner, making the existing
`PlanVerifier` `:slot_pinned` protection reachable.

## Goal

Let a user pin/unpin a meal slot from the planner. A pin is a signal to the
planner agent — *"don't touch this day"* — enforced deterministically by
`PlanVerifier.check_pins`. Today the pin backend
(`PlanningHandler.pin_slot/3`/`unpin_slot/3` → `SlotPinned`/`SlotUnpinned` →
`Planning.State.pins`) and the verifier check already exist and work; there is
simply no UI to set a pin. This closes that gap.

## Context: what already exists (no backend work)

- `Tore.Handlers.PlanningHandler.pin_slot(plan_id, slot_key, pin)` →
  `{:ok, [%SlotPinned{}]}`; `unpin_slot(plan_id, slot_key)` → `{:ok, [%SlotUnpinned{}]}`.
- `Tore.Planning.State.pins` (a `slot_key => true` map), reconstructed on
  `load_plan/1`.
- `Tore.Harness.Verifier.PlanVerifier.check_pins/2` fails any run whose PlanDiff
  touches a pinned slot, recording `:slot_pinned` + `{:edit_plan, [slot]}`
  (verified end-to-end in a live smoke).

This feature is **LiveView + i18n only**. No aggregate, command, event, or
verifier changes.

## Semantics

- **Pin blocks the AI only.** It is purely a signal to the planner agent. All
  manual modal controls (recipe, servings, skip, leftovers) stay fully usable on
  a pinned slot — it is the user's slot; the pin governs the agent, not the user.
  No UI disabling/gating.
- **Pinning an empty slot is allowed** (reserve a day). `pin_slot/3` does not
  require an assigned recipe.

## Components & data flow

### 1. Slot editor modal — pin toggle

A "Pin this day" toggle button in the modal's action row, beside the existing
"Skip dinner" button, following the `toggle_skipped` idiom.

- **`open_slot` seeds the pin state.** The initial `slot_action` map gains
  `pinned: Map.has_key?(socket.assigns.plan_state.pins, sk)`.
- **New handler `handle_event("toggle_pinned", _, socket)`.** It flips
  `slot_action.pinned` and **persists immediately in the handler** (not via
  `auto_save_slot`), because pinning is an independent aggregate command:

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

  The `pinned` field in `slot_action` exists only to render the toggle's
  on/off appearance; the authoritative state is the persisted `SlotPinned`/
  `SlotUnpinned` event. (The plan PubSub broadcast from `pin_slot`/`unpin_slot`
  refreshes `plan_state` via the existing `handle_info({:events, _}, ...)` path,
  keeping the day-row indicator in sync.)

- **Button appearance.** Mirrors the skip toggle's active/inactive styling, with
  a lock icon — `hero-lock-closed` when pinned, `hero-lock-open` when not — and
  gettext labels: pinned → `gettext("Pinned")`, not pinned →
  `gettext("Pin this day")`.

### 2. Day row — read-only pin indicator

When a slot is pinned, `day_row/1` shows a small lock icon (consistent with how
it surfaces the skipped state). `day_row` already receives `plan_state` and
`slot_key`, so it reads membership directly:

```heex
<.icon :if={Map.has_key?(@plan_state.pins, @slot_key)} name="hero-lock-closed" class="size-4 text-[color:var(--subtle)]" />
```

(placed alongside the row's existing day/recipe content). Indicator only — not
interactive; pins are set in the modal.

## What does NOT change

- No backend: `pin_slot/3`, `unpin_slot/3`, `SlotPinned`/`SlotUnpinned`,
  `State.pins`, `PlanVerifier.check_pins` are all untouched.
- `auto_save_slot/1` is untouched — the pin persists in its own handler, keeping
  the independent `SlotPinned` command out of the recipe-assignment save path.

## Files

```
Modify: lib/tore_web/live/planner_live.ex
          - open_slot: seed `pinned: Map.has_key?(plan_state.pins, sk)`
          - new handle_event("toggle_pinned", ...) (persists immediately)
          - slot_modal: "Pin this day"/"Pinned" toggle button in the action row
          - day_row: read-only lock indicator when the slot is pinned
Modify: priv/gettext/en/LC_MESSAGES/default.po
        priv/gettext/sv/LC_MESSAGES/default.po
          - "Pin this day" → "Lås dagen"; "Pinned" → "Låst"
```

## Testing

`test/tore_web/live/planner_live_test.exs` (reuse the existing `setup`
`%{user: user}` + `authed/2`):

- **Toggling pin persists `SlotPinned`.** Open a slot's modal, click the pin
  toggle, assert `PlanningHandler.load_plan(plan_id)` → `state.pins` now has the
  slot key.
- **Untoggling persists `SlotUnpinned`.** From a pinned slot, click the toggle
  again, assert the key is gone from `state.pins`.
- **Day row renders the indicator when pinned, not otherwise.** Pin a slot via
  `PlanningHandler.pin_slot/3`, render the planner, assert the lock icon /
  `hero-lock-closed` appears for that row and is absent for an unpinned row.
- **Opening a pinned slot shows the toggle in its "on" state.** Pin a slot, open
  its modal, assert the rendered toggle reflects pinned (label `Låst` in the
  `sv` test locale).

i18n: add the two msgids, fill the Swedish msgstrs, and **strip the `fuzzy`
flag** after `gettext.merge` (the fuzzy trap — gettext renders the English msgid
for fuzzy entries; the test asserts Swedish).

## Out of scope

- A tappable pin icon directly on the day row (set-in-modal only for now).
- Any change to how the planner agent or verifier handles pins (already built).
- Locking manual edits on a pinned slot (pin governs the AI, not the user).
