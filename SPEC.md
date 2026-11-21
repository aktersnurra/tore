# Tore — AI-Native Meal Planner

> *Tore* is a self-hosted family meal planner. The previous incarnation was *Scullion*,
> a competent but conventional CRUD-shaped planner. This document specifies the
> AI-native rewrite. Where this spec disagrees with the codebase, one of them is
> a bug: reconcile deliberately and record the decision in §Status. Neither side
> silently wins.

## Status

- **Source-of-truth date:** 2026-11-19
- **2026-05-31:** Reversed the Family→Household naming. `Tore.Household` is canonical; `Tore.Family.*` deleted.
- **2026-06-02:** Added §Agent Harness Layer. Tore is reframed as a household food-operations harness; every state-changing AI action is a `KitchenRun` producing typed artifacts, verified deterministically, applied atomically. §The Six LLM-Native Features rewritten in harness terms. Future sub-specs implement the harness primitives, verifiers, capsules, risk tiers, resolved references, and Kitchen Skills.
- **2026-06-02:** UI/UX vocabulary adopted. Canonical names: `CounterNote` (artifact and code module — replaces the working name `Opportunity` from the first draft of §A), `Shop` (UI surface and route `/shop` — replaces `Groceries` / `/groceries`), `Capture` (UI surface and route `/capture` — replaces `Chat` / `/chat`), `Tore.Capture` (module namespace — replaces `Tore.Chat`). The code rename is a separate sub-plan; SPEC.md uses the new names throughout from this commit forward.
- **2026-07-03:** Reconciliation pass. Absorbed what the run-receipts slice (`docs/specs/run-receipts.md`) and a month of implementation legitimately decided: the run aggregate is event-sourced (`Tore.Harness.Run`), a seventh `:discarded` terminal state with a weekly TTL sweep, `undo_payload` as a sum type replacing `undo_ref`, the `PantrySnapshot` / `RunBundle` artifacts, and the `:capture_turn_run` parent-run kind. Fixed internal contradictions (SystemPrompt, fridge-rescue tier, weekly planning Pattern A vs B, leftover Chat naming, Quantum jobs bypassing the harness). Made the single-household deployment assumption explicit. Decided: Capture keeps LLM photo classification (`classify_image`) rather than explicit intent chips — considered and rejected the chips.
- **2026-07-12:** §A.6.2 resolved-handles landed for plan slots. Decided: handles carry an opaque `ref` token (not the struct) to the model; the PlannerAgent runtime exchanges refs for real IDs at the action-tool boundary via a per-run registry, and rejects invented/stale refs as a tool error without invoking the tool. Added `:direct_touch` as a `source` value (confidence 1.0 — the user touched the object in the UI, nothing to resolve). Shipped: `resolve_recipe`, direct-touch slot handles from the plan slot sheet's scoped command input. Deferred: `resolve_slot`, `resolve_grocery_item`, `resolve_pantry_item` — until their consumers exist. Slot action-tool params stay structural `slot_key` domain keys by design, not a `ResolvedSlot` ref.
- **2026-08-04:** Anticipation layer landed (plan 3 of 3). `CounterNote` gained a `proposed_run` map column (sum type: `planner_command` | `add_item` | `nil`) and four scan kinds (`swap_suggestion`, `freezer_fallback`, `missing_ingredient`, `usual_item_missing`); `CounterNoteVerifier` checks every scan proposal before it is materialized. A new `:ambient_scan_run` (Tier 0, `started_by: "system"`) predicts at most one actionable note per surface daily at 05:00 and after a 5-minute-debounced plan/shop mutation, gated by SpendGuard `:ambient_scan {8_000, 600}`; `CounterNotes.recently_ignored/1` feeds dismissed notes back into the next scan prompt so the model does not re-propose them. `CounterNotes.follow_up/2` is the single accept-with-effect path: `add_item` applies directly (no LLM), `planner_command` dispatches `:planner_command_run` with `started_by: "counter_note_followup"` and Plan 2's `scoped_slot` machinery. Home hero, the Plan slot sheet, the Shop add-field, and the Capture tray's half state all render these notes as one-tap predictions per Rule 1 (replace generic affordances, never add elements) — never awaited on page load (Rule 2). §A.6.2: `resolve_slot` shipped as a pure, deterministic resolver — see below. Also shipped: long-press object sheets on the tonight card (scoped to today) and grocery rows (scoped via a `Capture.Router` text referent, since no grocery action tools exist yet to consume a handle).
- **2026-09-06:** Recipe proposals landed (plan 4). The planner can find recipe pages on the web (`find_recipe_web`), import one (`import_recipe_from_web`) or adapt a catalog recipe (`generate_recipe_variant`). Each ends the loop with a `RecipeProposal` that `RecipeProposalVerifier` checks, parked in `:needs_user` until a person saves or discards it on the run review page. The hand-rolled OpenRouter transport was replaced by the `open_router` library.
- **2026-11-06:** Trim. New core rule: the upkeep test (§Core Philosophy). Removed the kiosk and device tokens, counter notes, `/inbox`, the `/deals` page, the Saturday prep job, and the unbuilt run kinds `:deal_capture_run`, `:grocery_reconciliation_run`, `:prep_generation_run` and `:recipe_generation_run`. `:fridge_rescue_run` was never built either: the Capture tool that replies with suggestions is all there is. Receipts now record cost only and never touch the pantry, because a misread line would drop an item off the shopping list. Shelf photos apply straight away with undo and replace quantities. Added shelf life, stores added by link with a parser per chain, one cost page, and eating out as a meal state. The household's language is chosen once at setup and then locked. §The Six LLM-Native Features became §Features, with a status on each. The anticipation layer waits for Plan 3's rewrite (§3).
- **2026-11-08:** The trim was rebased onto plans 3 and 4, which it had not been based on. Cut by the owner: the ambient scan, `CounterNote`s, `CounterNoteVerifier`, the debouncer and the 05:00 scan. Kept from plan 3: the long-press object sheets and `resolve_slot`. Plan 4 stays whole.
- **2026-11-08:** Pocket ID is the only login. Removed the 16-digit codes, the setup page, roles, the rate limiter and `argon2`. Pocket ID decides who may sign in through the groups on its client, and a `tore_ai` claim marks who may use the server's LLM. Settings lists members and has "Sign out". `docs/UI_SPEC.md` became `docs/specs/ui.md`, and `docs/LLM-NATIVE-FEATURES.md` became `docs/specs/llm-native-features.md`.
- **2026-11-09:** Several households share one server (`.docs/specs/households.md`). Every function that reads or writes a household's data takes a `%Tore.Scope{}` first, and `Tore.Repo` raises on a household table queried without one. People belong to households through memberships, one active at a time; a first sign-in either joins the households that added that username or starts a household of its own, whose language is picked once at `/welcome`. Stores are shared and fetched once; deals are the only data that crosses households. `Tore.LLM` is the gate for LLM calls (image generation still calls OpenRouter directly, after a gated call): a household needs a sponsor with the `tore_ai` claim, the server needs an OpenRouter key (now optional), and each household has its own monthly limit. A friend's own OpenRouter key is a non-goal, so it left the backlog.
- **2026-11-10:** Run core (`.docs/specs/run-core.md`) and household memory (`.docs/specs/household-memory.md`). A `runs` table (`Tore.Harness.KitchenRun`) replaces the event-sourced run aggregate, its Projector, `UndoPayload` and `RunReceipts`. A kind of run is a plain behaviour (`Tore.Harness.Kind`) that `Tore.Harness.Runs` drives, and undo is a list of steps captured when the run applies. `PantrySnapshot`, `RunBundle`, `RunSummary`, `MemoryUpdate`, `:capture_turn_run` and `:kitchen_memory_synthesis_run` are gone. Household memory, a bounded profile and notes the household shares, replaces insight synthesis. All of Capture's writes now go through runs, which closes the gap §A.2 recorded on 2026-11-06, and Capture gained a `memory` tool. Then a simplification pass, by the owner's rule: keep the data model simple, and give the agent plain tools instead of building machinery for rare cases. An eating-out day's place and amount live on the plan, and the `dining_out` table is gone. Undoing a check-off leaves its pantry addition. The database holds one pantry row per ingredient. Capture deletes recipes, receipts and shopping items directly, with no review or undo. Undo puts things back as they were before the run, even over a later change.
- **Supersedes:** the original Scullion SPEC.md (2026-05-02), now archived in git history at commit `af0ad48`.
- **Companion docs:** `docs/specs/llm-native-features.md` (the design brief this spec absorbs), `docs/specs/ui.md` (UI/UX contract — meets this spec at the artifact boundary), `docs/specs/run-receipts.md` (the first vertical slice of the harness: receipts, diffs, undo; its run model is superseded by run core, §A.2). Per-feature design notes live under `docs/specs/`.
- **Naming:** the project is *Tore*. Any remaining reference to Scullion or Family in code is legacy and slated for deletion (see §Removed in Rewrite).
- **2026-11-11:** The app opens where the household needs it. A decision model (Jev, a fourth model tier, §A.8, Pattern C) picks the screen `/` opens on and the quick swaps above a chat box that sits at the bottom of every screen, with a ≡ menu in place of the navigation bars (§Interfaces). The pick is the latest applied `:home_pick_run`; a fixed rule picks without AI. Capture can suggest its own swaps with a `quick_swaps` tool.
- **2026-11-15:** Fewer screens, and a tab bar. Today · Plan · Tore · Shop · Recipes replaces the chat bar and its ≡ menu; Tore, in the middle, opens Capture over the current screen, and the quick swaps live there now. Recipes are saved straight away with undo, so the review page (`/review`, `/runs/:id`) is gone (§A.6.1). Spending moved under the shopping list, diet and allergies into Settings, and the pantry and costs pages and `/cooking` were removed. The palette is Gjutjärn and Dagsljus (docs/specs/ui.md §4).
- **2026-11-19:** Cooking, start to finish. Before cooking, what isn't at home is asked about once (`ToreWeb.BeforeCooking`, `Tore.Recipes.Swaps`); Done in cook mode uses up what the dinner took (`Tore.Pantry.use_up/2`); Today then shows tomorrow, and the home pick also chooses Today's one note (§Interfaces).
- **2026-11-19:** Meals put together from parts (`.docs/specs/meal-parts.md`). `recipe_parts` links a dinner to other recipes, in order; `Tore.Recipes.get!/2` and `get_many/2` give it its parts and their ingredients, scaled to its servings and added up, so the rest of the app sees one dinner. Its cooking order is written by cook mode's step writer from the parts' steps the first time it's cooked, and cleared when a part changes. Made from Sätt ihop on Recipes or `put_together` over MCP; the in-app chat gets it with the pi work.
- **2026-11-17:** Pages, collections and the research's eight fixes (`.docs/plans/notion-feel.md`). A recipe is a page with property rows and belongs to a collection: dinner, baking, sauces & sides, or assemblies (`recipe_type` `:meal | :baking | :component | :assembly`; imports classify it). Only dinners are planned or suggested for a day. Every recipe's picture is generated in one house style (`Tore.LLM.Prompts.food_photo/1`); a page's own photo is fetched only for MCP saves. Today's "Something else" offers three dinners to choose between, with Undo; Plan can plan the open days in one tap; Shop has one add field that reads "2 l mjölk", Make the list, and says which dinner each item is for. Capture gained `can_i_make` (a dish against the pantry), and a recipe page shows the same check as "At home". Cook mode has step timers and takes the servings chosen on the page; a hand-written recipe's steps are written when it's saved.
- **2026-11-19:** All AI goes through pi (`.docs/plans/all-ai-through-pi.md`). pi (`pi --mode rpc`, `Tore.Pi`) is Tore's agent: each person has a chat session, which the chat tray and the Plan, Today and Shop sheets ask, and the `plan_week` and `weekly_reflection` background jobs are task files it runs (`Tore.Agent`). It acts only through Tore's `/mcp` tools, so every write is still a run with its verifier and undo. Every one-off model call in `Tore.LLM` is a pi one-shot (`Tore.LLM.Pi`). pi reads photos itself: a shelf or fridge goes into the pantry with `add_to_pantry` (`seen`), and a recipe is saved with `save_recipe`. Deleted: Capture's router, `PlannerAgent` and its tools, `:planner_command_run`, `:weekly_planning_run`, `:memory_review_run`, `PlanDiffBuilder`, resolver handles, capsule composition (two capsules are left as structs `get_context` and the home pick read), the fridge suggestion tools, per-turn quick swaps, Tore's shelf and recipe photo readers, and the OpenRouter model client with `web_search`, `chat` and `chat_with_tools`. OpenRouter now only draws recipe pictures.
- **2026-11-19 (later):** Strict MCP: Tore writes no prompts. Every AI task is pi working through `/mcp`, and Tore's one-shots are gone with `Tore.LLM`, `Tore.LLM.Pi`, `Tore.LLM.Prompts`, `harness/ONESHOT.md`, `Tore.SpendGuard` and `Tore.MockLLM`. A link on the Recipes screen, a receipt photo on Shop and Check in the sheet before cooking ask the person's chat (the swaps come back with `suggest_swaps`). A saved or changed recipe gets its steps and picture from a `finish_recipe` job (`update_recipe`, `draw_recipe_picture`). The prep guide is a `prep_guide` job (`save_prep_guide`). New names and products are a `learn` job (`list_ingredients`, `learn_ingredients`, `match_products`), price guesses are part of `plan_week` (`set_price_guesses`), and the home pick is a `home_pick` job (`set_home_pick`). `find_recipes` runs every Thursday. Deleted: the recipe page parser, Tore's receipt reader and `uploaded_images`, typed decisions (Pattern C), "Surprise me" on a day, and recipe variants. The gate and the refusal words are `Tore.Pi`'s.
- **2026-11-20:** A recipe has its own chat per person (`chat-<user_id>-recipe-<id>`): Ask Tore on a recipe page opens it, and coming back to the recipe comes back to the conversation.
- **2026-11-20:** Jev (`typesafe/jev-1.14`, OpenRouter's Decisions API, `Tore.Jev`) guesses which offers a household wants: after each morning's fetch and when a store is added, `Tore.Deals.Picks` asks a `choice` question per new offer (`usual`, `maybe` or `no`), with what Tore knows of the household as its state, and keeps the answer and its confidence per household (`deal_picks`). On Erbjudanden `usual` joins the basics, `maybe` is its own group, and a sure `no` is folded at the foot. Jev is the one model Tore calls itself besides the picture model, an agreed exception to all AI going through pi; it needs the same sponsor and monthly limit, and logs its cost as `deal_picks`.
- **2026-11-20:** A person has several chats (`Tore.Chats`, the `chats` table: a card of title, summary and tags, and when it was last used; pi keeps what was said). Each is a pi session `chat-<user_id>-<chat_id>`; the screens ask in a session of their own, none of the chats (`Tore.Pi.screen_session/1`). pi writes a chat's card after its first answer and when the talk moves on (`describe_chat`; its title only while the chat has none) and ends each answer with `suggest_replies`, shown as buttons and not saved. A pi session token now says which session it is (`Tore.Scope.pi_session`), so a tool can tell a chat from a background job. Finding a chat again searches the cards (`Tore.Chats.search/3`, words scored in title, tags and summary): in the tray's list, and when someone asks pi in a new chat for an earlier one, pi uses `find_chats` and `open_chat`, which switches the tray there and drops the lookup chat if it has no card.
- **2026-11-20:** Offers are fetched every morning (`Tore.Deals.scrape_all/0` at 07:00), not only Friday to Sunday; `Tore.WeekAhead` only plans. An ICA store's own page is accepted as its offers link.

---

## Core Philosophy

Three sentences govern every decision in this spec:

1. **The system has a good guess and makes it easy to say yes or make a small correction.** The LLM does the work. The user approves, ignores, or nudges.
2. **The system should be more wrong about your kitchen and more right about your life.** Pantry counts will drift. Receipt scans will be skipped. But the system can learn that you skip Thursdays, that fish on weekdays doesn't stick, and that ICA has pork on sale — and that's the value.
3. **Does it change what Tore does next, without the household having to maintain it?** This is the upkeep test, and every feature has to pass it. Tore stays advanced: predictive, learning, doing the work unprompted. What goes is a report nobody acts on, a chore, or code nothing can reach.

Derived rules:

- **Skipping is first-class and neutral.** One tap. No "why?", no cascade warning. The plan is a proposal, not a contract.
- **No nagging.** No notifications about logging, no streaks, no reminders. The app is ready when you come to it.
- **The grocery list is the reliability anchor.** It works even if everything else is chaos. Manual add always works.
- **Trust the user's choices.** When the user overrides a suggestion, the app does not ask why. It notes the event and moves on.
- **Surface, never push.** Proactive intelligence appears in the UI when you open the app. It never sends a notification.

---

## One Interface, One Backend

```
┌──────────────────────┐         ┌──────────────────────────────────┐
│  Phone / laptop      │         │  VPS                             │
│  Browser ──────────────HTTPS──▶  Phoenix + LiveView               │
│  Pocket ID sign-in   │         │  Ecto + SQLite                   │
└──────────────────────┘         │  pi (every model call)           │
                                 │  OpenRouter (pictures, Jev)      │
                                 │  Garage (S3) for images          │
                                 │  Quantum scheduler               │
                                 │  EventStore (planning, groceries)│
                                 └──────────────────────────────────┘
```

All logic runs on the server.

---

## Pattern Strategy

Two aggregates are event-sourced via the Decider pattern. Everything else is Ecto CRUD
behind a context boundary. LiveViews call context APIs only; the context modules orchestrate IO.

### Event-sourced

| Aggregate     | Why                                                                |
|---------------|--------------------------------------------------------------------|
| **Planning**  | LLM-orchestrated workflow with frequent user tweaks. Its events are what the weekly reflection learns from (§1). |
| **Shop** | Multi-user real-time grocery checklist (decider streams `shop_list:<household>:<monday>` from `Tore.Streams`, formerly `groceries`). Granular events enable PubSub sync and natural undo. |

### CRUD

| Context       | Role                                                              |
|---------------|-------------------------------------------------------------------|
| **Accounts**  | Users, sessions, per-user prefs.                                  |
| **Household** | Shared household-level state (preferences, memory, members). |
| **Recipes**   | Reference catalog.                                                |
| **Deals**     | Scraped weekly from stores added by link; ended ones kept half a year as price history. |
| **Pantry**    | Approximate inventory. **No primary management UI.** See §Pantry. |
| **Costs**     | Receipts, for cost tracking; eating out is read from the plan (§7). Reached from Settings and the menu. |
| **Runs** (`Tore.Harness.Runs`) | One `runs` row per `KitchenRun`, moved through its steps by pure transitions (§A.2). Replaced an event-sourced run aggregate on 2026-11-10. |
| **Prep**      | LLM-generated text guides, on demand. Optional. Read-only.        |

---

## Agent Harness Layer

### A.1 — Tore is a household food-operations harness

Tore is not a chatbot over meal-planning data. Tore is a small, tasteful harness
around the household food loop.

A coding agent feels powerful because it doesn't just answer — it runs a bounded
operation, produces a diff, verifies it, and lets you accept or reject. The model
is one component of a larger scaffold: typed context, permissioned tools,
structured prompts, execution traces, verification, and reversible state. The
harness is what turns "chat with file access" into something a careful engineer
will trust.

Tore applies the same shape to food. Every non-trivial AI action is a bounded
run with a typed input snapshot, declared context, permissioned tools, generated
artifacts, deterministic verification, and a clean reversible diff. The LLM
proposes. The harness verifies. The user sees a quiet, tasteful receipt — not a
transcript.

The rest of this section names the parts of that harness: runs, artifacts,
context, verifiers, risk tiers, references, skills, inspectability, and
model routing. Every built feature in §Features below is then
described as a kind of run.

### A.2 — The unit is a `KitchenRun`

Every non-trivial AI action in Tore is a `KitchenRun`. A run is the food
equivalent of an agentic coding session: a bounded operation with a typed
beginning, a verified middle, and a reversible end.

`KitchenRun` is both the concept and the code: `Tore.Harness.KitchenRun` is one row
in the `runs` table, and `Tore.Harness.Runs` moves it through its steps. A kind of run
is a module implementing the `Tore.Harness.Kind` behaviour.

**Fields** (columns on `runs`):

- `id`: `"run-<base64>"`, which keeps `/runs/:id` links
- `household_id`, `user_id`
- `kind`: the kind's name, such as `"plan_edit_run"` (see §Features)
- `actor`: `:user | :system | :mcp`
- `surface`: `:today | :plan | :shop | nil`, declared by the kind
- `status`: `:running | :needs_user | :applied | :failed | :reverted | :discarded`
- `phase`: while `:running`, one of `:gathering_context | :proposing | :verifying`. Drives the UI's thinking-state strip (docs/specs/ui.md §7.2): *"Checking the week…", "Verifying changes…"*
- `input`: the JSON the run started with, string keys only
- `artifacts`: the typed `RunArtifact`s (see §A.3). A run waiting for review stores its proposal here
- `question`: what a `:needs_user` run asks
- `failure_code`, `repair_action`: why a run failed and what the person can do (§A.5). A `failure_message` column exists, but nothing writes it yet
- `discard_reason`: `:user_discarded | :ttl_expired`
- `undo`: set when the run applies, either `{:steps, [step]}` or `{:irreversible, reason}`
- `opened_at`, `applied_at`, `reverted_at`, `closed_at`

CHECK constraints tie the columns to the status: an applied run has `applied_at` and
`undo`, a failed one a `failure_code`, a `:needs_user` one a `question`. A run holds no
LLM usage: each call's cost is in `llm_usage`, under its feature (§LLM Surface).

**Steps.** A kind says what each step means for it:

| Step | May do | May not do |
|---|---|---|
| `propose` | reads | write domain state |
| `resolve` | reads (for example matching pantry names to ingredients) | write domain state |
| `verify` | nothing: a pure check | any effect |
| `apply_proposal` | database writes, in one transaction with the status change | HTTP, storage |
| `after_commit` | best-effort effects, such as broadcasting or making a recipe's picture | |

`Runs.start/3` runs every step. `Runs.submit/4` takes a ready proposal and skips
`propose`: every MCP write uses it, pi's and someone's own Claude's. `ctx[:actor]`, when given, overrides the
kind's actor, so an MCP write is marked `:mcp`. A kind's `review_question/1`
says whether a person must look first. If so, the run waits in `:needs_user` with its
proposal, and `Runs.confirm/3` verifies the edited proposal again before applying it.
`apply_proposal` may return `{:fail, code, repair}` when a check no longer holds inside
the transaction, which fails the run as a verifier would.

**Status transitions** (`Tore.Harness.KitchenRun.Transition`, pure):

| From | Action | To |
|---|---|---|
| `running` | `phase` | `running` |
| `running` | `ask`, `review` | `needs_user` |
| `running` | `apply` | `applied` |
| `running` | `fail` | `failed` |
| `needs_user` | `confirm` | `applied` |
| `needs_user` | `discard` | `discarded` |
| `applied` | `revert` | `reverted` |

Anything else is an error. `failed`, `reverted` and `discarded` are terminal. A failed
`confirm` leaves the run in `needs_user`, so the person can correct the card. An
irreversible run refuses `revert`.

A `:needs_user` run nobody answers is discarded by the person or by the weekly sweep
(`Tore.Harness.InboxSweeper`). Nothing was applied, so there is nothing to revert. Tore
runs on one BEAM node, so at boot every `running` row is dead, and
`Runs.fail_interrupted/0` fails it with `:interrupted`.

**Undo.** `apply_proposal` captures the before-image of what it touches, so the undo is
known when the run applies. The steps are `restore_plan_slots` (each touched slot and
pin, put back by appending planning events), `restore_pantry_item`, `restore_memory`,
`delete_receipt`, `delete_recipe`, `remove_shop_item` and `uncheck_shop_item`. Revert
runs them last first, in one transaction with the status change. An unknown step raises
and rolls back. Undo puts back what was there before the run, even over a later change;
it doesn't detect a stale undo. A delete or shop step whose target is already gone
counts as done. Building the shopping list is irreversible, since it replaces the list.

`{:run_changed, %KitchenRun{}}` is broadcast on `runs:household:<id>` after each commit.
Screens match on `status`.

**Hard rules.**

- Only a `KitchenRun` may write household state on the AI's behalf. pi (through `/mcp`), the crons and the screens all go through `Runs`.
- Every kind has a verifier: `verify` is a required callback.
- Two exceptions write directly, by decision. `mark_recipe_cooked` sets one timestamp. The delete tools (`delete_recipe`, `delete_receipt`, `remove_from_list`) do what the person asked for by name, so they get no review, receipt or undo (2026-11-10). A person tapping in a screen also writes directly.

### A.3 — Runs produce `RunArtifact`s, not chat output

A `KitchenRun` does not produce a conversational reply. It produces one or
more `RunArtifact`s — typed, renderable objects with a compact summary and an
inspectable detail view. Artifacts are the contract between the harness and
the UI: the harness emits them, the UI surfaces them, and neither side knows
how the other implements its half.

**Artifact kinds:**

| Kind | Produced by | Carries |
|---|---|---|
| `PlanDiff` | `:set_plan_slot_run`, `:plan_edit_run` | Per-slot changes with the recipe before and after, and the planning events to append |
| `RecipeProposal` | `:recipe_ingestion_run`, for a recipe pi read from a link, a page or photos and saved (`save_recipe`) | A recipe to save, with its source and steps |
| `RecipeEdit` | `:recipe_edit_run`, for a recipe pi changed (`update_recipe`) or drew a picture for (`draw_recipe_picture`) | The recipe's new fields or picture; undo restores the recipe as it was |
| `PantryBeliefUpdate` | `:pantry_belief_update_run` | Items added or removed, each with `provenance` |
| `CostEntry` | `:receipt_ingestion_run` | Parsed receipt: store, date, total, line items |
| `MemoryBatch` | `:memory_update_run` | Add, patch and remove operations on one part of the household's memory (§1) |
| `ShopChange` | `:shop_edit_run` | An item added or checked off, or the week's list built |
| `HomePick` | `:home_pick_run` | The screen the app opens on and the quick swaps, as pi set them with `set_home_pick` |

A proposal is a registered artifact or a list of them.

**Rendering.** The UI reads artifacts and status, never a run's internals. The chat
shows each run pi starts as one short line built from the tool's result, with Undo.

**No chat transcripts in artifacts.** The LLM's prose is never an artifact.

**Hard rule.** An applied run carries the artifacts of what it changed, and a run that
changed nothing carries none. A run waiting on a question carries no proposal.

### A.4 — Context from tools, not one big prompt

The pre-harness code assembled one big system prompt via
`Tore.Chat.SystemPrompt.build/0` — household preferences, active insights,
week context, and approximate pantry, all glued together. That builder is a
junk drawer by construction: every new feature adds another paragraph, every
prompt gets longer, and no caller can tell which inputs actually drove a
model's behaviour. It has been deleted; the rules below keep it deleted.

pi reads the household through Tore's MCP read tools, when it needs to. `get_context` comes
first: the language, today, diet and allergies, the memory, the week's mode, this and next week's
dinners with each week's budget against its estimate, the basics, the list, the pantry and what's
due. `get_planning_history`, `search_recipes`, `get_recipe`, `list_receipts` and `list_deals`
give the rest. `harness/AGENTS.md` says how Tore works; a background job's task file says what to
do, and the job's details (which recipe, which week, the home pick's facts) follow it.

