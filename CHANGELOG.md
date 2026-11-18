# Changelog

All notable changes to Tore are recorded here. The app is pre-production, so
entries are grouped by feature milestone rather than released versions.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### The Notion look (2026-11-18)

- Papper: ink on white, graphite when the phone is dark. The main action is ink; colour comes from photos and from tags that mean something (orange dinner, yellow baking, green sauces and done, blue assemblies and the week, red tonight or missing, purple leftovers, grey quiet). Buttons are soft rectangles.
- Phosphor icons in place of Heroicons and every emoji: regular in the chrome, fill for the current tab, duotone for pages and dishes. The Tore button is raised above the tab bar.
- Never a missing photo: a dish without a picture shows its icon on its collection's tint, the icon read from its name ("Laxpasta" is a fish). Recipes still without a picture get one drawn at night (`Tore.Recipes.draw_missing_pictures/0`, off in dev and test).
- The same top bar on every tab: the menu on the left, the page's ⋯ on the right. The menu is a drawer with the rest of the week, favourites, the collections with counts, the household's settings and Ask Tore. Today's gear is gone.
- Favourites: a recipe's ⋯ stars it; starred recipes lead Recipes and sit in the menu.
- Today is tonight's recipe page: cover, icon, title, properties (what's missing as red tags with Put on the list), Cook now, Something else, the ingredients.
- Plan is a list: one line with the dates and the money ("16–22 november · runt 575 av 900 kr"), each day's dish with status tags, "+ Ny middag" on open days.
- Recipes is a gallery grouped by collection (two to a row, 4:5 pictures), or a list; the choice is remembered. Search opens from the toolbar.
- Shop is a to-do page: one add line with the scanner at its end, sections as tinted tags that fold, square checkboxes, the basket folded at the bottom.

### Pages, collections, and a smarter kitchen (2026-11-17)

- Recipes are collections: 🍲 Dinner, 🥐 Baking, 🫙 Sauces & sides, 🥪 Assemblies. An import files itself. Only dinners go on the week; the rest are there to find and start.
- A recipe is a page: cover, then quiet properties (collection, time, servings, at home, source, last made). The servings stepper scales the amounts and carries into cook mode. Cook or Bake now, Put on the week (pick a day, Undo), Ask Tore.
- Every picture is drawn in one house style, so the library reads as one cookbook. `Tore.Recipes.restyle_images/0` redraws the existing ones (paid image calls; run by hand).
- Tab bar: names under the icons, a filled icon for where you are, no sparkles.
- Today's "Something else" offers three dinners with photos and why each fits; choosing one changes tonight, with Undo. "No dinner tonight" is one tap.
- Plan: "Plan the N open days" fills what's open, with the run's receipt and Undo. Day rows lead with the dish's photo.
- Shop: one add field at the top that reads "2 l mjölk"; Make the list from the week's dinners; ticking draws the check and folds the row into the basket; each item says which dinner it's for ("till tisdagens tacos").
- Tore: "can I bake cinnamon rolls with what I've got?" answers with what's missing, Bake now, and Put what's missing on the list. While it works it says what it's doing. Dinner suggestions are photo rows.
- Cook mode: a timer on any step with minutes, kept while you move on; a hand-written recipe's steps are written when it's saved.

### The list in your store's order, recipes from a link (2026-11-16)

- A new recipe starts from a link: + on Recipes opens a link field, Tore reads the page in and opens the recipe. Writing it in by hand is the way out underneath, and takes what was typed along.
- Share a link to Tore: `/recipes?url=…` (or `?text=…`) reads it in straight away. The app manifest puts Tore in Android's share sheet; on iPhone a Shortcut opens that address.
- Shop sections start in the order of a typical Swedish store (fruit and veg first, frozen last) and then follow the order you tick things off, once Tore has seen three trips. No model call.

### Weekly budget (2026-11-16)

