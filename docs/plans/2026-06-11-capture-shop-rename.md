# Capture / Shop Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the Chat surface → Capture and the Groceries surface + its grocery-list aggregate → Shop, aligning code with the SPEC vocabulary. Pure rename + one dead-code deletion; no behaviour change.

**Architecture:** Three independent rename groups committed separately so the suite stays green at each step: (1) Capture side — `Tore.Chat.ChatHandler` → `Tore.Capture.Conversation` (`reply/2`), ChatLive/KioskChatLive → Capture, `/chat` → `/capture`, delete dead `WeekContext`; (2) Shop side — `Tore.Groceries` aggregate + `"grocery_list:"` stream key → `Tore.Shop` / `"shop_list:"`, GroceryLive → ShopLive, `/groceries` → `/shop`; (3) SPEC.md alignment. The `Tore.Handlers.GroceriesHandler` module name and all cross-feature grocery vocabulary (`GroceryDiff`, `:grocery_checkoff`, etc.) are deliberately kept.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit, gettext (sv). No new deps.

**Spec:** `docs/specs/2026-06-11-capture-shop-rename-design.md`

---

## Codebase orientation (verified 2026-06-11)

- **VCS is jj, never git.** Controller commits per task (`jj describe` then `jj new`). Renaming a file in jj = just move/rewrite it; there is no `git mv` staging. Create the new file, delete the old, in the same change.
- **Capture surface refs** (complete list):
  - `lib/tore/chat/chat_handler.ex` — `defmodule Tore.Chat.ChatHandler`, public `handle_text/2`.
  - `lib/tore/chat/week_context.ex` — `defmodule Tore.Chat.WeekContext`, `build/1`. **DEAD** — no `lib/` caller (only its own test). Delete.
  - `lib/tore_web/live/chat_live.ex` — `defmodule ToreWeb.ChatLive`, `alias Tore.Chat.ChatHandler` (line 4), `ChatHandler.handle_text(text)` (line 53).
  - `lib/tore_web/live/kiosk_chat_live.ex` — `defmodule ToreWeb.KioskChatLive`.
  - `lib/tore_web/router.ex` — line 42 `live "/chat", KioskChatLive` (in `scope "/kiosk"`), line 62 `live "/chat", ChatLive` (in main scope).
  - `lib/tore_web/live/kiosk_live.ex:217` — `navigate="/kiosk/chat"`.
  - Tests: `test/tore/chat/chat_handler_test.exs`, `test/tore/chat/week_context_test.exs`, `test/tore_web/live/chat_live_test.exs`, `test/tore_web/live/kiosk_chat_live_test.exs`.
- **Shop aggregate + surface refs** (complete list):
  - `lib/tore/groceries/{decider,events,state,commands,aggregator}.ex` — `defmodule Tore.Groceries.*`; `decider.ex` aliases `Tore.Groceries.{Commands, Events, State}`.
  - `lib/tore/handlers/groceries_handler.ex` — line 2 `alias Tore.{EventStore, Groceries.Decider, Groceries.Commands, Groceries.Aggregator, Pantry}`. **Module name KEPT** (`GroceriesHandler`); only the `Tore.Groceries.*` aliases change to `Tore.Shop.*`.
  - `lib/tore_web/live/grocery_live.ex` — `defmodule ToreWeb.GroceryLive`; `grocery_id/1` (line 315) builds `"grocery_list:#{...}"`; `grocery_row/1` render helper.
  - `lib/tore_web/live/planner_live.ex` — `grocery_id/1` (line 1183) builds `"grocery_list:#{...}"`; `GroceriesHandler.build_list(grocery_id(week_start), ...)` (line 317).
  - `lib/tore_web/router.ex:55` — `live "/groceries", GroceryLive`.
  - `lib/tore_web/components/layouts.ex:14` — `{"/groceries", gettext("Groceries"), "nav-groceries"}`.
  - Tests: `test/tore/groceries/decider_test.exs`, `test/tore/groceries/aggregator_test.exs`, `test/tore/handlers/groceries_handler_test.exs` (refs `Tore.Groceries.Events.*` and `"grocery_list:2026-04-27"`).
  - sv translation: `priv/gettext/sv/LC_MESSAGES/default.po:296` `msgid "Groceries"`.