Two typed structs are left from the capsule design, built once and read by more than one caller:
`WeekPlanCapsule` (the week's slots) and `PantryBeliefsCapsule` (usable pantry names, what to use
soon first). `get_context` and the home pick's facts (`Tore.Home`) read them.

**Hard rules.**

- No shared prompt builder, and no prompt in Tore's code: what pi is asked is a task file, a
  screen's one-line request, or what the person typed.
- What pi knows about the household comes from a tool call, so a run's context is the tools it called.

### A.5 — Verifiers run after every state-changing run

A coding agent earns trust by running tests. Tore's harness earns trust the
same way: every state-changing `KitchenRun` is checked by a deterministic
verifier before anything it proposes is written. The LLM proposes. The
verifier decides if the proposal can actually land. The user sees a clean,
validated result — never a half-applied edit.

Verifiers are pure code, not LLM calls. They read the run's proposal and
the current state of what it would change, and
return either `:ok` or a structured `:fail` reason. They do not call models,
do not have side effects, and are cheap to run inline at the end of every
run.

**Verifier catalog (V1):**

| Verifier | Owns | Checks |
|---|---|---|
| `PlanVerifier` | `PlanDiff` | No locked/pinned slot was changed; every assigned recipe has servings; leftover slots point to a valid source meal earlier in the week; skipped slots are explicit, not missing; no banned ingredient or dietary constraint is violated; no recipe appears twice within the household's configured repeat window |
| `PantryVerifier` | `PantryBeliefUpdate` | Provenance is set on every item write; no negative quantities; `last_seen_at` is monotonic per item |
| `RecipeProposalVerifier` | `RecipeProposal` | Title, ingredients (≥1), and instructions are present; servings is positive; no near-duplicate of an existing catalog recipe (title + ingredient overlap heuristic); no ingredient name is empty |
| `CostEntryVerifier` | `CostEntry` | Store, date, total are present; date is not in the future |
| `Tore.Household.Memory.Ops` | `MemoryBatch` | Each operation fits the current entries (exactly one match for a patch or remove, no duplicate add); the part stays within its size limit; no content that is an instruction, a credential, hidden characters, an internal id or an allergy. A batch applies whole or not at all |