- Tore knows what an ingredient costs: an offer running that week, the price paid on an earlier receipt, the usual price seen on an offer, or a guess. Every estimate says how much of it is real prices ("14 of 18 ingredients priced"). Offers and receipt lines are matched to ingredients once per product.
- Offers keep their real prices now: decimals, "3 för 40 kr" per item, the comparison price per kg or litre, and half a year of history. A failed fetch sends an alert.
- Set a weekly budget in Settings, or for one week in Capture ("plan next week, budget 2 000"). The planner aims at it, sees each recipe's cost, and plans once more when its own picks go over, keeping the cheaper plan. It never changes a dinner someone chose.
- The plan screen shows the week's estimate against the budget, and a day's alternatives show what they'd change ("−35 kr"). After the week it gives the verdict: what was spent against the budget and the estimate.
- Receipts count towards a week, a weekend shop towards the coming one; a tap on the receipt moves it. "We spent 1 900 this week" in Capture works without a receipt.
- The estimate learns: the average gap between paid and estimated over recent weeks is added to the next one.
- Basics: what the household buys every week beyond its dinners is learned from what gets ticked off and bought, or named in Capture ("we have cereal and milk for breakfast"). They're added to the list when due, and taking one off makes it come less often.
- From Friday Tore fetches offers once a day until the new week's appear, then plans the week; at the latest Sunday at 18:00.
- Over MCP: `set_budget`, `set_basics`, and `match_deals`, so a household without the server's model still gets offer prices. `get_context` shows both weeks' budget and estimate.
- Not yet tried on live ICA offers: the fetch gets a 403 (SPEC §8).

### Tore from your own Claude (2026-11-16)

- Tore is an MCP server at `/mcp`. Add it to Claude as a custom connector and sign in through Pocket ID; Claude then works on your active household, in its language.
- Claude can read the week, the list, the pantry, recipes, receipts and deals, and change the plan, the list, the pantry and the household memory. It can save a recipe or log a receipt it read from a page or a photo. Every change shows in the app at once and can be undone from either side.
- None of it uses the server's model, so a household without AI gets the whole loop on its own Claude plan.
- The `plan_week` prompt plans next week the way Tore's own planner does.
- Setup: `docs/guides/mcp.md`. Not yet tried against the deployed server, or from ChatGPT.

### Pantry rules and barcode scanning (2026-11-16)

- Ticking an item, adding one and making the list ask no model. Tore matches a name to its ingredient exactly, by name or by a name it has learned, and learns a new name once, afterwards, in one call: it either joins an ingredient Tore has (*mellanmjölk* is *mjölk*) or gets its own section and shelf life. Until then the item waits in "Other".
- Making the list leaves out what the pantry holds by ingredient, so a near miss stays on the list.
- Shop has a scanner: point the phone at what you unpack and each pack goes into the pantry, or is ticked off if it's still on the list, with Undo. A new barcode is looked up once in Open Food Facts and remembered with its pack size; one nobody knows asks for a name once.
- The `filter_pantry` and `classify_item` prompts are gone.

### One look across the screens (2026-11-15)

- Today, the recipe page and Cook mode share one layout: the photograph full-bleed and darkening into the page, the name on its foot, a row of pills with one saffron lamp, then the facts.
- Tapping a recipe carries its photograph from the grid to its page and back. A recipe opens at its own address (`/recipes?id=`), so Back closes it.
- Everything tappable answers a press; toasts rise above the tab bar and leave on their own; sheets rise from the bottom; content arrives a few items at a time. Reduced motion turns it all off.
- Plan reads like a calendar with today lit; Shop has a dill bar that fills as things go in the basket; Capture's own messages are ink so the send button stays the lamp; Settings is a stack of rounded cards.

### Fewer screens, a tab bar and a locked palette (2026-11-15)