- **VERIFIED — do NOT touch:** `cost_live.ex`, `cooking_live.ex`, `pantry_live.ex` have **no** `Tore.Groceries`/`GroceriesHandler`/`grocery_id` reference (the spec listed them speculatively; they are clean). The Projector, EventStore, and config.exs have **no** reference to the groceries stream/aggregate (the list is loaded via `EventStore.load(list_id, Decider)` from the handler). `priv/gettext/sv/.../default.po:1700` `"Groceries — this month"` is a **costs** label (cross-feature) — KEEP it.
- **KEEP (cross-feature grocery vocabulary):** `GroceryDiff`, `GroceryVerifier`, `resolve_grocery_item`, `:grocery_reconciliation_run`, `:grocery_checkoff`, `FinishTheShoppingList`, `grocery_items_updated`. These are a different match from the renamed identifiers.

`reply/2` keeps the same signature as `handle_text/2`: `(String.t(), keyword()) :: {:ok, String.t(), nil} | {:error, term()}`.

---

## File Structure

Group 1 (Capture) and Group 2 (Shop) are independent; either could go first. Group 3 (SPEC) is documentation. Each group is one task (one commit). The suite must be green after each.

---

### Task 1: Capture side rename

**Files:**
- Rename: `lib/tore/chat/chat_handler.ex` → `lib/tore/capture/conversation.ex`
- Rename: `lib/tore_web/live/chat_live.ex` → `lib/tore_web/live/capture_live.ex`
- Rename: `lib/tore_web/live/kiosk_chat_live.ex` → `lib/tore_web/live/kiosk_capture_live.ex`
- Delete: `lib/tore/chat/week_context.ex`, `test/tore/chat/week_context_test.exs`
- Rename: `test/tore/chat/chat_handler_test.exs` → `test/tore/capture/conversation_test.exs`
- Modify: `lib/tore_web/router.ex`, `lib/tore_web/live/kiosk_live.ex`
- Rename: `test/tore_web/live/chat_live_test.exs` → `test/tore_web/live/capture_live_test.exs`
- Rename: `test/tore_web/live/kiosk_chat_live_test.exs` → `test/tore_web/live/kiosk_capture_live_test.exs`

- [ ] **Step 1: Capture the baseline**

Run: `mix test test/tore/chat/ test/tore_web/live/chat_live_test.exs test/tore_web/live/kiosk_chat_live_test.exs`
Expected: all PASS. Note the counts — this is the regression net.

- [ ] **Step 2: Create `Tore.Capture.Conversation` and delete the old handler**

Create `lib/tore/capture/conversation.ex` with the exact contents of `lib/tore/chat/chat_handler.ex`, changing only: the module name `Tore.Chat.ChatHandler` → `Tore.Capture.Conversation`, and the public function `handle_text/2` → `reply/2`. Everything else (the `@llm` config, the capsule aliases, `@chat_capsules`, `@role_preamble`, `chat_ctx/0`, `date_line/0`, `generate_correlation_id/0`, the AiOperations logging) is copied verbatim.

> Read `lib/tore/chat/chat_handler.ex` in full first. The only identifier changes are the module name and `handle_text` → `reply`. Do NOT rename `@chat_capsules` or the internal helpers — those are internal names, out of scope (and `chat` there refers to the LLM `chat` callback, not the surface).

Then delete `lib/tore/chat/chat_handler.ex`.

- [ ] **Step 3: Delete the dead WeekContext**

```bash
rm lib/tore/chat/week_context.ex test/tore/chat/week_context_test.exs
```

(`Tore.Chat.WeekContext.build/1` has no `lib/` caller — verified. The `Tore.Chat` namespace is now empty and retired.)