Kinds with no LLM step check less. `:plan_edit_run` refuses a change to a pinned day,
and `:shop_edit_run` accepts every change, since what it writes is what the person said.

**Verifier lifecycle.** After `propose` and `resolve`, `Runs` calls the kind's
`verify`, and one of three things happens:

- **Pass.** `apply_proposal` writes, and the run becomes `:applied` in the same transaction.
- **Fail.** Nothing is written. The run becomes `:failed` with a structured `failure_code` (e.g. `:slot_pinned`, `:near_duplicate`, `:dietary_violation`) and a `repair_action`. Screens turn the code into a sentence. The surface shows a compact repair state with a dismiss option. *Example: "Tuesday dinner is pinned, so nothing was changed."* (An ambiguous reference like "the salmon" matching two recipes is **not** a verifier failure: pi asks the person, §A.6.2. Verifiers catch proposals that cannot land.)
- **Review.** When the kind's `review_question/1` asks, the run waits in `:needs_user` with its proposal, and `verify` runs again on the edited proposal when the person confirms.

**No partial applies.** A verifier failure is atomic — nothing commits. This
is the load-bearing rule. The run is either fully applied or not applied;
the user is never asked to clean up a half-edited week.

**Concurrency and drift.** Runs hold no locks and never block a person's direct
edits. When `apply_proposal` finds, inside its transaction, that a check no longer
holds (a memory entry changed since `verify`), it returns `{:fail, code, repair}` and
the run fails with nothing written. Revert doesn't re-check: undo restores the
before-image, even over a later edit (§A.2).

**No model retry on verifier failure.** When verification fails, the harness
does not silently re-run the LLM with the verifier reason in the prompt.
That path is tempting (cheap retry, often fixes the failure) but it hides
bugs and produces non-deterministic spend. The repair state is surfaced to
the user; they decide whether to retry.

A refusal still reaches pi, as a tool error saying why (`Not saved: near_duplicate.`), and
pi decides what to tell the person or how to fix its call. For memory that is the point: its check
is about wording the model can fix, not about state the household owns (§1).

**Hard rules.**

- Every run kind implements `verify`. A kind whose proposal comes from the LLM checks it against a verifier in this table; a kind that only writes what the person said may check less (above).
- Verifiers run in Tore, never in the model. Tore never retries a model on a failure; pi reads the refusal and chooses (above).
- Verifier failures are stored on the `KitchenRun` row for later inspection; a verifier that fails 20% of the time across runs is a signal to fix the tool, the prompt, or the verifier — not to retry harder.

### A.6 — Risk tiers, references, and Kitchen Skills

#### A.6.1 — Risk tiers

Every `KitchenRun` kind is classified into one of four tiers. The tier
determines whether the harness auto-applies, surfaces for inspection, or
requires explicit confirmation before anything is written.

| Tier | Examples | Apply policy |
|---|---|---|
| **Tier 0 — Surface only** | `:home_pick_run`; what pi suggests in words | They write no domain state. The home pick is a run only so its pick is stored, and its undo is empty. Acting on a suggestion is a separate request. |
| **Tier 1 — Reversible domain edits** | `:set_plan_slot_run`, `:plan_edit_run`, `:shop_edit_run`, `:pantry_belief_update_run`, `:memory_update_run` | Auto-apply after verifier passes. The run receipt is visible. Undo is one tap. |
| **Tier 2 — Reversible ingestion** | `:receipt_ingestion_run`, `:recipe_ingestion_run` | Applies straight away with undo. The chat shows what was saved, with Undo. |
| **Tier 3 — Destructive or sensitive** | Bulk operations like *clear the week*; any change touching dietary constraints or allergens | Never auto-applies. Proposal is produced; commit requires explicit user confirmation. |

A kind decides whether to ask for review from its proposal alone, in
`review_question/1`:

- **Recipes** never wait (since 2026-11-15, when the review screen was removed). A recipe from a link, or one pi saves, is saved once `RecipeProposalVerifier` passes, and undo deletes it.
- **Receipts** never wait. A readable receipt applies straight away with undo, and one without a store, date or total fails.

What pi sees on a shelf or fridge photo is Tier 1 and applies straight away, since one misread item is one tap to fix.

**Hard rules.**

- Review is decided by the kind's code from the proposal, never by the model. The model cannot escalate or de-escalate.
- Tier 3 is the only tier with a confirm modal. Tiers 0, 1 and 2 use act-then-undo. The UI never asks "are you sure?" for Tier 1 or 2.
- A run that touches household preferences (diet, allergies) is Tier 3 regardless of its declared kind.

#### A.6.2 — References

pi names things by what Tore's read tools gave it: a recipe by the `recipe_id` from
`search_recipes` or `get_context`, a day by its ISO date, a shopping or pantry item by name. Every
lookup goes through the household's scope, so an id from another household is not found, and the
verifiers check what the write would do. A sheet on a screen adds a line naming what was touched
(*"From the Plan screen, about the dinner on Tuesday 2026-11-24: …"*), so the person doesn't have
to say which day or item.