- A tab bar at the bottom of every main screen replaces the chat bar and its ≡ menu: Today, Plan, Tore, Shop and Recipes. Tore, in the middle, opens the chat over the current screen and returns there. The quick swaps moved into the chat, above its input. Settings opens from a button on Today.
- Recipes from a link, a photo or the planner are saved straight away, and Undo in the chat deletes them again. The review page (`/review`, `/runs/:id`) and the review counts are gone.
- Spending moved under the shopping list: this month against last, the latest receipts, eating out, and "Scan receipt". The costs page and its typed receipt form are gone.
- Diet and allergies moved into Settings; `/cooking` is gone. The pantry page is gone too: Tore keeps the pantry, and the chat corrects it.
- The palette is locked: cast-iron greys tinted toward saffron (Gjutjärn, dark) and a warm white (Dagsljus, light), saffron 400 with black type as the one accent, dill for done (the shopping tick), lingon only for what can be lost. Contrast is checked in docs/specs/ui.md §4.3.

### The app opens where you need it

- `/` opens the screen the household most likely needs now, picked by a decision model (TypeSafe's Jev, `typesafe/jev-1.14`) and stored as the latest `:home_pick_run`. Opening the app never waits for it: a pick older than an hour, or older than a change since, starts a new one in the background for next time, at most once every ten minutes and never without AI. Below 0.6 confidence, or without AI, a fixed rule picks: a review waiting, the list on Saturday morning, next week's plan on Sunday evening, otherwise tonight.
- A new decision tier: `Tore.LLM.decide/4` asks typed questions through OpenRouter's Decisions API, through the same gate and cost records as every other call. `DECISIONS_MODEL` and `DECISIONS_URL` configure it.
- A chat bar at the bottom of every screen replaces the navigation bars and Today's review pill: up to three quick swaps, a chat box that opens Capture with what you typed, and a ≡ menu of every page with the reviews waiting.
- Capture can suggest the next steps for the bar with a `quick_swaps` tool. They're not stored; the next pick replaces them.
- Today moved from `/` to `/today`.
- Every calendar date comes from `Tore.Clock`, the server's local clock, instead of UTC, so the pick and every screen agree on the day after local midnight. Set `TZ` to the household's time zone.
- A new look, "Porslin": cobalt on porcelain white with saffron and lingonberry states, the device's own typeface, corners that follow hierarchy (sheets 20, cards 14, controls 10), hairlines instead of shadows, sentence-case section labels and no arrows on links. Today is tonight's dinner in large type. Plan rows show the whole dish name, Recipes is a compact list, and every page title sits on the page at one size. Recipes' "Get ideas" placeholder is gone.
- The screens are set like a weekly menu: one double cobalt "rim line" under each title, days, recipes and shopping items as lines on the page instead of rows in a card, weekdays and months written out, and Today's dish in the largest type under the date with one filled button. Plan lost its own command box (the chat bar and each day's sheet do that), the week's mode moved behind "Planning for: …", a shopping item is removed from its long-press sheet, and the menu leads with Today, Plan and Shop.
- Several photos sent in one message each get their reply; only the first one did before. A photo whose reading failed can be sent again instead of being called a duplicate, and a tool that fails inside Capture is no longer shown as a chat reply.
- Opening a day in Plan and closing it again writes nothing. Before, every close saved the day again, and a leftover day lost half its portions each time.
- A receipt photo is logged straight away, with Undo. The review step for receipts is gone: it depended on a check of line prices that the read-out never contained. Receipt photos are no longer stored, and the `tore-runs` bucket is gone.
- Removed the `ai_operations` log and the token and cost columns on runs; AI cost is recorded per feature in `llm_usage`. The receipts `image_path` column is gone. The dev database needs a reset.
- Capture, the planner and the capsules are handed the household's scope instead of rebuilding one from an id. Decimal coercion of model output lives in `Tore.Types.decimal/1`. Recipes' substitution and cook-mode answers no longer block the screen.
- Cook mode: a recipe opens as cards to step through at the stove (`/recipes/:id/cook`). The first card is what to take out; each step shows what it uses, with amounts, and how long it takes. "All steps" shows the whole recipe to peek ahead, and tapping a step goes there. The screen stays on, and a reload lands on the same card. An imported recipe uses the steps it was saved with; one written as running text gets its steps from the model once, and they're kept. This replaces the three-phase summary box that asked the model every time.
- The week's prep can be followed as the same cards ("Start prepping").
- Photos lead: Today opens with the dish's picture edge to edge, Recipes is a two-column picture grid, and Plan's pictures are larger. A recipe's menu has "New picture", and a picture that couldn't be made is logged with the reason instead of failing silently.
- Recipe pictures are generated with `bytedance-seed/seedream-5-0-pro` by default. Google's image endpoints keep prompts for abuse monitoring, so an OpenRouter account with a zero-data-retention guardrail rejects them.
- The dish's name sits on its photograph: on Today, on each card in Recipes, and at the top of a recipe, which now fills the phone screen. A recipe leads with what you can do (Start cooking, Missing something?, the original) as pills, then time and servings, then ingredients with amounts in their own column. Today also says when dinner would be on the table.
- A dark look ("natt") for phones set to dark; the light porcelain look is unchanged in colour. Buttons are pills.
- New colours: warm paper white with an ember accent in light, near-black with saffron in dark. Large photographs blur and fade into the page at the foot, and the dish's name stands on that fade. The double rim line is now one quiet hairline.
- Softer throughout: headlines at an app's size and weight rather than a poster's, charcoal and cream instead of black and white in dark, a quieter apricot accent, rounder corners, and lists gathered on soft rounded surfaces instead of ruled lines on the page.
- Every screen draws its colours from the design tokens: no raw Tailwind greys, blue, red, amber or `dark:` classes are left, and the undefined `--surface-raised` and `--ink` are gone. A `--danger-soft` token backs error notices.
- Shop no longer scrolls sideways on a phone: the add-item field can shrink.
- With AI off, checking off a shopping item adds it to the pantry again, keeping its name as written.
- Capture only sends a request it was opened with when the chat bar signed it for that person in the last minute, and it drops the request from the URL once sent.