- [ ] **Step 4: Rename ChatLive → CaptureLive**

Create `lib/tore_web/live/capture_live.ex` = the contents of `chat_live.ex` with: `defmodule ToreWeb.ChatLive` → `ToreWeb.CaptureLive`; `alias Tore.Chat.ChatHandler` → `alias Tore.Capture.Conversation`; `ChatHandler.handle_text(text)` → `Conversation.reply(text)`. Delete `lib/tore_web/live/chat_live.ex`.

> Check the template/render inside `chat_live.ex` for any hardcoded `/chat` link or "Chat" title text and update to `/capture` / "Capture" as appropriate (grep the file for `chat` case-insensitively after the rename). Keep user-facing copy minimal — only change what names the surface.

- [ ] **Step 5: Rename KioskChatLive → KioskCaptureLive**

Create `lib/tore_web/live/kiosk_capture_live.ex` = contents of `kiosk_chat_live.ex` with `defmodule ToreWeb.KioskChatLive` → `ToreWeb.KioskCaptureLive` (and any internal `/kiosk/chat` self-reference → `/kiosk/capture`). Delete `kiosk_chat_live.ex`.

- [ ] **Step 6: Update the router and the kiosk nav link**

In `lib/tore_web/router.ex`:
- line 42: `live "/chat", KioskChatLive` → `live "/capture", KioskCaptureLive`
- line 62: `live "/chat", ChatLive` → `live "/capture", CaptureLive`

In `lib/tore_web/live/kiosk_live.ex:217`: `navigate="/kiosk/chat"` → `navigate="/kiosk/capture"`.

> Grep `grep -rn "/kiosk/chat\|\"/chat\"\|navigate=\"/chat\"" lib/` for any other hardcoded link to the old routes (nav bars, buttons, redirects) and update them.

- [ ] **Step 7: Rename and update the tests**

- `test/tore/chat/chat_handler_test.exs` → `test/tore/capture/conversation_test.exs`: module `Tore.Chat.ChatHandlerTest` → `Tore.Capture.ConversationTest`; every `Tore.Chat.ChatHandler.handle_text(...)` → `Tore.Capture.Conversation.reply(...)`.
- `test/tore_web/live/chat_live_test.exs` → `test/tore_web/live/capture_live_test.exs`: module name `ChatLiveTest` → `CaptureLiveTest`; any `live(conn, "/chat")` → `live(conn, "/capture")`; any `ChatLive` reference → `CaptureLive`.
- `test/tore_web/live/kiosk_chat_live_test.exs` → `test/tore_web/live/kiosk_capture_live_test.exs`: same treatment (`/kiosk/chat` → `/kiosk/capture`, module + module-ref renames).

> Read each test file before editing — update assertions that match on the old route/module but DO NOT weaken what they assert.

- [ ] **Step 8: Compile + verify no dangling Capture-side refs**

