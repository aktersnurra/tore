# Capture / Shop Vocabulary Rename Design

**Date:** 2026-06-11
**Spec section:** SPEC.md §Status (2026-06-02 vocabulary line), §Interfaces
(Capture `/capture`, Shop `/shop`), §Module Map.
**Scope:** Align code with the SPEC's adopted UI vocabulary — `Chat` → `Capture`,
`Groceries` → `Shop` — at the **surface and the grocery-list aggregate that
surface owns**. A pure rename + one dead-code deletion. No behaviour changes.

## Goal

The 2026-06-02 SPEC vocabulary line adopted `Capture` (replacing `Chat`) and
`Shop` (replacing `Groceries`) but explicitly deferred the code rename to "a
separate sub-plan." This is that sub-plan. It renames the Capture and Shop
surfaces and, for Shop, the grocery-list aggregate the surface owns — unifying
the surface with its own stream rather than carrying two names for one concept.

## The surface / domain / cross-feature distinction (why the boundary is where it is)

Three layers use the word "grocery"; only the first two rename:

1. **The Shop surface** — the `/shop` screen + its LiveView. Presentation.
2. **The grocery-list aggregate the Shop surface owns** — `Tore.Groceries`
   (decider/events/state/commands/aggregator) + the `"grocery_list:"` stream key.
   This is ~1:1 with the surface (the Shop page *is* the grocery list), so naming
   them differently (Shop vs groceries) is a needless split. Unify → `Shop`.
3. **Cross-feature grocery vocabulary** — `GroceryDiff`, `GroceryVerifier`,
   `resolve_grocery_item`, `:grocery_reconciliation_run`, `:grocery_checkoff`
   (a *pantry* provenance), `FinishTheShoppingList`. These name the grocery
   *concept* used by **other** features (planning, pantry, reconciliation), not
   the Shop screen. They collide with "grocery" only through English. Renaming
   them to "shop" would impose a false abstraction (a pantry checkoff is not a
   "shop"). **Keep them.**

The Capture side has the same shape but a cleaner split: `Capture` is the surface
(it accepts text, photos, receipts); `Conversation` is the one thing the text
path produces. Surface ≠ the thing — so the logic module is `Conversation`, not
`Capture.Capture`.

This pass overrides SPEC line 69's parenthetical ("the decider stream stays named
`groceries`"): the app is pre-production with no persisted events, so unifying the
stream name to `shop` costs nothing and removes the double-naming. SPEC.md is
updated to match (see SPEC changes below).

## Scope

### Capture side

| From | To |
|---|---|
| `Tore.Chat.ChatHandler` | `Tore.Capture.Conversation` |
| `ChatHandler.handle_text/2` | `Conversation.reply/2` |
| `ToreWeb.ChatLive` (`chat_live.ex`) | `ToreWeb.CaptureLive` (`capture_live.ex`) |
| route `/chat` (main scope) | `/capture` |
| `ToreWeb.KioskChatLive` (`kiosk_chat_live.ex`) | `ToreWeb.KioskCaptureLive` (`kiosk_capture_live.ex`) |
| route `/kiosk/chat` | `/kiosk/capture` |
| `navigate="/kiosk/chat"` (kiosk_live.ex:217) | `navigate="/kiosk/capture"` |

**Naming rationale (Tiger Style):** `handle_text` uses the forbidden `handle_*`
verb; the module's job is to produce a reply to a captured message, so the module
names the domain concept (`Conversation`) and the function names the action
(`reply`). `ChatHandler` was already an outlier (it lived at `Tore.Chat.*`,
outside the `Tore.Handlers.*` family), so relocating it to a Tiger-Style name
costs nothing. (The broader `*Handler` family — `GroceriesHandler` included — is
**not** renamed here; that is a separate dedicated spec. See Out of Scope.)

**Delete (dead code):** `Tore.Chat.WeekContext` (`lib/tore/chat/week_context.ex`)
and its test (`test/tore/chat/week_context_test.exs`). `WeekContext.build/1`
renders a plan to a summary string but has **no caller in `lib/`** — it was
superseded by `WeekPlanCapsule`. Deleting it (rather than renaming dead code)
fully retires the `Tore.Chat` namespace.