### Run core and household memory

- A run is one row in a `runs` table, moved through its steps by a pure transition function. The event-sourced run aggregate, its Projector, `UndoPayload` and `RunReceipts` are gone. A kind of run implements `Tore.Harness.Kind` (propose, resolve, verify, review, apply), and `Tore.Harness.Runs` drives it.
- Undo is a list of steps captured when a run applies, and puts back what was there before, including a plan slot's recipe and pin, instead of clearing it. Building the shopping list is the one irreversible run.
- Household memory replaces insight synthesis: a bounded profile and notes, shared by the household, written by a weekly review and by Capture's new `memory` tool, readable and removable in Settings. Allergies stay in Preferences; memory refuses them.
- Every Capture write goes through a run with a verifier and, apart from building the shopping list, Undo: plan edits and eating out, the shopping list, the pantry, receipts, memory, and recipes from a link or photo, which now wait for review before they're saved. The deletes below are the exception.
- Capture refuses to change a pinned day.
- Simpler data: an eating-out day's place and amount live on the plan, and the `dining_out` table is gone. The database holds one pantry row per ingredient. Undoing a check-off leaves the pantry as it is.
- Capture can delete a recipe, a receipt or a shopping item when asked, straight away and without review.
- A receipt applies straight away with Undo, unless its lines don't add up to its total.
- Recipes keep their structured steps, a recipe that doesn't say how many it serves is taken to serve 4, and a recipe's Review link opens that recipe.
- Several migrations were edited in place. Reset the database.

### Several households