Run: `mix compile --warnings-as-errors`
Expected: clean.
Run: `grep -rn "Tore.Chat\|ChatHandler\|ChatLive\|KioskChatLive\|WeekContext\|handle_text" lib/ test/`
Expected: **no output**. (If any remains, it's a missed reference — fix it. Note: `@chat_capsules` and the LLM `chat`/`chat_with_tools` callback are NOT matches for these patterns — confirm none of the grep hits are those.)

- [ ] **Step 9: Run the renamed tests**

Run: `mix test test/tore/capture/ test/tore_web/live/capture_live_test.exs test/tore_web/live/kiosk_capture_live_test.exs`
Expected: all PASS, counts matching Step 1 minus the deleted WeekContext tests.

- [ ] **Step 10: Commit**

```bash
jj describe -m "refactor(capture): rename Chat→Capture surface; ChatHandler→Conversation; drop dead WeekContext"
jj new
```

---

### Task 2: Shop side rename (aggregate + surface + stream key)

**Files:**
- Rename: `lib/tore/groceries/{decider,events,state,commands,aggregator}.ex` → `lib/tore/shop/{...}.ex`
- Rename: `lib/tore_web/live/grocery_live.ex` → `lib/tore_web/live/shop_live.ex`
- Modify: `lib/tore/handlers/groceries_handler.ex` (aliases only), `lib/tore_web/live/planner_live.ex`, `lib/tore_web/router.ex`, `lib/tore_web/components/layouts.ex`
- Rename: `test/tore/groceries/decider_test.exs` → `test/tore/shop/decider_test.exs`, `test/tore/groceries/aggregator_test.exs` → `test/tore/shop/aggregator_test.exs`
- Modify: `test/tore/handlers/groceries_handler_test.exs`
- Modify: `priv/gettext/sv/LC_MESSAGES/default.po`

- [ ] **Step 1: Capture the baseline**

Run: `mix test test/tore/groceries/ test/tore/handlers/groceries_handler_test.exs`
Expected: all PASS. Note counts.

- [ ] **Step 2: Rename the aggregate modules `Tore.Groceries.*` → `Tore.Shop.*`**

For each of the 5 files, create the `lib/tore/shop/<name>.ex` equivalent with `defmodule Tore.Groceries.X` → `defmodule Tore.Shop.X` and every internal `Tore.Groceries.` → `Tore.Shop.` (e.g. `decider.ex`'s `alias Tore.Groceries.{Commands, Events, State}` → `alias Tore.Shop.{Commands, Events, State}`). Then delete the old `lib/tore/groceries/` files.

> The directory `lib/tore/groceries/` should end up empty and removed. Only module names and internal aliases change — the decider logic, event structs, and state shape are byte-for-byte otherwise identical.

- [ ] **Step 3: Update GroceriesHandler's aliases (keep its module name)**

In `lib/tore/handlers/groceries_handler.ex` line 2:
`alias Tore.{EventStore, Groceries.Decider, Groceries.Commands, Groceries.Aggregator, Pantry}`
→
`alias Tore.{EventStore, Shop.Decider, Shop.Commands, Shop.Aggregator, Pantry}`

> The module stays `Tore.Handlers.GroceriesHandler` (deferred to the handlers spec). Grep the file body for any other `Groceries.` / `%Tore.Groceries.` reference (e.g. event struct matches) and update those to `Shop.` too. Do NOT rename the module or its functions.

- [ ] **Step 4: Rename GroceryLive → ShopLive + stream key + row helper**

Create `lib/tore_web/live/shop_live.ex` = contents of `grocery_live.ex` with:
- `defmodule ToreWeb.GroceryLive` → `ToreWeb.ShopLive`
- `grocery_id/1` → `shop_id/1`, and its body `"grocery_list:#{...}"` → `"shop_list:#{...}"`
- the `list_id = grocery_id(week_start)` call site → `shop_id(week_start)`
- `grocery_row/1` → `item_row/1` (definition + call sites)
- any `Tore.Groceries.` reference → `Tore.Shop.`
- any hardcoded `/groceries` link or "Groceries" title in the template → `/shop` / "Shop"

Delete `lib/tore_web/live/grocery_live.ex`.

- [ ] **Step 5: Update planner_live.ex (stream key + handler call)**

In `lib/tore_web/live/planner_live.ex`:
- `grocery_id/1` (line ~1183) → `shop_id/1`, body `"grocery_list:#{...}"` → `"shop_list:#{...}"`
- the call site (line ~317) `GroceriesHandler.build_list(grocery_id(week_start), ...)` → `GroceriesHandler.build_list(shop_id(week_start), ...)`

> `GroceriesHandler` stays — only the helper name + key string change. Grep the file for any other `grocery_id`/`grocery_list:`/`Tore.Groceries.` and update.

- [ ] **Step 6: Update the router and nav**

`lib/tore_web/router.ex:55`: `live "/groceries", GroceryLive` → `live "/shop", ShopLive`.

`lib/tore_web/components/layouts.ex:14`: `{"/groceries", gettext("Groceries"), "nav-groceries"}` → `{"/shop", gettext("Shop"), "nav-shop"}`.

> Grep `grep -rn "\"/groceries\"\|GroceryLive\|nav-groceries" lib/` for any other hardcoded nav link/redirect to `/groceries` and update.

- [ ] **Step 7: Add the Swedish translation for "Shop"**

Run `mix gettext.extract && mix gettext.merge priv/gettext` to surface the new `"Shop"` msgid. Then in `priv/gettext/sv/LC_MESSAGES/default.po`, set the Swedish translation for `msgid "Shop"` to `msgstr "Inköp"` (or the project's preferred term — check how the app refers to shopping; "Inköp" = purchases/shopping is the natural Swedish nav label).

> CRITICAL (gettext fuzzy trap): after merge, verify the new `"Shop"` entry is NOT marked `#, fuzzy` — a fuzzy entry is ignored at runtime and renders the English "Shop". If it's fuzzy, remove the `#, fuzzy` line. The test env runs in `sv`, so a test asserting the Swedish label will fail if it's fuzzy. Leave the old `msgid "Groceries"` entry in place (harmless; gettext.merge may mark it obsolete `#~` — that's fine).

- [ ] **Step 8: Rename and update the Shop tests**

- `test/tore/groceries/decider_test.exs` → `test/tore/shop/decider_test.exs`: module `Tore.Groceries.DeciderTest` → `Tore.Shop.DeciderTest`; `alias Tore.Groceries.{Decider, State, Commands, Events}` → `alias Tore.Shop.{...}`.
- `test/tore/groceries/aggregator_test.exs` → `test/tore/shop/aggregator_test.exs`: module + alias renames `Groceries` → `Shop`.
- `test/tore/handlers/groceries_handler_test.exs` (file + module name KEPT — it tests `GroceriesHandler`): update `%Tore.Groceries.Events.ItemAdded{}` / `ItemChecked{}` / `ListBuilt{}` (lines 39/51/79) → `%Tore.Shop.Events.*{}`; update `list_id` helper `"grocery_list:2026-04-27"` (line 20) → `"shop_list:2026-04-27"`.

> Read each test before editing; keep assertions intact, only rename identifiers + the key string.

- [ ] **Step 9: Compile + verify no dangling Shop-aggregate refs**

Run: `mix compile --warnings-as-errors`
Expected: clean (watch for an empty-directory or unused-alias warning).
Run: `grep -rn "Tore.Groceries\|GroceryLive\|grocery_list:\|grocery_id\|grocery_row\|nav-groceries" lib/ test/`
Expected: **no output**. (The KEPT vocabulary — `GroceryDiff`, `GroceriesHandler`, `resolve_grocery_item`, `:grocery_checkoff`, `grocery_items_updated`, the costs `"Groceries — this month"` label — does NOT match these patterns. If a grep hit is one of those, you've over-matched; but these specific patterns shouldn't catch them. Verify each remaining hit.)

- [ ] **Step 10: Run the renamed tests + full suite**

Run: `mix test test/tore/shop/ test/tore/handlers/groceries_handler_test.exs`
Expected: PASS, counts matching Step 1.
Run: `mix test`
Expected: full suite green. (A rare SQLite "Database busy" flake under parallel load is pre-existing, not a regression — re-run if it appears.)

- [ ] **Step 11: Commit**

```bash
jj describe -m "refactor(shop): rename Groceries aggregate+surface→Shop; grocery_list:→shop_list: stream key"
jj new
```

---

### Task 3: Align SPEC.md + CHANGELOG

**Files:**
- Modify: `SPEC.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update SPEC.md line 69**

Find the Shop interface row (≈ line 69):
`| **Shop** | Multi-user real-time grocery checklist (decider stream stays named `groceries`). Granular events enable PubSub sync and natural undo. |`
Change the parenthetical: the stream is now `shop`. New text:
`| **Shop** | Multi-user real-time grocery checklist (decider stream `shop`, formerly `groceries`). Granular events enable PubSub sync and natural undo. |`

- [ ] **Step 2: Update the SPEC.md module map**

In the module map (≈ lines 748-820):
- `groceries/                 # Decider aggregate` → `shop/                      # Decider aggregate`
- `grocery_live.ex            # close loop: check → Pantry.add_item` → `shop_live.ex               # close loop: check → Pantry.add_item`
- `chat_live.ex               # completes fridge → suggestions flow` → `capture_live.ex            # completes fridge → suggestions flow`
- `kiosk_chat_live.ex` → `kiosk_capture_live.ex`

> Leave `groceries_handler.ex` (module kept; handlers spec renames it), `grocery_verifier.ex`, and the `resolve_grocery_item` reference in `resolvers.ex` unchanged — those are kept vocabulary. Do NOT touch `GroceryDiff`, `:grocery_*_run`, `:grocery_checkoff` references elsewhere in the SPEC.

- [ ] **Step 3: Append to CHANGELOG**

Add under `## [Unreleased]`, after the weekly-planning entry:

```markdown
### Capture / Shop vocabulary rename

Aligned code with the SPEC's adopted UI vocabulary.

- `Tore.Chat.ChatHandler` → `Tore.Capture.Conversation` (`handle_text/2` →
  `reply/2`); `ChatLive`/`KioskChatLive` → `CaptureLive`/`KioskCaptureLive`;
  routes `/chat` → `/capture`, `/kiosk/chat` → `/kiosk/capture`. The dead
  `Tore.Chat.WeekContext` (superseded by `WeekPlanCapsule`) is deleted, retiring
  the `Tore.Chat` namespace.
- `Tore.Groceries` aggregate → `Tore.Shop`; `GroceryLive` → `ShopLive`; route
  `/groceries` → `/shop`; stream key `grocery_list:` → `shop_list:`; nav label →
  "Shop"/"Inköp". The grocery-list aggregate and its surface now share one name.
- Kept: `Tore.Handlers.GroceriesHandler` (a Tiger-Style rename of the whole
  handler family is a separate spec) and the cross-feature grocery vocabulary
  (`GroceryDiff`, `GroceryVerifier`, `resolve_grocery_item`,
  `:grocery_reconciliation_run`, `:grocery_checkoff`) — those name the grocery
  domain concept used by other features, not the Shop surface.
- SPEC.md line 69 + module map updated to match (overriding the earlier "stream
  stays named groceries" note; safe pre-production with no persisted events).
```

- [ ] **Step 4: Verify + commit**

Run: `mix compile --warnings-as-errors && mix test` (full suite green; SPEC/CHANGELOG are docs, no code impact).
Run: `mix format` then `jj diff --stat` to confirm only intended files changed.

```bash
jj describe -m "docs: align SPEC + CHANGELOG with Capture/Shop rename"
jj new
```

---

## Notes for the executor

- **jj, never git.** One `jj describe` + `jj new` per task. File "rename" = create new + delete old in the same change. Push to master happens after the whole plan + review via finishing-a-development-branch.
- **Keep vs rename is the crux.** The KEPT list (`GroceriesHandler`, `GroceryDiff`, `:grocery_checkoff`, `resolve_grocery_item`, `:grocery_reconciliation_run`, `grocery_items_updated`, the costs `"Groceries — this month"` label) must survive untouched. The verification greps in each task use patterns narrow enough to exclude them — but eyeball every remaining hit.
- **No behaviour change.** This is a rename. If any test's *assertion* (not its identifiers) needs to change to pass, something is wrong — stop and report; do not weaken assertions.
- **gettext fuzzy trap.** The new "Shop" sv translation must not be `#, fuzzy` (fuzzy = ignored at runtime → renders English; the test env runs in `sv`).
- **Smoke (user-run):** after merge, the user should click through `/capture`, `/kiosk/capture`, `/shop` in the running app to confirm the surfaces render and the nav works. Mox/route tests cover the deterministic parts.