### Shop side

| From | To |
|---|---|
| `ToreWeb.GroceryLive` (`grocery_live.ex`) | `ToreWeb.ShopLive` (`shop_live.ex`) |
| route `/groceries` | `/shop` |
| nav label `"Groceries"` (layouts.ex:14) | `"Shop"` (+ Swedish translation) |
| `grocery_row/1` (UI render helper) | `item_row/1` |
| `Tore.Groceries.Decider` | `Tore.Shop.Decider` |
| `Tore.Groceries.Events` | `Tore.Shop.Events` |
| `Tore.Groceries.State` | `Tore.Shop.State` |
| `Tore.Groceries.Commands` | `Tore.Shop.Commands` |
| `Tore.Groceries.Aggregator` | `Tore.Shop.Aggregator` |
| dir `lib/tore/groceries/` | `lib/tore/shop/` |
| stream key `"grocery_list:#{...}"` | `"shop_list:#{...}"` |
| `grocery_id/1` helper (grocery_live.ex:315, planner_live.ex:1183) | `shop_id/1` |

**Stays (this pass):** `Tore.Handlers.GroceriesHandler` keeps its name — it is a
conforming member of the `Tore.Handlers.*Handler` family, and renaming it belongs
to the separate handlers spec. Its **internal references** to `Tore.Groceries.*`
update to `Tore.Shop.*` (the aggregate it drives moved). This leaves a deliberate
interim asymmetry (`Tore.Shop` aggregate driven by `GroceriesHandler`), resolved
when the handlers spec runs.

### Keep unchanged (cross-feature grocery domain vocabulary)

`GroceryDiff`, `GroceryVerifier`, `resolve_grocery_item`,
`:grocery_reconciliation_run`, `:grocery_checkoff` provenance,
`FinishTheShoppingList`, and the `grocery_items_updated` RunSummary count key.
These belong to planning / pantry / reconciliation features, not the Shop
surface. (Most are in unbuilt features.)

## SPEC.md changes

The rename is only coherent if SPEC.md stops contradicting it:

- **Line 69** — remove the parenthetical "(decider stream stays named
  `groceries`)"; the stream is now `shop`. Reword to reflect the unified name.
- **Module map** (≈ lines 748-820) — `groceries/` → `shop/`; `grocery_live.ex` →
  `shop_live.ex`; `chat_live.ex` → `capture_live.ex`; `kiosk_chat_live.ex` →
  `kiosk_capture_live.ex`. Leave `groceries_handler.ex` (renamed in the handlers
  spec) and the `grocery_verifier.ex` / `resolve_grocery_item` references (kept
  vocabulary).
- Do **not** touch SPEC references to the kept cross-feature vocabulary
  (`GroceryDiff`, `:grocery_*_run`, `:grocery_checkoff`, etc.).

## Architecture / data flow

No control-flow or data-shape changes. The Shop aggregate's events, decider
logic, and PubSub topic behave identically — only module names, the directory,
and the stream-key string change. The Capture surface routes text to
`Conversation.reply/2` exactly as it routed to `ChatHandler.handle_text/2`.

The one runtime-visible change is the **stream key string** (`"grocery_list:"` →
`"shop_list:"`). Because there is no persisted production data, no historical
events exist under the old key; nothing to migrate. Every caller that builds the
key (`grocery_id/1` in two LiveViews, the `list_id` in the handler test) changes
together, so the key is internally consistent.

The grocery list is loaded directly via `EventStore.load(list_id, Decider)` from
`GroceriesHandler` (alias line) and read in the LiveViews — the **Projector,
EventStore, and config.exs have no reference to the groceries aggregate or
stream** (verified: the Projector replays harness *runs*, not this stream). So
the rename surface is confined to the handler's aliases, the LiveViews, and the
aggregate/test files — no scheduler/projector wiring to touch.

## File structure