When a reference could mean more than one thing, pi asks the person rather than guess
(`harness/AGENTS.md`: ask only when you truly can't choose). A background job has nobody to ask,
so it makes the sensible choice and says what it chose.

**Hard rule.** A write tool finds what it changes through the household's scope. It never trusts an
id because the model sent it.

#### A.6.3 — Kitchen Skills

**Status: planned, nothing built.** Each skill has to pass the upkeep test when it's picked up.

A Kitchen Skill is a reusable agent runbook: a task file in `harness/tasks/` that pi runs as a
background job (`Tore.Agent`), as `plan_week` and `weekly_reflection` already are. Skills are how
the user would invoke a higher-order operation without typing a free-text command.

Each skill is a small typed declaration. The skill catalog is the V1 surface
of the harness for ordinary household operations.

**V1 skill catalog:**

| Skill | Would run | Purpose |
|---|---|---|
| `PlanMyWeek` | the `plan_week` task | Generate the upcoming week from current pantry, deals, memory, and past affinity |
| `UseTheDeals` | `plan_week`, deal-weighted | Re-plan the week prioritising current active deals |
| `LowEnergyWeek` | `plan_week` in the `low_effort` week mode | Plan a week of short-cook recipes with cascading leftovers |
| `StretchLeftovers` | a task of its own | Re-arrange the current week to maximise leftover cascades |
| `LearnFromThisWeek` | the `weekly_reflection` task | Reflect on the week out of schedule, from recent events |

What a skill declares beyond its task file (`trigger`, `surface`) lives in a future Skills
sub-spec. The umbrella names the concept
and the V1 list only.

**Surface rule.** Skills appear in the UI as small contextual action chips
on the surfaces where they are relevant (e.g. `PlanMyWeek` on Plan). There is no global "skills" management screen.

**Hard rule.** A skill is just a task file. It is not a separate primitive, and it writes through
the same MCP tools and runs as everything else. Removing a skill is removing a
row from the catalog, not a refactor.

### A.7 — Inspectability

Every `RunArtifact` produced by a `KitchenRun` carries enough information
for the user to ask *why this?* and get a concrete answer. Inspectability is
not a separate logging or telemetry layer — it is a contract on the artifact
shape.

**Each artifact field that drove a user-visible decision must carry its
rationale inline.**

Examples:

- A `PlanDiff` slot change carries a `rationale` field: `"Pork on sale at ICA · matches a high-affinity recipe · Tuesday has no prep dependency"`.
- A `PantryBeliefUpdate` carries `provenance` per item: `grocery_checkoff`, `vision` (a shelf photo) or `manual`.

Rationale strings are produced by the run, not by the LLM at render time.
They reflect what actually drove the decision: the context the model
read, the deals it weighted, the memory it drew on. A rationale that says
only *"the model picked it"* is a harness bug.

**UI contract.** The surface always renders the artifact's summary form by
default. The rationale and evidence are revealed on a deliberate inspect
gesture. The harness guarantees the data is there; UI/UX spec decides the
affordance.

**Hard rules.**

- Every artifact field that surfaces a decision carries a rationale or provenance.
- Rationales are short and concrete — not paragraphs, not LLM prose. The verifier owning the artifact checks rationale presence as part of artifact validity.
- A run that produces an artifact with empty rationales fails its verifier. There is no "the model didn't explain" fallback.

**Known gap (2026-11-10).** The verifiers don't check rationale presence: `is_rationale_complete/1` had no caller after run core and was removed.

### A.8 — Model routing

Every model call goes through pi (`pi --mode rpc`, `Tore.Pi`), started per household session by
`harness/pi-session`. Tore has no model client and writes no prompts; only recipe pictures are
drawn by an image model (MAI-Image-2.6, `OPENROUTER_IMAGE_MODEL`) through OpenRouter (`Tore.ImageGen`), when pi calls `draw_recipe_picture`
with its own description of the dish. There are two ways in, both an agent session with Tore's
`/mcp` tools and the web, under `harness/AGENTS.md`:

| Way | Used for | Session |
|---|---|---|
| **The chat** | What the person types, and the screens that ask it: a day's sheet and "Plan the open days" on Plan, Today, Shop's sheets and its receipt photo, a link on Recipes (`ToreWeb.PiReply`), and Check in the sheet before cooking (`ToreWeb.BeforeCooking`). A screen's request starts "From the … screen" and says what was asked. | `chat-<user_id>-<chat_id>` |
| **A recipe's chat** | Ask Tore on a recipe page: the person's conversation about that recipe, which opening Ask Tore on it again goes back to. Its first message says which recipe; the quick swaps stay in the main chat. Its cost counts as the chat's. | `chat-<user_id>-recipe-<id>` |
| **Background jobs** | `harness/tasks/*.md`, run by `Tore.Agent`: `plan_week`, `weekly_reflection` and `find_recipes` on a schedule; `finish_recipe`, `prep_guide`, `learn` and `home_pick` when something needs them. | `<task>-<job id>` |

The model is `TORE_PI_MODEL` (default `anthropic/claude-sonnet-5-5`), except for the small, frequent
jobs, `home_pick` and `learn`, which run on `TORE_PI_LIGHT_MODEL` (default
`anthropic/claude-haiku-5-5`). A job already running with the same task and details isn't started
again, and jobs left running when the app stopped are failed at boot, so a schedule can run them
again.

**Hard rules.**

- No call site picks a model. The model is set in runtime config, per kind of session.
- Usage is counted in `llm_usage` only, as `pi_<session kind>` (`pi_chat`, `pi_plan_week`), when a
  session's run settles or the session stops first. A run holds none. A recipe picture is counted
  as `recipe_picture`, at what OpenRouter says it cost.
- A person's chat signs in to `/mcp` as that person, so what it changes is theirs; a background
  job signs in as the household.
- The household's monthly limit (`Tore.Pi.monthly_limit_usd/0`) gates every session
  (`Tore.Pi.check/1`) and is the runaway-cost guard.
- Whatever pi writes goes through a tool, so a verifier checks it (§A.5). A tool's refusal is an
  error pi reads and acts on; Tore never retries a model.

### A.9 — Meeting point with docs/specs/ui.md

This spec owns the harness contract: run kinds, artifact shapes, MCP tools,
verifier checks, risk tiers. `docs/specs/ui.md`
owns the surface contract: how artifacts render across Today / Plan / Shop /
Capture / Cooking / Settings, the visual system, the run-receipt and
thinking-state and failure-state and undo and "Why this?" patterns.

The two specs meet at artifact schemas. Concretely:

- A run's artifact (§A.3) drives the chat's one-line receipt (docs/specs/ui.md §7.1).
- `KitchenRun.phase` (§A.2) drives docs/specs/ui.md §7.2's operational thinking-state strip.
- A failed run's `failure_code` and `repair_action` (§A.5) drive docs/specs/ui.md §7.3's failure-state card.
- Per-item `rationale` and `evidence` on every artifact (§A.7) drive docs/specs/ui.md §7.5's "Why this?" expansion.
- Household memory's parts and how full each is (§1) drive Settings' kitchen memory section.

When docs/specs/ui.md adds a surface that needs an artifact field this spec didn't
name, that's a SPEC.md amendment, not a UI-side workaround. When this spec
declares a field that no UI surface consumes, that's a SPEC.md trimming
opportunity. Both specs evolve together at the artifact-schema boundary; no
side silently degrades.

---

## Features

Status of everything Tore does, or is meant to do. Each built feature is described below with the
`KitchenRun` kinds it writes through, its tools, artifacts, verifier, risk tier and model.

| Feature | Status |
|---|---|
| §1 Household memory | Built (2026-11-10). Replaced insight synthesis |
| §2 Tore, the chat, on pi | Built (2026-11-19), not yet tried against a real model |
| Weekly planning (the `plan_week` job) | Built. Fills open days once the coming week's offers are in, or Sunday at 18:00 (`Tore.WeekAhead`) |
| §3 Anticipation | Removed, apart from the long-press object sheets |
| §4 Pantry as belief, with shelf photos and shelf life | Built |
| §5 Receipts for cost | Built |
| §6 Photos in the chat | Built (2026-11-19): pi reads receipts, recipes, shelves and the fridge itself |
| §7 Eating out | Built |
| §8 Stores and deals | Built, for ICA only. See its known problems |
| §9 Prep | Built, optional and on demand |
| §10 Weekly budget | Built (2026-11-16), not yet tried on live ICA offers or receipts |
| Recipe import from a link | Built: the Recipes screen sends the link to the chat; pi reads the page and saves it with `save_recipe`, with undo |
| Recipes from the web or a photo | Built: pi reads the page or photos and saves with `save_recipe`. `find_recipes` runs every Thursday |
| Changing a recipe | Built (2026-11-19): pi changes it with `update_recipe`, with undo; tags it leaves out and running text someone wrote stay. A saved recipe takes its page's own photo when pi passes `image_url`; otherwise a `finish_recipe` job draws one, and writes its steps when it has none |
| The app opens where the household needs it (`:home_pick_run`, §Interfaces) | Built (2026-11-11) |
| Tore from someone's own Claude, over MCP (§Interfaces) | Built (2026-11-16), not yet tried against a deployed server |

**Run kinds in the code** (`Tore.Harness.Kinds`): `:set_plan_slot_run`, `:plan_edit_run`, `:shop_edit_run`,
`:pantry_belief_update_run`, `:receipt_ingestion_run`, `:recipe_ingestion_run`, `:recipe_edit_run`,
`:memory_update_run` and `:home_pick_run`.

**Background jobs** (`Tore.Agent`, `harness/tasks/*.md`), each a pi session of its own, recorded in
`agent_jobs` with pi's summary and what it cost: `plan_week` (Friday to Sunday, `Tore.WeekAhead`),
`weekly_reflection` (Saturday), `find_recipes` (Thursday), and `finish_recipe`, `prep_guide`, `learn`
and `home_pick` when something needs them.

**Planned, in order.** Working specs live in `.docs/specs/`, which isn't versioned.

1. Instagram recipes.
2. A prep upgrade.

Several households on one server, with a gate on who may use the server's LLM, landed on 2026-11-09 (§Auth and Multi-Tenancy).
Run core and household memory landed on 2026-11-10 (§A.2, §1).
The home pick landed on 2026-11-11 (§Interfaces); its swaps moved from the chat bar into Capture on 2026-11-15.
All AI through pi landed on 2026-11-19 (§A.8, §2).
Pantry rules and barcode scanning landed on 2026-11-16 (§4).
MCP landed on 2026-11-16 (§Interfaces); ChatGPT isn't tried yet.

### 1. Household Memory → `:memory_update_run`

**Status: built (2026-11-10). Replaced insight synthesis. Written by pi since 2026-11-19.**

The household keeps a small memory that its members share, kept the way the Hermes agent keeps one:
a **profile** (who lives here, what they like) and **notes** (habits and patterns), each with a size
limit. A note about one person names them: *"Anna dislikes mushrooms."* `get_context` gives pi both
parts, with how full each is, so the chat and every background job see it.

pi writes it with the `update_memory` tool, one `:memory_update_run` per batch, checked by
`Memory.Ops` (§A.5):

- **From the chat.** *"We've stopped eating fish on weekdays"* is saved without being asked for, and
  shows as a line with Undo. A rejected batch is a tool error pi reads and fixes.
- **The weekly reflection** (Sat 06:00, `Tore.Agent.run_weekly("weekly_reflection")`). pi reads
  the memory and `get_planning_history` and writes what has become a pattern. Most weeks it changes
  nothing.

- **Artifact:** `MemoryBatch`.
- **Verifier:** `Memory.Ops`.
- **Tier:** 1, with undo (`restore_memory`).

Allergies and dietary rules stay in Preferences, where `PlanVerifier` enforces them. Memory refuses
them, and pi is told that settings never go in memory, so a refused allergy isn't mistaken for a
saved safety rule. Removing an entry in Settings is direct and needs no run.

What the reflection looks for, in `get_planning_history`'s six weeks of days (the recipe each day
ended with, leftovers, skips, what was swapped out): a weekday they skip, a dish they always swap
away, a favourite they come back to, leftovers they plan on. One week is not a pattern; three in six
is. `MealSkipped` carries an optional `reason`, so memory can tell "we went out" from "we skipped it".