- Several households share one server. Every function that reads or writes a household's data takes a `%Tore.Scope{}`, and `Tore.Repo` raises on a household table queried without one, so a missed query crashes instead of leaking.
- Event streams, PubSub topics, storage keys and the image controllers carry the household, so nothing crosses households except deals.
- A first sign-in joins the households that added that Pocket ID username, or starts a household of its own, which picks its language once at `/welcome`.
- Settings: add a member by username, remove one or leave (not as the last member), rename the household, and switch between households when you're in two or more.
- Stores are shared and fetched once, however many households use them.
- AI is per household: a member with the `tore_ai` claim can let the household use their credits. `Tore.LLM` refuses calls without a sponsor or past the household's monthly limit, records spend per household, and the app says which refusal it was. The OpenRouter key is optional, also in dev.
- The planning and memory crons run per household, and only for households that can use AI and are under their limit.

### Pocket ID login

- Pocket ID is the only way to sign in. The 16-digit codes, the setup page, roles, the rate limiter and `argon2` are gone.
- Pocket ID decides who may sign in, through the groups on its client. A `tore_ai` claim marks who may use the server's LLM.
- Settings lists the members and has "Sign out", which also closes the app in other open tabs. Sessions last 90 days.
- A dev-only sign-in at `/dev/login` for working without Pocket ID.
- `docs/UI_SPEC.md` moved to `docs/specs/ui.md`, and `docs/LLM-NATIVE-FEATURES.md` to `docs/specs/llm-native-features.md`.

### Recipe proposals (plan 4)

- The planner can find recipe pages on the web, import one, or adapt a recipe from the catalog. Each becomes a proposal that a verifier checks and a person saves or discards on the run review page.
- LLM calls go through the `open_router` library instead of a hand-written adapter.

### Anticipation (plan 3)

- Long-press the tonight card or a grocery row for a sheet with a command scoped to it.
- `resolve_slot` resolves a slot from plain words, without the LLM.
- The ambient scan and its predictions also landed here, and were removed again in the trim.

### Trim

Everything now has to pass one test: does it change what Tore does next, without the household having to
maintain it? `SPEC.md` records this as a core rule, and each feature now has a status.

**Removed**

- The kiosk and device tokens, which nothing could issue, so the kiosk couldn't be used.
- Plan 3's predictions: the ambient scan, counter notes and their verifier, the 05:00 scan and the re-scan after edits. The long-press object sheets stay.
- The `/deals` page and the Coop stub. The planner reads deals, and stores moved to Settings.
- `/inbox`. Today's review pill opens the oldest pending review directly.
- The Saturday 18:30 prep job, whose result the page never looked up.
- Most of the cost page: tabs, charts, weekly bars and restaurant stats (1,104 lines down to 323).
- The unbuilt run kinds from `SPEC.md`.

**Changed**

- Receipts record cost only and never touch the pantry or the list, because a misread line would drop an item off the list.
- Shelf photos apply straight away with undo, and replace quantities.
- Eating out is a state of a day in the plan. It cancels any recipe, works on an empty day, and takes an optional place and amount.
- Stores are added by pasting a link, and the link picks the parser. Only https links on a parser's hosts get fetched.
- The household's language is chosen once at setup and then locked, and everything stored uses it.
- Prep is optional and on demand, through a "Prep this week" link on Plan.

**Added**

- Shelf life: the LLM guesses it per ingredient. It feeds belief, planning and the list, and a date set by hand teaches it.

**Fixed**

- The cost page no longer crashes when a background run finishes while it's open.
- Capture's replies, and 22 strings on other pages, appeared in English in a Swedish household. A test now fails on any empty or fuzzy Swedish string.
- Flaky database busy errors in tests, by using one connection.

### All-handlers Tiger-Style rename

The `Tore.Handlers.*Handler` family is retired — "handler" is filler; each
module now names what it does. Pure rename — suite unchanged at 483/0.