```
Rename: lib/tore/chat/chat_handler.ex          → lib/tore/capture/conversation.ex   (module + handle_text→reply)
        lib/tore_web/live/chat_live.ex          → lib/tore_web/live/capture_live.ex
        lib/tore_web/live/kiosk_chat_live.ex    → lib/tore_web/live/kiosk_capture_live.ex
        lib/tore/groceries/decider.ex           → lib/tore/shop/decider.ex
        lib/tore/groceries/events.ex            → lib/tore/shop/events.ex
        lib/tore/groceries/state.ex             → lib/tore/shop/state.ex
        lib/tore/groceries/commands.ex          → lib/tore/shop/commands.ex
        lib/tore/groceries/aggregator.ex        → lib/tore/shop/aggregator.ex
        lib/tore_web/live/grocery_live.ex       → lib/tore_web/live/shop_live.ex
Delete: lib/tore/chat/week_context.ex
        test/tore/chat/week_context_test.exs
Modify: lib/tore_web/router.ex                  (/chat→/capture, /kiosk/chat→/kiosk/capture, /groceries→/shop; module names)
        lib/tore_web/live/kiosk_live.ex         (navigate="/kiosk/chat"→"/kiosk/capture")
        lib/tore_web/components/layouts.ex       (nav: /groceries→/shop, "Groceries"→"Shop")
        lib/tore/handlers/groceries_handler.ex   (Tore.Groceries.* → Tore.Shop.* internal refs ONLY; module name kept)
        lib/tore_web/live/planner_live.ex        (grocery_id→shop_id + "grocery_list:"→"shop_list:"; any Tore.Groceries.* ref)
        lib/tore_web/live/cost_live.ex           (any Tore.Groceries.* / Groceries ref)
        lib/tore_web/live/cooking_live.ex        (any Tore.Groceries.* ref)
        lib/tore_web/live/pantry_live.ex         (any Tore.Groceries.* ref)
        SPEC.md                                  (line 69 + module map, per SPEC changes above)
Rename test files + update refs:
        test/tore/chat/chat_handler_test.exs    → test/tore/capture/conversation_test.exs
        test/tore/groceries/decider_test.exs    → test/tore/shop/decider_test.exs
        test/tore/groceries/aggregator_test.exs → test/tore/shop/aggregator_test.exs
        test/tore/handlers/groceries_handler_test.exs  (Tore.Groceries.*→Tore.Shop.*, "grocery_list:"→"shop_list:"; file/module name kept)
Modify i18n: priv/gettext (Swedish "Shop" label translation)
```

## Testing

- **Behaviour-preserving:** every existing test that exercised Chat/Groceries
  must pass after rename (same assertions, updated module names / stream keys).
  The `groceries`/shop aggregate tests (`decider_test`, `aggregator_test`,
  `groceries_handler_test`) prove the data layer behaves identically under the
  new names + key.
- **Route smoke:** add/keep a test that `GET /capture`, `/kiosk/capture`, and
  `/shop` render (and that the old `/chat`/`/groceries` paths are gone — a
  `live/2` to the old path should 404 / not route).
- **No dangling refs:** `grep -rn "Tore.Chat\|Tore.Groceries\|ChatLive\|GroceryLive\|ChatHandler\|grocery_list:\|WeekContext" lib/ test/` returns nothing after the pass (the kept cross-feature `Grocery*`/`grocery_*` vocabulary is a different match — verify each remaining hit is intentional).
- **Compile clean** with `--warnings-as-errors`.
- **Full suite green.**
- **gettext:** the Swedish "Shop" nav label is the only user-facing copy change;
  follow the project's gettext flow and avoid the fuzzy trap (new msgid should be
  non-fuzzy, but verify the sv translation renders, since the test env runs in
  `sv`).

## Out of scope

- **Renaming the `Tore.Handlers.*Handler` family** to Tiger-Style names
  (`PlanningHandler`, `RecipeHandler`, `GroceriesHandler`, etc.) — a separate
  dedicated spec. This pass keeps all `*Handler` names (only `ChatHandler` →
  `Conversation`, because its namespace is being retired regardless).
- **Cross-feature grocery vocabulary** (`GroceryDiff`, `:grocery_checkoff`, etc.)
  — kept; renaming would impose a wrong abstraction.
- **`"deal_opportunity"` counter-note kind** — already correct (`Tore.CounterNotes`
  exists; `Opportunity` was renamed long ago). Not touched.
- Any UI/UX redesign of the Capture or Shop surfaces — names only.