**Hard rule:** There is no rating UI. Nothing asks *"how was dinner?"*. The signals are the event
stream and what people say in the chat.

### 2. Tore, the chat, on pi

**Status: built (2026-11-19). Not yet tried against a real model.**

Each person has their own pi sessions, one per chat (`Tore.Chats`, `chat-<user_id>-<chat_id>`), so partners
chatting at once don't read each other's turns. The chat tray (`/capture`) talks to it, photos with
the words, and pi's reply streams in. Three sheets ask the same session with a line saying where the
person is (`ToreWeb.PiReply`): a day's sheet on Plan, the tonight sheet on Today, and an item's sheet
on Shop. Plan's "Plan the open days" asks it too. The reply shows in a note on that screen, and the
screen updates as the runs land.

- **Instructions:** `harness/AGENTS.md`, for the chat and background jobs alike.
- **Tools:** Tore's MCP tools (§Interfaces, MCP) and pi's web search and page reading. No shell, no
  files. pi reaches `/mcp` with a session token for that household only (`Tore.Mcp.SessionToken`).
- **Runs:** every write is the tool's run: `:set_plan_slot_run` and `:plan_edit_run` for the plan,
  `:shop_edit_run`, `:pantry_belief_update_run`, `:receipt_ingestion_run`, `:recipe_ingestion_run`,
  `:memory_update_run`. Each shows in the chat as a line with Undo.
- **Verifiers:** each kind's own (§A.5).
- **Model:** the agent session's (§A.8). Its cost is counted as `pi_chat`.

**Hard rules.**

- Buttons still work. The chat is the power path; it is never the only path.
- pi can't read or write anything outside the MCP tools. No direct DB access, no shell.
- pi asks the person rather than guess an ambiguous reference (§A.6.2).
- A pinned day is refused by the tools. pi is told to leave a day marked as eating out (§7) alone
  too, but only the instruction holds it: `set_dinner` would replace it.

### 3. Anticipation

**Status: removed 2026-11-08, apart from the object sheets.**

Plan 3 built an `:ambient_scan_run` that predicted one action per surface each morning and after edits, stored
as `CounterNote`s and shown on Today, the plan slot sheet, the Shop add field and the Capture tray. The owner cut
it when the trim was rebased onto it, along with `CounterNote`s and `CounterNoteVerifier`.

What stays from Plan 3:

- **Object sheets.** A long press on the tonight card, or on a grocery row, opens a sheet with an input
  about that dinner or item. What's typed goes to the person's chat with a line naming it (§2), as the plan
  day sheet's input does.

**Hard rule.** Anything anticipatory appears inline on the relevant surface. It is never delivered as push, email
or any other interruption.

### 4. Pantry as Inference → `:pantry_belief_update_run`

**Status: built.**

Four channels update the pantry through a `:pantry_belief_update_run`: a grocery item checked off, a barcode
scanned on Shop, something pi saw at home on a photo of a shelf or the fridge (`:seen`), and an add or removal
someone asks for in the chat. Receipts are not a channel (§5).

- **Tools:** pi's `add_to_pantry` (with `seen` for what it saw) and `remove_from_pantry`. No pantry run asks a model (below).
- **Artifact:** `PantryBeliefUpdate` (items added or removed, each with `provenance`: `grocery_checkoff`, `barcode`, `vision` for what was seen, or `manual`). Undo puts each touched row's before-image back.
- **Verifier:** `PantryVerifier`, and no `matched_key` the household doesn't have.
- **Tier:** 1 — every channel applies straight away with undo. No review card.

**Seen at home.** pi reads the photo itself and calls `add_to_pantry` once per item with `seen`: the
quantity is what's there now, so it replaces the old one instead of adding to it (a seen item with no
quantity keeps the one Tore knew). `best_before` is a date printed on it, and `keeps_days` pi's guess at
how long this food keeps.

**The model sees a name once.** `Tore.Pantry.Match` finds an ingredient by its key, then by a learned alias
(`ingredient_aliases`: another name's key, or `ean:<digits>`), with no substring or fuzzy matching. A tick, an
add to the list and building the list use only `Match`, so they never wait for the model and work without it.
A name `Match` doesn't know gets its ingredient as written, and `Tore.Pantry.Learn` starts a `learn` job for it
afterwards, one per batch of names: pi says with `learn_ingredients` either that it means an ingredient Tore has (*mellanmjölk* is *mjölk*), and the two
are merged with the name kept as an alias, or it fills the new ingredient's section and shelf life. Shop items
waiting in "other" move to their section when that lands (`ItemSectionSet`). Without pi, the name stays as
written.

**Barcodes.** The scanner on Shop reads EAN-13, EAN-8 and UPC-A from the phone's camera (`barcode-detector` with
ZXing's wasm, served by Tore). `Tore.Pantry.Scan`: a learned code lands on its ingredient with its pack size. A new
code is looked up once in Open Food Facts (only the number leaves the server), its product name goes through
`Learn` as above, and the code is learned with its pack. No photo is fetched (pack photos were dropped
2026-11-20; the old `image_path` column is left unread). A code nobody knows asks for a name once. A pack still
unticked on the list is ticked instead.

**One row per ingredient.** A unique index on `(household_id, ingredient_id)` holds it. Undoing a removal yields
to a row added since. Undoing a check-off unchecks the item and leaves the pantry as it is; if that's wrong, pi
can remove the item.

**Shelf life.** A guess at `shelf_life_days` per ingredient comes from the `learn` job the first time Tore sees a name, or
from pi's `keeps_days` when it sees the item, and stays on the ingredient. A pantry row's date follows
`Tore.Pantry.Expiry`:

- A printed date (`best_before`) beats a guess.
- A date the household sets beats both until the item is bought again, and teaches that ingredient's shelf life.
- Seeing an item again never makes it fresher, so a photo never extends a date. Buying it starts over.

The date affects three things:

- **Belief:** a row past its date becomes `:uncertain`.
- **Planning:** past-date rows don't count as available, and `get_context` lists what to use soon first.
- **The list:** past-date items stop showing as probably at home, so they're bought again.

**How fast it goes** (2026-11-20). Nothing loses belief just by time passing, except what's eaten
between meals. Each ingredient that comes into the pantry is asked about once, in the background, by
Jev (`Tore.Pantry.Lasts`, a `choice`): only for cooking (pasta, salmon, cream), or eaten between meals
and gone in days, about a week or weeks. These have a half-life of 3, 7 or 21 days, and the
household's own rhythm from Basics (`interval_days`) replaces Jev's guess once there is one. The chance
an item is still there halves every half-life since it was last seen: at a half or less it's
`:uncertain`, at a quarter or less `:missing`, and no longer counts as at home. Buying it, seeing it
or confirming it starts over. What's only for cooking changes only when a dinner uses it or the
household says so. Spent from the household's AI budget, with its sponsor; without one nothing decays
by itself. Slut (Gone) teaches it: how long the pack lasted since it was bought moves a basic's
`interval_days` halfway there (so the list follows too), or else the ingredient's own `lasts_days`,
which then comes between the rhythm and Jev's guess. What's only for cooking learns nothing.
The same call picks each ingredient's picture for its Hemma row (`ingredients.icon`, a name), from
the food icons `Tore.Pantry.Icons` has (Iconito Food, MIT, and eight drawn to match), each with what
it stands for in English and in Swedish ("grapes, raisins; vindruvor, russin"), since Jev guesses at
a Swedish name it doesn't know (2026-11-21: "morot" got salt, "russin" rice). It's also told the
language the names are in, and each ingredient's section when Tore knows it. One Jev answers with that isn't there is not kept and is asked again, and a row whose
pick is no longer there shows its category's. Jev is asked when something new comes into the pantry
and when Hemma opens, so nothing kept waits for an add; with nothing unasked there's no call. Opening
Hemma also has whatever is kept without a section learned (`Tore.Pantry.without_section/1`, a `learn` job). An ingredient is asked only for what it lacks.

**Amounts** (2026-11-20). A dinner takes its amounts off what's at home (`Tore.Pantry.use_up/2`, with
`Tore.Recipes.uses/2` for the servings cooked): where the pantry's unit and the recipe's are of the same
kind (`Tore.Prices.Units`: weights, volumes, counts), the recipe's is taken off and what runs out is
`missing`; otherwise the old rule holds (gone, except dry goods, spices and condiments). Done in cook
mode does this with Undo, and so does `mark_cooked` from the chat. Used without cooking through Tore:
on Hemma a tap on the amount says what's left (`Tore.Pantry.set_left/4`; nothing left is gone), and
in the chat pi calls `add_to_pantry` with `seen` and what's left.

**Demotion:**

- There is no pantry screen (2026-11-15). The chat shows and corrects it.
- `get_context` gives the pantry as approximate. Items carry `last_seen_at` and `provenance`.

**Hard rule.** Spec or implementation work that adds back a primary
pantry-management screen is a regression of this requirement.

### 5. Receipts → `:receipt_ingestion_run`

**Status: built.**

A receipt becomes a `:receipt_ingestion_run` when pi logs it with `log_receipt`: from a photo in the chat, or from
"Scan receipt" under the shopping list, which sends the photo to the person's chat. Receipts record what was
spent and nothing else. They never touch the pantry or the shopping list, because a misread line would drop an item
off the list.

- **Tools:** `log_receipt`, `list_receipts`, `delete_receipt` (pi).
- **Artifact:** `CostEntry` (store, date, total, line items). The photo isn't kept.
- **Verifier:** `CostEntryVerifier`.
- **Tier:** 2 — a readable receipt applies straight away, with no review (§A.6.1). Undo deletes it.
- **Model:** the person's chat session (§A.8).

A receipt with the same store, date and total as one already logged is refused (`duplicate_receipt`). Line items
carry name, quantity, unit and what the row cost. Once a receipt commits, its products are matched to the household's
ingredients for prices (`Tore.Prices.Products`, §8). pi can
also delete a receipt outright: it lists recent receipts (`list_receipts`) and deletes the one named
(`delete_receipt`).

### 6. Photos in the chat

**Status: built (2026-11-19).**

A photo sent to the chat goes to pi with the words, and pi reads it itself. A photo with no words is
something to act on (`harness/AGENTS.md`): a receipt is logged (`log_receipt`, §5), a recipe saved
(`save_recipe`, source `:photo`), and a shelf or the fridge goes into the pantry, item by item, as
seen (§4). Anything else pi answers in words, such as what it could cook from the fridge; putting
one on the plan is a separate request.

### 7. Eating Out

**Status: built.**

Eating out is a state of a day in the plan, not a cost form. "Eating out" on the day's sheet, or saying so in the chat
(`change_day` with `eat_out`, through `:plan_edit_run`), emits `MealSkipped` with `reason: "eating_out"`.

- It cancels any recipe that day, and it works on an empty day too.
- Place and amount are optional, and can be added later from the sheet or the chat. They ride on the `MealSkipped` event and live on the day in the plan state; there is no separate table.
- "Not eating out", or picking a recipe for the day, clears them with the day.
- Undoing an earlier change to that day puts it back as it was, eating out or not. The chat can mark it again.
- It isn't a gap in the plan: `PlanHealth` doesn't count it, and pi is told to leave it alone when planning (§2).
- Today says so instead of showing a dinner. The cost page reads the amounts from the plans.

### 8. Stores and Deals

**Status: built, for ICA only.**

A store is added on Erbjudanden (`/deals`) by pasting a link to its offers, or to the store's own page (ICA's
`/butiker/<kind>/<town>/<slug>-<id>/` is stored as `/erbjudanden/<slug>-<id>/`). `Tore.Deals.Parsers.for_url/1` picks a parser from the
link's host, and each chain is one module implementing `Tore.Deals.Parsers.Parser`. Only https links on a parser's
hosts get fetched, so a pasted link can't point Tore anywhere else. A link no parser handles gets "Tore can't read
that store yet". Every morning at 07:00 `Tore.Deals.scrape_all/0` fetches each enabled store once, however many
households use it, and pi reads the current offers through `list_deals`, each with the ingredient it matched.