- Folded the context-backed handlers into their existing context modules:
  `RecipeHandler` → `Tore.Recipes`, `CostsHandler` → `Tore.Costs`,
  `PantryHandler` → `Tore.Pantry`, `DealsHandler` → `Tore.Deals`,
  `PrepHandler` → `Tore.Prep`. Their LLM/scraping/orchestration functions now
  sit beside the persistence and query functions they already called (the
  `Tore.Recipes` ↔ `RecipeHandler` cyclic dependency dissolves into local calls).
- `PlanningHandler` → `Tore.Planning` and `GroceriesHandler` → `Tore.Shop`:
  the bare context module is the imperative shell over the pure aggregate
  submodules (`*.Decider/.Events/.State/.Commands`), matching the `Tore.Recipes`
  pattern. The aggregate and its operations now share one name.
- `InsightsHandler` → `Tore.Insights` (no sibling context existed).
- `Tore.Costs.log_dining_out/1` is kept (live callers) with the folded `/2`
  beside it; the handler's `to_decimal` was folded as a distinct
  `receipt_to_decimal` because the pre-existing `Tore.Costs.to_decimal` coerces
  `nil → 0` while the receipt path must pass `nil` through — reusing it would
  have silently changed behavior. `lib/tore/handlers/` is removed.
- Follow-ups deferred to keep this pass a pure rename (not done here):
  consider making `Tore.Recipes.scrape_and_create/2` private now that its only
  caller is internal; add `@spec`s to the folded functions; add a comment on
  `Tore.Costs.receipt_to_decimal` documenting its nil-pass-through contract.

### Harness foundation

The event-sourced run harness — the load-bearing primitives for AI-driven
runs.

- `Tore.Harness.Run` aggregate: closed `Events`/`Commands` sum types (10 each),
  a six-variant `State` ADT enforced by `@enforce_keys`, and a pure
  `Decider` (`decide/2` + `evolve/2`).
- `Tore.Harness.Run` public surface: `load/1`, `next_stream_id/0`, and
  `append/3` (PubSub-broadcasting on the household topic).
- Closed `Artifact` behaviour + compile-time `Registry`, with the `PlanDiff`
  (events authoritative, `summarise/1` projection) and `RunSummary`
  (outcome + counts rollup) artifacts.
- `Tore.Harness.Orchestrator`: composes the Decider, owns persistence and
  artifacts, drives the planner command run.
- Per-household `Tore.Harness.Projector` (GenServer + ETS, replays open runs on
  boot) with its Registry and DynamicSupervisor.
- `Tore.LLM.PlannerAgent.run/4` refactored to a pure bounded tool-calling loop
  (no persistence, no correlation-id generation).
- `ai_operations`: `correlation_id` replaced with `run_stream_id` (irreversible
  migration).
- Web: `ReceiptLive` component (pattern-matched per `State` variant); `PlannerLive`
  consumes the Projector and renders the receipt, replacing the old
  `quick_reply` machinery.

### Real PlanDiff from tool outcomes

The receipt now reflects what the planner actually did, not a placeholder.

- `Tore.Harness.PlanDiffBuilder` reconstructs a real `PlanDiff` from the
  planner's successful tool calls (joining args to results by `tool_call_id`,
  keeping only successful action calls); the Orchestrator uses it instead of a
  hardcoded placeholder.
- New `PlanDiff` event types `RecipeSwapped` and `ServingsChanged` in the
  rollup; humanized `RunSummary`/`PlanDiff` change wording.
- Action tools require a `rationale` arg (flows into each diff event);
  `assign_recipe`/`swap_recipe` return the recipe label.
- `PlanningHandler.swap_slots/3`: a true atomic recipe swap (reads both slots
  before cross-assigning) — fixes a data-loss bug where the old move-based swap
  destroyed the target recipe.

### Named receipt lines + Swedish i18n

- The receipt's applied body renders one localized line per change, naming the
  recipe and day (from the `PlanDiff` rollup), e.g. "Bytte in Ugnsraggmunk på
  Lördag" / "Hoppade över Söndag".