**Erbjudanden** (`/deals`, `Deals.page/3`) shows the current offers with no model: first those a dinner from today on
calls for, then those on the household's basics (`Tore.Basics`), each through its product match; the rest folded. Each
has what it saves over the regular price, and + puts it on this week's list by its ingredient's name. The stores sit at
its foot.

Each offer stores its price for `quantity` items per `price_unit` ("3 för 40 kr" is 40 for 3, per st), the usual
price per item and the comparison price per kg or litre, all as numbers. The ICA parser reads the price from the
offer's own words, so the öre stay, and an offer that only says what you save has no price. An offer without an end
date runs to Sunday. Each week's offer is its own row, and `clear_expired` keeps ended ones for 26 weeks: they are
the price history the weekly budget prices recipes from. A failed fetch emails an alert, as zero deals does.

**Products to ingredients.** `Tore.Prices.Products` matches each deal's and receipt line's product name to one of the
household's ingredients, once per name, in `product_matches`. A name with an ingredient's key, or one the pantry has
learned, matches for free; the rest go to a `learn` job, where pi matches them with `match_products`, and only an
ingredient the household has counts.
"None fits" is stored too and asked again after four weeks. Matches are kept apart from the pantry's aliases, so a
wrong one only nudges a price. After each scrape, every household matches the offers it can use.

**Known problem.** Tested on 2026-11-04 against one ICA store: `Req`, which the scrape uses, gets a 403 where plain
`curl` gets a 200, so the fetch may return nothing (and now sends an alert). The limits when fetching
works: one store, at most once a day and only until the new week's offers appear, with no retries on a 403.

### 9. Prep

**Status: built, optional and on demand.**

Plan links to "Prep this week". When asked, the page starts a `prep_guide` job (`Tore.Prep.start/2`), and pi saves
the guide with `save_prep_guide`; the page shows it when it arrives. It's a document to read: there's no scheduled job and no
"report back". It isn't a run, since it changes nothing else.

### 10. Weekly budget

**Status: built (2026-11-16).** Not yet tried against live ICA offers, which `Req` can't fetch (§8). Spec `.docs/specs/weekly-budget.md`, plan `.docs/plans/weekly-budget.md`.

A week's budget covers the whole shop. It is the week's own, set when someone asks to plan to one, or else the
household's budget from the latest change on or before that week (`budget_changes`, `Tore.Budget.set_from/3`, 2026-11-20):
raising it from week 41 leaves the weeks before at what they had, and a household's first budget covers the weeks
before it too. The plan is aimed at it and never refused for it: a dinner someone chose is never
changed to save money.

**Prices** (`Tore.Prices`) are derived every time, never stored. An ingredient's price is the first of these that
has one in the line's unit family (kg, l or st): a deal running in the week, the latest price paid on a receipt from
before the week, the latest regular price seen on a deal, and the model's estimate. Products on deals and receipt
lines reach ingredients through `Tore.Prices.Products` (§8). The `plan_week` job guesses the estimate first, for
ingredients without one (`list_ingredients`, `set_price_guesses`, `Tore.Prices.Estimate`). Only the first three count as priced:
every estimate carries its coverage, "14 of 18 ingredients priced".

**The week's estimate** (`Tore.Budget.estimate/3`) adds up the dinners the plan cooks at their servings; leftovers
and skipped days cost nothing. An open day (no dinner, not eating out, leftovers or skipped) costs a typical dinner:
the median of the dinners cooked that week and the four before it, priced the same way (2026-11-19). Because it never reads that week's own receipts, it can be worked out again later and
compared with what was paid.

**Planning to it.** `get_context` gives pi each week's budget against its estimate, and the `plan_week` task asks
it to keep within the budget when one is set. Nothing in code makes it re-plan for money: a plan that doesn't fit is
applied, and the plan screen says how far over it is.

**Where it shows.** Veckobudget (`/budget`, ui.md §6.9) says where the week lands, what's paid and left, eight weeks
of what was paid, the last four weeks by Shop's sections, and the receipts; the budget is changed there, no longer in
Settings. A receipt line carries the section Claude gave when logging it (`log_receipt`), else other, and can be
moved on the receipt. The plan screen shows "About 1 850 of 2 000 kr, 14 of 18 ingredients priced", or how far
over, and leads to Veckobudget. A day's suggested alternatives show the difference ("−35 kr"). In the chat pi sets a
budget (`set_budget`, written directly as a setting the person states: from this week on, from a week given as
`from`, or for one week as `week_of`) and plans the open days, as Plan's button asks
it to.

**After the week.** Each receipt counts towards a week (`receipts.week_start`): the list ticked most recently when
that is the purchase week or the one after, so a Saturday shop for the coming week lands there, otherwise the purchase
week. The receipt row on Shop shows its week and a tap moves it to the other. A receipt pi logs may have no lines,
but `log_receipt` needs a store and a date: since Capture's `log_total` went, a bare "we spent 1 900 this week" has
no tool of its own. Once a week has ended and has a
receipt, the plan screen gives the verdict in place of the estimate: "Spent 1 940 of 2 000 kr, about 5 % above the
estimate". With nothing paid there is no verdict and no reminder.

**Calibration** (`Tore.Budget.Forecast.OpenDays.adjustment/1`): the mean of what was paid minus what was estimated (dinners and open
days), over the latest four earlier weeks that had dinners planned and receipts, once there are two. It is added to the dinners' estimate to give
what the week is expected to cost, which is what the budget and the plan screen hold against.
It absorbs basics, pack sizes and what's already at home.

**Forecast** (`Tore.Budget.Forecast`, 2026-11-20): what a week is expected to cost is a rung of a ladder
(`.docs/specs/budget-forecast.md`), each rung a pure function of `Forecast.Facts`, what Tore knew at a moment
(`as_of`): plan events, receipts and offers count from when they were stored, so a past week can be predicted as it
stood. Basics, the model's price estimates and product matches keep no history and are read as they stand.
`Baseline` counts no open days; `OpenDays` (the calibration above) is what `Budget.status` goes by everywhere;
`ScaleOffset` fits paid ≈ a·meals + b + c·open days' cost over the last eight finished weeks, shrunk toward
`OpenDays`, and gives an 80 % range; `Drift` walks the weeks oldest first with a Kalman filter on (a, b), so recent
weeks count most, its range from the filter's variance; `PerLine` counts each list ingredient at its price times the
chance it is bought (learned from receipt lines' matches, pulled toward the household's rate, 1 until there is
evidence) plus recent weeks' extras; `Simulation` runs the week 2000 times (lines bought at those chances, open days
as recent dinners picked at random, extras around their mean), seeded from the facts, its spread calibrated split-
conformally against the finished weeks, and gives the share of runs over the budget (`status.risk`, "12 % risk att gå
över budget" beside the budget tag). Plain Elixir, no Nx. `backtest/2` predicts each finished week from its Monday and reports each rung's
mean absolute error, and how often its range held. `live/2` climbs from `OpenDays` while each next rung beats the one
below over the latest 12 finished weeks (`beats?/2`: at least 8 weeks, a smaller error, a range that held 70–90 % of
the time). Only the Veckobudget page asks, in the background as it opens, since the backtest takes about half a
second; with a range it says "Veckan landar på 640–720 kr".

**Basics** (`Tore.Basics`) are what the household buys regularly beyond its dinners, so the list and the estimate
cover the whole shop. One is learned when an ingredient was ticked off the list in three or more of the last twelve
weeks, in weeks whose dinners didn't call for it (receipt lines don't count: a price match must never reach the list); its interval is the median gap. Or
someone names them in the chat (`set_basics`: "we have cereal and milk for breakfast"), due every week. Building the
list learns first, then adds the basics due, marked as basics. Ticking one off records the purchase; taking one off
the list restarts its wait and lengthens its interval by half, and three in a row stop it. No model is asked. Until calibration exists, the
due basics are priced into what the week is expected to cost; after, calibration covers them.

**Timing** (`Tore.WeekAhead`, Friday to Sunday at 09:00 and Sunday at 18:00). It never fetches: it reads what
that morning's 07:00 fetch brought. A store's coming week is in when most of what its latest fetch added runs past
Sunday. A household that can use pi gets its coming week planned once, by the `plan_week` job: when all its
stores' new offers are in, or at Sunday 18:00 with whatever prices exist. Later offers change the estimate and the
alternatives, never the plan.

---

## Interfaces

### Opening the app (`/`)

`/` redirects to the screen the stored pick names, without waiting on a model. The stored pick
is the latest applied `:home_pick_run` (`Tore.Home`):

- **The pick.** A `home_pick` job (`harness/tasks/home_pick.md`) gives pi the facts worked out in code (weekday
  and time, tonight, tomorrow and what it needs that's neither at home nor on a list, what's unplanned this week
  and next, the list, when the latest shopping trips began (`Tore.Shop.Walk.trip_starts/1`)), the quick swaps
  that make sense now and the notes that are true now. pi reads the rest (`get_context`) and sets a screen
  (Today, Plan or Shop), up to three swaps and a note or none with `set_home_pick`, which the kind's verifier
  checks. A job that sets nothing leaves the last pick, or the fixed rule.
- **The note.** Code works out which notes are true (`Tore.Home.notes_for/1`): tomorrow needs
  things to buy, there's something on the list, tomorrow isn't planned. pi chooses one or none;
  Today writes it from the facts, with its action. It is never pi's text.
- **When.** Only when someone opens `/` or Today, or finishes cooking, and the pick is stale: older than an hour, or older than
  another run applied since. The open starts a new pick in the background for next time, at most
  one job per ten minutes per household, and never without AI. There's no cron.
- **The fixed rule.** Saturday before 14:00 → Shop; Sunday from 16:00 →
  Plan; otherwise Today. Its swaps open the other main screens. Its note: what tomorrow needs
  from 14:00, the list on Saturday morning, an open tomorrow from 17:00.
- **Times** come from `Tore.Clock`, the server's local clock: set `TZ` to the household's time
  zone. Every calendar date in the app (today, this week, tonight, a receipt's or a pantry item's
  date) comes from it, so the pick and the screens agree on the day. Stored timestamps stay UTC.

A stored pick is narrowed when it is read. A household that can't use pi now gets the fixed rule, not its last pick.

### The tab bar (every main screen)

`ToreWeb.TabBarLive`, a sticky LiveView at the bottom of every main screen: Today, Plan, Tore,
Shop and Recipes. Tore, in the middle, opens Capture over the current screen; Capture's Close
returns there, query string and all. Prep counts as Plan, and a recipe's pages as Recipes.
Cook mode has no bar.

Every tab starts with the same top bar (`<.top_bar>`): the sidebar icon opens the menu, and
the right holds the page's own actions behind ⋯ (`<.page_menu>`). The menu is a drawer that
`TabBarLive` reads when it opens: the rest of this week, starred recipes
(`Tore.Recipes.list_favorites/1`), the collections with counts (each opens
`/recipes?type=…`), the household's members, diet, budget and settings, and Ask Tore.

### Today (`/today`)

- Tonight's dinner, as its recipe page: cover, icon, title, properties (the day, collection,
  time, servings, what's missing at home with Put on the list), Cook now and Something else,
  then the ingredients. A night marked as eating out says so instead of showing a dinner.
- A lunch planned for the day is one property line, opening its recipe.
- Once tonight's dinner is cooked (Done in cook mode), or from 21:00 (`:evening_over`), Today is
  tomorrow's page instead, with a line that tonight's was cooked. Open the recipe and Something
  else; no Cook now.
- The home pick's note, when there is one and the page doesn't already say it.
- Cook now, when something is missing, opens the sheet before cooking (below).
- ⋯: Open the recipe, Ask about tonight, No dinner tonight (tomorrow).
- Long-press on tonight for its object sheet.

### Before cooking, and Done

- **Before cooking** (`ToreWeb.BeforeCooking`, from Cook now on Today or a recipe): what Tore
  can't find at home, each to tick as had (free), and one field for what you'd use instead.
  Check asks pi once for all the rest, in the person's chat; pi answers with `suggest_swaps`,
  which saves nothing, and the sheet reads the swaps from its result (`Tore.Recipes.Swaps`): a
  swap per missing thing, from what was typed first, then the pantry, never anything else, with
  how to use it; or that nothing fits, with Put on the list. Cook with these carries the swaps to cook mode in
  `?swaps=`. Nothing is saved: one red onion today says nothing about next week.
- **Done** (cook mode's last card) marks the recipe cooked and the pantry rows the dinner took as
  missing, the swaps' in place of what they stood for (`Tore.Pantry.use_up/2`). Dry goods,
  spices and condiments outlast a dinner and stay. A missing row isn't at home until it's bought
  again. Done shows what's gone, with Undo.
- **In the chat**, "I don't have Y, I have Z" gets the same swaps from pi in words
  (`harness/AGENTS.md`).

### Planner (`/plan`)

- Week view with editable slots.
- Slot interactions work via tap (assign, swap, skip, mark leftover, set servings, eating out). A day's sheet
  also has an input that asks the chat about that day (§2).
- "Plan the open days" asks the chat to fill the week's empty days; they fill as the runs land, and pi's words show
  in a note.
- One line under the week: the dates and about what it costs against the budget.
- Each day a row with the dish and status tags (Tonight, leftovers, eating out, skipped); an
  open day ahead is a faint "+ New dinner".
- **Lunch** is optional, never the default (slot key `<day>_lunch`). A planned lunch is one line
  above the day's dinner; weekends, Swedish public holidays (`Tore.Holidays`, computed) and days
  off offer a faint "+ Lunch", and any day's sheet adds one. Days off are plan events
  (`MarkDaysOff`/`ClearDaysOff`, `State.days_off`), set by asking Tore; a day off shows "Fridag"
  and changes nothing else. A lunch counts on the list and in the week's expected cost, but the
  typical dinner and open days use dinners only. A leftover's source comes earlier in time
  (`Streams.slot_order/1`: day, then lunch before dinner). The weekly auto-plan plans no lunches.
- "Prep this week" behind ⋯ (§9).

### Capture (`/capture`)

The chat with Tore, the centre tab, as a sheet over the current screen: the person's own pi session
(§2). It accepts text and photos; pi's reply streams in, with a working label from the tool it is
running ("Changing the plan…"). Opening it shows the conversation from where it was, since the
conversation is pi's.

Each write pi makes is its own run and shows as its own line, with Undo where the run has one,
read from the tool's result. Building the shopping list has no Undo, since it replaces the list.
Deleting a recipe, a receipt or a shopping item is a plain tool with no review or undo; pi finds
the id itself (`search_recipes`, `list_receipts`) and deletes only what the person clearly named,
asking when more than one matches.

Above the input sit up to three quick swaps from the stored home pick. A swap opens a screen or
sends its request.

### Shop (`/shop`)

The reliability anchor. Manual add always works. The list is built from the week's plan when
someone asks (the "Make the list" swap, or the chat), never behind their back: building replaces
the list, so a plan change must not wipe hand-added items and check-offs. The list survives a
missing plan, a missing pantry, and a missing connection to pi. Checking an item
dispatches a `:pantry_belief_update_run` (see §4). Items sit in their ingredient's section, or in "other" until
Tore has learned the name. Building the list leaves out what the pantry holds, by ingredient.
Sections come in the order the household walks its store, learned from the order it ticks things
off (`Tore.Shop.Walk`, no model): until three real trips are seen, the walk through a typical
Swedish store, fruit and veg first and frozen by the tills. A list ticked off in seconds teaches
nothing. One order per household; it doesn't tell two stores apart.

The scanner button at the end of the add line opens a sheet with the camera: each pack scanned while unpacking goes into the
pantry, or is ticked off if it's still on the list, with a line and Undo per pack (§4).

Under the list, what was spent this month (`ToreWeb.Spending`): the total against last month,
the five latest receipts, eating out from the plans, and "Scan receipt", which sends a photo to
the person's chat for pi to log (§5). A receipt is a photo, here or in the chat; there is no typed form.

### Settings (`/settings`)

- Members, by name and Pocket ID username. Add someone by their Pocket ID username; remove a member, or leave. The last member can't leave, since the household's data would have nobody to reach it. "Sign out".
- Diet and allergies: the choices every plan is checked against (§A.6.1, Tier 3).
- Household: rename it; the language, picked at `/welcome` when the household was created and shown locked.
- **Your households:** a switcher, shown only to someone in two or more.
- AI: someone with the `tore_ai` claim can let the household use their credits ("Use my credits for this household"). Others see who sponsors it, or that AI is off.
- **Things Tore has learned:** the household memory (§1), as "Your household" (the profile) and "Notes", each with how full it is and a "Forget" button per entry. Either member can forget anything.
- AI usage.

---

## Removed in Rewrite

The following exists in the codebase today and is **deleted** by this spec. Implementation
plans must remove these explicitly — they are not deprecated, they are gone.

| Removed | Replacement |
|---------|-------------|
| `pantry_live.ex` full CRUD (add/edit/category management UI) | No pantry screen (2026-11-15): grocery check-offs, barcodes, what pi sees on a photo and the chat keep it, and the chat corrects it |
| `/pantry` in main nav | Removed entirely |
| `/costs` in main nav, later `/settings/costs` | Spending under the shopping list (2026-11-15) |
| The run review page (`/review`, `/runs/:id`) | Recipes save straight away with undo (2026-11-15) |
| The chat bar and ≡ menu | The tab bar, with Tore in the middle (2026-11-15) |
| Capture's router, `PlannerAgent` and the planner command bar | pi, through `/mcp`; the chat and the screens' sheets ask it (2026-11-19) |
| Tore's own model client (`Tore.LLM.OpenAI`) | pi; OpenRouter draws recipe pictures only (2026-11-19) |
| `Tore.LLM`, its one-shots and `Tore.LLM.Prompts` | pi through `/mcp`: the chat or a background job (2026-11-19) |
| `Tore.Family` context (introduced as the canonical name in the prior rewrite) | `Tore.Household` is canonical; `Tore.Family.*` deleted |
| Onboarding questionnaire (if/when added) | Inference from events over time |
| Any meal-rating or "how was dinner?" UI | Never built; explicitly prohibited |
| Any "you haven't logged in N days" reminder | Never built; explicitly prohibited |

---

## Module Map

Files marked `PLANNED` are named by this spec but not yet in the tree;
everything else reflects the code as of 2026-11-19.

```
lib/tore/
  scope.ex                   # %Scope{household_id, user_id}, the first argument of household functions
  streams.ex                 # event stream ids per household and week
  household.ex               # canonical household context (preferences, language, sponsor, each_scope)
  home.ex                    # where the app opens: facts, the fixed rule, the stored pick, swaps
  clock.ex                   # the household's clock: now/0 and today/0 from the server's local time
  household/
    memory.ex                # profile and notes: snapshot, stores, write, forget, restore
    memory/ops.ex            # the pure batch check: plan/3 and the content rules
  members.ex                 # add, remove and switch members; pending members
  accounts.ex                # users; sign_in/1 from Pocket ID claims; the session's scope
  accounts/                  # user, membership, pending_member
  auth/
    oidc.ex                  # Pocket ID: authorization code flow with PKCE, over oidcc
  recipes.ex                 # catalog; finish (the finish_recipe job), draw_picture, cook_steps
  recipes/                   # schemas
  deals.ex                   # owns add_store/scrape_all/scrape_url
  deals/
    deal.ex
    store.ex
    household_store.ex
    parsers.ex               # picks a parser from the link's host
    parsers/                 # parser.ex (behaviour), ica.ex
  pantry.ex                  # inference-shaped: list, upsert_belief, remove_item, set_expiry, belief decay
  pantry/
    pantry_item.ex           # effective_belief
    expiry.ex                # a row's date from what was just observed. Pure
  costs.ex                   # receipts, eating out read from the plans, monthly totals, LLM usage
  costs/
  prep.ex                    # the week's guide: start (the prep_guide job), save_guide
  prep/
  planning.ex                # imperative shell over the pure Planning aggregate
  planning/                  # Decider aggregate
    commands.ex              # AssignRecipe, SwapRecipe, SkipMeal, EatOut, ...
    events.ex                # MealSkipped, RecipeRemoved, RecipeSwapped, ...
    decider.ex
    state.ex
  plan_health.ex             # ready | flexible | fragile | unplanned
  week_mode.ex
  shop.ex                    # imperative shell over the pure Shop aggregate
  shop/                      # Decider aggregate
  capture/                   # dispatch.ex (the writes behind the MCP tools, as runs)
  pi.ex                      # Tore's client for pi: ask, run, messages, recipe_chat_session, the gate
  pi/session.ex              # one pi process per household session, over a Port
  agent.ex                   # background jobs: a harness/tasks/*.md task sent to pi; agent/job.ex
  week_ahead.ex              # Fri–Sun: the plan_week job, once the coming week's offers are in
  harness/                   # the Agent Harness Layer
    kitchen_run.ex           # the runs row; kitchen_run/transition.ex (pure), kitchen_run/types.ex
    kind.ex                  # the Kind behaviour: propose, resolve, verify, review_question, apply_proposal, after_commit
    kinds.ex                 # kind name → module
    kinds/                   # set_plan_slot, plan_edit (sharing planner.ex), shop_edit,
                             # pantry_update, receipt, recipe_ingestion, recipe_edit,
                             # memory_update, home_pick
    runs.ex                  # start, submit, confirm, discard, revert, queries, fail_interrupted
    undo.ex                  # {:steps, [step]} | {:irreversible, reason}
    inbox_sweeper.ex         # weekly TTL sweep: stale :needs_user → :discarded
    receipt_ingestion.ex     # saves a CostEntry for Kinds.Receipt
    artifact.ex              # RunArtifact behaviour + artifact/registry.ex
    artifact/                # plan_diff, recipe_proposal, pantry_belief_update, cost_entry,
                             # memory_batch, shop_change, home_pick, recipe_edit
    capsule.ex               # capsule behaviour (build, to_prompt)
    capsules/                # week_plan, pantry_beliefs: read by get_context and the home pick
    verifier/                # plan, pantry, cost_entry, recipe_proposal
  image_gen/
    open_router.ex           # recipe images through the open_router library
  scheduler.ex
  storage.ex
```

```
lib/tore_web/controllers/home_controller.ex   # GET /: redirects to the stored pick's screen

lib/tore_web/live/
  home_live.ex               # /today: tonight
  tab_bar_live.ex            # sticky: Today, Plan, Tore, Shop, Recipes, on every main screen
  planner_live.ex            # the week; a day's sheet and "Plan the open days" ask the chat
  capture_live.ex            # the chat: the person's pi session, receipts with Undo, the quick swaps
  shop_live.ex               # check → :pantry_belief_update_run; spending under the list
  recipe_live.ex
  prep_live.ex
  settings_live.ex           # members, diet and allergies, households switcher, rename, sign-out, stores, kitchen memory, AI sponsorship and usage
  welcome_live.ex            # /welcome: a new household picks its language once
```

```
lib/tore_web/controllers/
  session_controller.ex      # /login page, DELETE /logout
  oidc_controller.ex         # /auth/oidc and its callback
  dev_session_controller.ex  # /dev/login, dev only
lib/tore_web/user_session.ex # starts and ends a session
lib/tore_web/components/pi_reply.ex # a screen's sheet asks the chat; pi's reply in a note
```

```
harness/
  pi-session                 # starts pi in RPC mode for one household session
  AGENTS.md                  # pi's instructions, for the chat and background jobs
  tasks/                     # plan_week, weekly_reflection, find_recipes, finish_recipe,
                             # prep_guide, learn, home_pick
```

### MCP (`/mcp`)

`/mcp` is how pi works in Tore (§2), and how someone uses Tore from their own Claude: plans the week, keeps the
list and the pantry, saves a recipe or logs a receipt Claude read. For their own Claude the thinking is theirs
and paid by their plan; no MCP tool calls a model, so a household nobody sponsors gets the whole loop. Setup:
`docs/guides/mcp.md`.

- **Shape.** Tore is a resource server; Pocket ID issues the token (audience `MCP_OIDC_AUDIENCE`, the
  `/mcp` URL). Stateless Streamable HTTP: one JSON-RPC POST, one JSON reply. RFC 9728 metadata at
  `/.well-known/oauth-protected-resource`; a 401 points there. Unset audience means `/mcp` is a 404.
- **Who.** The token's `sub` is a user who has signed in once; calls run as their active household's
  scope, in its language. pi's session token (`Tore.Mcp.SessionToken`, signed by Tore, tried first) names one
  household and the session, and signs in as that household with no person.
- **Tools.** Reads: `get_context` (language, today, diet, memory, both weeks' plan and their budget against
  the estimate, the basics, the list, the pantry, what's due), `get_planning_history` (six weeks of days),
  `search_recipes`, `get_recipe`, `list_receipts`, `list_deals` (with the ingredient each offer matched),
  `what_if` (the week's forecast with its plan changed in memory, next to now, by the rung the budget page goes
  by; nothing is saved), `suggest_swaps` (pi's swaps for the sheet before cooking; nothing is saved). Writes call `Capture.Dispatch`, with `actor: :mcp`: `set_dinner` and `change_day` (both
  take `meal: "lunch"`), `set_days_off`, `add_to_list`, `check_off`,
  `remove_from_list`, `make_list`, `add_to_pantry`, `remove_from_pantry`, `update_memory`, `mark_cooked`,
  `delete_recipe`, `delete_receipt`, `set_budget`, `set_basics`, `update_recipe`, `draw_recipe_picture`
  (an image call, gated). `put_together` makes a meal from recipe ids (missing parts are written with
  `save_recipe` first); it writes directly, like `mark_cooked`, and `delete_recipe` takes it away. For the jobs:
  `list_ingredients`, `learn_ingredients`, `match_products` (offers and receipt lines to ingredients,
  `Tore.Prices.Products.put/3`), `set_price_guesses`, `save_prep_guide` and `set_home_pick`. `save_recipe` and
  `log_receipt`
  submit Claude's reading as the run's proposal, so the same verifiers decide. Each write answers with
  its run id, and `undo` reverts any run. A bad argument or a refusal is a tool error Claude can read.
- **One prompt**, `plan_week`: the same instructions the `plan_week` job gives pi
  (`harness/tasks/plan_week.md`), and the household's week mode.

```
lib/tore/mcp.ex                    # JSON-RPC dispatch, tools and the prompt
lib/tore/mcp/token.ex              # verifies the Pocket ID token
lib/tore/mcp/tool.ex               # the tool behaviour; ctx, reply, date
lib/tore/mcp/tools/*.ex            # one module per tool
lib/tore/mcp/plan_week.ex          # the plan_week prompt
lib/tore_web/mcp_auth.ex           # bearer token → scope
lib/tore_web/controllers/mcp_controller.ex, mcp_metadata_controller.ex
```

---

## LLM Surface

Tore has no model facade. Everything a model does in Tore, pi does in a session (§A.8), through
the MCP tools; the person's own Claude uses the same tools (§MCP).

**The gate.** `Tore.Pi.check/1` answers for a household before any session starts or any prompt is
sent: `{:error, :pi_off}` when pi isn't configured (`TORE_PI_COMMAND`), `{:error, :ai_unavailable}`
when nobody sponsors the household (a member with `ai_enabled` who turned sponsorship on, or who
started the household with the claim), and `{:error, :budget_exceeded}` once the household has
spent `Tore.Pi.monthly_limit_usd/0` this calendar month. `Tore.Pi.refusal_text/1` is what a screen
says for the last two, instead of "try again". Each session records its cost in `llm_usage` when a
run settles. Image generation (`Tore.ImageGen`) runs only from `draw_recipe_picture`, inside a
gated session, and records what OpenRouter says it cost as `recipe_picture`.

---

## LLM Interface Conventions

One pattern: **pi, with tools.**

- The model reads through Tore's read tools and writes through its write tools; it never gets a
  prompt Tore assembled from the household's data (§A.4).
- A new AI feature is a tool, a task file, or a line in `harness/AGENTS.md`, not a prompt in code.
  A screen that needs an answer asks the person's chat in one line ("From the … screen: …") and
  shows the reply (`ToreWeb.PiReply`); work nobody watches is a background job.
- Tool schemas use JSON Schema. A bad argument or a refusal is a tool error pi can read.
- Every write is a run with its verifier and undo (§A.2). Read tools write nothing.
- Facts pi would have to compute, such as dates and counts, are computed in code and given as
  plain lines (the home pick's facts, `get_context`).
- A tool returns what Tore knows; pi's judgement (which ingredient a product is, what a dish looks
  like, how long a guide's step takes) comes back as a tool's arguments.

### Universal rules

- Every session's cost is recorded in `llm_usage` under its kind.
- Every session goes through the gate for its household (`Tore.Pi.check/1`).
- No LLM-emitted SQL, no LLM-emitted code execution, no LLM-emitted shell. The MCP tools are the only side-effect channel.
- There is no shared prompt builder (§A.4). pi gets the household through its tools.

---

## Quantum Schedule

```elixir
config :tore, Tore.Scheduler,
  jobs: [
    {"0 3 * * *",  {Tore.Deals,                          :clear_expired,      []}},
    {"30 3 * * *", {Tore.Recipes,                        :draw_missing_pictures, []}},  # off in dev and test
    {"0 4 * * 0",  {Tore.Harness.InboxSweeper,           :sweep_weekly,       []}},
    {"0 6 * * 6",  {Tore.Agent,                          :run_weekly,         ["weekly_reflection"]}},
    {"0 7 * * 4",  {Tore.Agent,                          :run_weekly,         ["find_recipes"]}},
    {"0 7 * * *",  {Tore.Deals,                          :scrape_all,         []}},  # every store's offers, daily
    {"0 9 * * 0,5,6", {Tore.WeekAhead,                   :run,                []}},  # runs plan_week once the offers are in
    {"0 18 * * 0", {Tore.WeekAhead,                      :run,                []}}   # the deadline: plans with what there is
  ]
```

**Scheduled jobs go through the harness.** A cron job that writes state on the
AI's behalf is a pi background job (`Tore.Agent`), whose every write is a `KitchenRun` through
`/mcp` — it never calls a context function directly, per §A.2's hard rule. A job is recorded in
`agent_jobs` with pi's summary and cost; a scheduled one runs once a week per household. `Tore.Deals.clear_expired`
and `Tore.Deals.scrape_all` are deterministic maintenance, not AI actions, and stay direct.
`Tore.Recipes.draw_missing_pictures` only starts a `finish_recipe` job for each recipe that has no
picture, the same job saving one starts.

---

## Auth and Multi-Tenancy

A *household* owns all data: plans, groceries, pantry, costs, memory, recipes, runs, LLM usage.
*Users* belong to one or more households through `memberships`, exactly one of them active. Pocket ID is the only login: `Tore.Auth.Oidc` runs the authorization code
flow with PKCE, and `OidcController` hands the ID token's claims to `Accounts.sign_in/1`. A returning user
gets name, username and LLM access refreshed. A new one joins every household that added their username
(`pending_members`), active in the first and in its language, or else gets a household of their own, named
after them, whose language they pick once at `/welcome`.
A missing username, or one held by another Pocket ID account, is refused. Sessions are browser cookies
that last 90 days. "Sign out" in Settings ends the session in that browser and closes the app in its other
open tabs; other devices stay signed in.

Pocket ID decides access, not Tore. Its client for Tore allows only the `tore` group, so nobody else
reaches the callback. Members of `tore-ai` carry the claim `tore_ai = true` (the name is set by
`AI_CLAIM`), which sets `ai_enabled`. Tore decides only who shares a household: `Tore.Members` adds,
removes and switches. Adding someone never makes them the household's sponsor, so nobody reaches another
person's credits by adding them. `Tore.Household` is the canonical context. There is no `Tore.Family` module.

**Several households, one server.** The rules, from `.docs/specs/households.md`:

- Every function that reads or writes a household's data takes `%Tore.Scope{household_id, user_id}` first. LiveViews get it from `on_mount`,
  built on each request from the active membership, so a removal takes effect at once. Background jobs loop
  over households with `Tore.Household.each_scope/1`.
- `Tore.Repo.prepare_query/3` raises when a query on a household table has no `household_id:` option, and
  filters by it when it has one. A missed site crashes instead of leaking.
- Event streams (`plan:<household>:<monday>`, from `Tore.Streams`), PubSub topics
  (`plan:household:<id>`) and storage keys (`households/<id>/…`) carry the household id, and the image controllers load through the scope, so another household's id is a 404.
- Stores and deals are shared: a store is fetched once however many households use it (`household_stores`).
  Nothing else crosses households.
- The `plan_week` and `weekly_reflection` jobs run only for households that can use pi (`Tore.Pi.check/1`).

---

## Backlog

Loose ideas captured here so they don't drift in a scratch file. Promote to a
proper section or sub-spec when picked up.

- **Locale on scraped recipes.** Scraped recipes should be translated into the household's locale at ingestion time.
- **Elixir 1.20 upgrade.** Move to the new type system and take advantage of it across `lib/tore/`.
- **HTML in `.html.heex` files.** Move inline templates out of `*_live.ex` modules into colocated `.html.heex` files.
- **Scraped recipe format** Even scraped recipes without llm should be sent to llm for translation if needed, and reformatted to the "tore format"

---

## Out of Scope for This Spec

- iOS/Android native apps. Mobile web is the target.
- Multi-family aggregation, social/sharing features.
- Nutrition tracking, calorie counting.
- Voice input (target for a later phase; the chat takes text and photos).
- Anything that requires push notifications.

---

## Success Criteria

The rewrite is done when:

1. Every feature marked Built in §Features passes an end-to-end test on a real device.
2. `pantry_live.ex` no longer offers add/edit; the route is gone from main nav.
3. `cost_live.ex` is reachable only through Settings.
4. `Tore.Family.*` is deleted; `Tore.Household` is canonical.
5. pi, in the chat and the background jobs, plans and changes the week through Tore's MCP tools, every write a run, on a real model.
6. Receipts, scanned under the shopping list or logged by pi, write to `costs` and never to `pantry`.
7. A photo of the fridge or a shelf in the chat puts what pi sees in the pantry, with Undo.
8. A user can skip a meal with one tap and the app says nothing back.
9. No notifications. No nags. No streaks.
10. Every state-changing AI action is a `KitchenRun` — visible as a row in the kitchen runs table, producing its typed artifacts, gated by its verifier, classified into a risk tier. No code path writes household state on the AI's behalf outside a run, apart from the exceptions §A.2 names.
11. Every applied run carries the artifacts of what it changed, and every run waiting for review carries its proposal, with rationale-or-provenance fields populated where they surface a decision (§A.7).