- Plan-health badge localized via `{status, count}` + a view-side `gettext`
  helper (domain module stays web-free).
- Full Swedish translation pass: all remaining UI strings translated, 8 wrong
  fuzzy auto-matches corrected.
- Receipt component tests pinned to the `sv` locale so they assert what users
  actually see.

### Orchestrator error boundary

- `dispatch/2` is railway-oriented end to end with a typed error channel
  (`{:step_failed, term} | {:run_crashed, Exception.t}`): interior helpers
  thread `{:ok,_} | {:error,_}` (no more bare matches that raised), a
  `try/rescue` at the boundary converts any crash, and a best-effort tee records
  the run as `Failed` on any error — no dangling open runs.
- The receipt translates `failure_code` (machine-readable) instead of a baked
  message string; Swedish failure messages added.

### Verify-then-mutate planner + PlanVerifier

The planner is now verify-then-mutate, closing the load-bearing §A.5 atomicity
gap: the LLM proposes, a deterministic verifier decides, and a failure leaves
the plan genuinely unchanged.

- Planner action tools are pure: they propose plan changes against an in-memory
  working `Planning.State` via the existing `Planning.Decider` (preserving the
  model's mid-loop `:slot_empty`/`:not_pinned` feedback) and return the events
  they'd produce plus the evolved state — no persistence. `swap_recipe` reuses
  an extracted pure `PlanningHandler.swap_events/3`.
- `PlannerAgent` threads a `working_plan` through its loop and accumulates
  `plan_events`, returning both in its `loop_outcome`. The Orchestrator loads the
  plan into the agent context and persists the accumulated events exactly once,
  after the loop, via `PlanningHandler.apply_events/2`.
- `Tore.Harness.Verifier.PlanVerifier` — deterministic gate over the planner's
  `PlanDiff` (pinned slot unchanged, every assigned recipe has servings, skips
  are explicit, leftovers point to an earlier source meal, no banned/allergen/
  disliked ingredient). First failure wins. The repeat-window check is deferred
  (it needs a `repeat_window` household preference — a product decision; faking a
  default would be less correct than not checking).
- The Orchestrator gates the plan apply on the verifier: pass → apply + commit;
  fail → record the run as `Failed` with a structured `code` and an
  `{:edit_plan, slots}` repair action, applying nothing. A verifier failure is a
  successful dispatch of a failed run, not an infrastructure error.
- Web: the receipt renders a per-code, localized (en/sv) failure message and an
  "Edit the plan" link; the planner reads a `focus` query param and highlights
  the offending slot(s), completing the repair loop.

### Context capsules (§A.4)

The junk-drawer system prompt is replaced by typed, per-run-declared context
capsules — the model's standing context is now auditable ("what did the model
see?" = the run's capsule list), independently testable, and free of ambient
string concatenation.

- `Tore.Harness.Capsule` behaviour (`build/1` + `to_prompt/1`) and
  `Tore.Harness.Capsules.compose/2` — the only assembler; a capsule a run did
  not list is not in its prompt.
- Four capsules with a real consumer today, each a typed struct that fetches and
  summarises its own data (the compactness rule lives in the capsule):
  `HouseholdPreferencesCapsule`, `ActiveInsightsCapsule` (≤5),
  `WeekPlanCapsule` (typed per-day status), `PantryBeliefsCapsule`
  (names capped at 20 + a count).
- The planner run and the chat handler now declare their capsule list and
  compose it; the date and active week-mode stay as small inline framing. The
  planner's doubled role section (its own preamble plus the chat role text) is
  removed.
- `Tore.Chat.SystemPrompt.build/0` deleted — fully replaced by capsules.

### Weekly auto-planning (`:weekly_planning_run`, PlanMyWeek)

A headless harness run that fills the upcoming week's empty, unpinned dinner
slots, triggered by the Saturday cron.

- `:weekly_planning_run` reuses the planner's pure tool loop, the four context
  capsules, and `PlanVerifier`, via an extracted `run_planner_loop` helper shared
  with `:planner_command_run` (the planner clause is a behaviour-preserving
  refactor over the new `run_dispatch` + `run_planner_loop` helpers). Higher loop
  caps (10 round-trips / 25 action calls). Fills empty + unpinned slots only;
  pinned and assigned days are left untouched; the apply is atomic
  (verifier-gated).
- `PlanningHandler.plan_upcoming_week/0` is the cron entry; the Saturday 18:00
  Quantum job now targets the upcoming (next Mon–Sun) week via the harness. With
  no LiveView session the filled week surfaces through the Projector when the
  user next opens `/plan`; they edit individual slots with the existing modal.
- Removed the old one-shot `generate_plan` path — `PlanningHandler.generate_plan/3`,
  `Planning.Commands.GeneratePlan`, `Planning.Events.PlanGenerated` (whose evolve
  clobbered pins), the `@llm.generate_plan/1` callback + adapter impl, the
  `:generate_plan` SpendGuard entry, and the Prep page's "generate plan" button.
  The prep *guide* (`PrepHandler.generate_guide`) is independent and unchanged.
  The `feature_label("generate_plan")` Settings clause is kept — it labels
  historical `ai_operations` cost rows, not a live caller.

### Capture / Shop vocabulary rename

Aligned code with the SPEC's adopted UI vocabulary.

- `Tore.Chat.ChatHandler` → `Tore.Capture.Conversation` (`handle_text/2` →
  `reply/2`); `ChatLive`/`KioskChatLive` → `CaptureLive`/`KioskCaptureLive`;
  routes `/chat` → `/capture`, `/kiosk/chat` → `/kiosk/capture`. The dead
  `Tore.Chat.WeekContext` (superseded by `WeekPlanCapsule`) is deleted, retiring
  the `Tore.Chat` namespace.
- `Tore.Groceries` aggregate → `Tore.Shop`; `GroceryLive` → `ShopLive`; route
  `/groceries` → `/shop`; event-store stream key `grocery_list:` → `shop_list:`
  and the PubSub topic `grocery_list` → `shop_list`; nav label → "Shop"/"Inköp".
  The grocery-list aggregate and its surface now share one name.
- Kept: `Tore.Handlers.GroceriesHandler` (a Tiger-Style rename of the whole
  handler family is a separate spec) and the cross-feature grocery vocabulary
  (`GroceryDiff`, `GroceryVerifier`, `resolve_grocery_item`,
  `:grocery_reconciliation_run`, `:grocery_checkoff`) — those name the grocery
  domain concept used by other features, not the Shop surface.
- SPEC.md line 69 + module map updated to match (overriding the earlier "stream
  stays named groceries" note; safe pre-production with no persisted events).

### Fixed

- Event-store JSON round-trip downgraded atom/Decimal event fields on replay;
  `Run.load` now rehydrates them (`cost_usd` → Decimal; `phase`/`surface`/
  `step_kind` and `RunSummary` outcome/count keys → atoms via explicit closed
  maps, load-order independent to survive cold-boot Projector replay).
- `PlannerAgent` assigned a unique `step_index` per trace entry (was colliding,
  violating the `ai_operations` unique constraint) and coerces a float
  `cost_usd` from the LLM into a Decimal.
- Planner dispatch in `PlannerLive` clears the spinner and flashes on failure
  instead of hanging on a silent crash.
- `FailureRecorded` round-trip: `repair_action` is encoded as a map on write and
  decoded back to `{:edit_plan, slots}` via a literal map on read, and
  `failure_code` decodes via a literal map for the known verifier codes — both
  cold-boot safe (no `String.to_existing_atom`), so a fresh Projector boot can't
  downgrade a verifier code to a string the receipt would fail to match.
