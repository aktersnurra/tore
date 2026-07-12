# AI-First Redesign — Design Spec

_Tore · Brainstorming session 2026-05-28_

---

## Core Philosophy

**The app has two modes: cooking mode and planning mode.** The home screen is cooking mode — tonight, right now, low friction. The week view is planning mode — thinking ahead, adjusting the plan.

**Risk-tiered actions, not uniform act-then-undo.** Actions are classified by reversibility:
- **Tier 1 — Trivially reversible** (add pantry item, add grocery item): act immediately, toast confirmation, undo chip in toast.
- **Tier 2 — Recoverable with effort** (swap meal slot, skip meal): act immediately, toast with undo. Undo is a compensating event.
- **Tier 3 — Destructive or hard to reverse** (clear pantry, delete recipe, purge week plan): confirm before acting. One confirmation step, no confirmation theatre for simple things.

**Background AI produces drafts, never silent mutations.** Scheduled jobs (plan generation, insights synthesis) write to a `drafts` state. The draft is surfaced to the user with a one-tap accept. Once accepted, the plan becomes active. The AI never silently replaces an accepted plan. Replanning mid-week always produces a draft first.

**The AI is infrastructure, not a feature.** The plan exists before you open the app. The grocery list is already built. The AI's work happens in the background — you live with the output and nudge when needed.

**The app is not allowed to nag.** No guilt, no streaks, no "you haven't updated your pantry in 14 days." It is ready when you come to it.

**Voice: warm but brief.** The AI speaks like a knowledgeable friend who left a note on the counter. "You've got a good week ahead — roast chicken tonight sets up the next three days."

**The cascade model is load-bearing.** Weekly meal planning follows a batch-cook-and-transform approach: cook a larger component on Sunday (roast chicken, a grain, a sauce), then build weeknight meals from it. The AI reasons from this model at all times. When it reshuffles a slot, it considers what needs to be prepped the day before, what downstream meals depend on the change, and whether the grocery list needs updating. "I want fried rice Wednesday" means the AI also ensures a rice or chicken component is planned for Tuesday, and updates everything accordingly.

**Cascade metadata lives in the plan.** Each plan slot carries lightweight metadata: `role` (anchor / derived / standalone), `produces` (list of component tags), `consumes` (list of component tags). This enables downstream awareness without re-deriving it from the prompt every time, and lets the UI show "uses Sunday's chicken" without an LLM call.

**Staleness is explicit.** When a plan slot is stale (pantry changed, deal expired, ingredient no longer available), the slot shows a staleness indicator. Same for grocery lists and prep guides. Stale ≠ wrong — it just means a re-check is warranted.

**Recipe generation is guarded.** When the AI suggests recipes, it first searches the existing catalog. If no catalog match fits, it may generate a new recipe — but only when the user explicitly asks to "find something new" or the catalog has no suitable option. Catalog-first is always the default.

---

## Phone UI

### Home Screen (cooking mode)

**Top half — Tonight:**
- Recipe name, large. Food photo alongside it (not behind text — accessibility and readability).
- One line of AI commentary: contextual, warm, specific. "Uses Sunday's chicken — should be quick." Generated once daily, cached. Never generic.
- Prepped components visible if relevant: "✓ Chicken already done" if a component from an earlier slot is in pantry.
- Two buttons:
  - **Start cooking** — opens the recipe detail
  - **Something else** — shuffle. AI picks an alternative that works with what's already prepped, replans downstream if needed, updates grocery list, shows toast. No confirmation step (Tier 2 — recoverable).

**Bottom half — The week strip:**
- Compact horizontal day cards. Today highlighted. Each day shows meal name and food photo thumbnail.
- Tap any day to open an expanded sheet for that slot (same structure as tonight's card, plus slot controls — see Week View).
- No calendar grid.

**FAB — bottom right:**
- Persistent floating action button, always accessible.
- Labelled "Ask Tore" or "Tell Tore" depending on context (cooking question vs action intent).
- Opens the AI chat interface (see AI Assistant section below).

---

### Week View (planning mode)

- Full week as scrollable day cards with food photos.
- Tap a card to expand it as a sheet. The sheet shows: recipe name, photo, cascade notes, and three slot action buttons: **pin**, **something else**, **skip**.
- Inline buttons are NOT shown on the collapsed cards — only in the expanded sheet.
- **Accept draft** button at the top if a new plan draft is pending. One tap to accept.
- **Regenerate plan** at the top — full LLM replan respecting any pins. Always produces a draft.
- Plan history: navigate to previous weeks.
- Slot state includes: `assigned`, `pinned`, `skipped`, `flexible` (AI may adjust), `draft`.

---

### Grocery List

- Grouped by category. Check items off. Real-time sync across phone and kiosk via PubSub.
- Manual add via text input or via AI chat ("add 1 kg chicken").
- Checked items flow to pantry automatically.
- Staleness indicator if the list is based on a plan that has since changed.

---

### Recipes

- Search + filter by tags, time, type. Sort by last used / most used / recently added.
- Each recipe shows cascade notes where relevant ("produces leftover for Tuesday").
- Add via URL scrape or via AI chat ("find me a quick pasta recipe").
- AI searches catalog first. New recipe generation requires explicit "find something new" intent.

---

### Pantry

- Read-only inference view: "here's what we think you have." Not a management screen.
- Each item carries a confidence level: `confirmed` (user explicitly added), `probably_have` (checked off grocery list), `maybe_have` (inferred from plan history), `stale` (not seen in >2 weeks), `removed` (user deleted).
- Lightweight correction: tap an item to remove, adjust quantity, adjust expiry, or mark as confirmed.
- Primary input: AI chat, checked-off grocery items, or receipt/fridge photo via chat.
- Items surface with their confidence level in the AI's system prompt — the AI reasons accordingly ("you probably have chicken").

---

### Insights (weekly, AI prose)

- Natural language observations synthesised from planning events.
- "You skip Thursdays often — the plan has been adjusted to account for this."
- Updated weekly by a background Quantum job. No rating UI, no user input required.
- Lives in settings/profile area — not in the main nav. Occasional view.

#### Memory model: two tiers

**Tier 1 — Stable patterns (weekly LLM synthesis)**

Stored as a set of insight records rather than a single blob. Each record carries:

```
family_insights (
  id           INTEGER PRIMARY KEY,
  family_id    → families,
  kind         TEXT,   -- "skip_pattern", "cascade_success", "time_preference", etc.
  body         TEXT,   -- NL observation, LLM-written
  confidence   REAL,   -- 0.0–1.0
  evidence     TEXT,   -- JSON array of event IDs that support this insight
  status       TEXT,   -- "active", "superseded", "dismissed"
  generated_at DATETIME
)
```

Benefits over a single blob: individual insights can be dismissed, superseded, or updated independently. Confidence scores inform how strongly each insight is injected into the system prompt. Dismissed insights are excluded from prompts without losing history.

Example insight records:
```
kind: "skip_pattern",    body: "You skip Thursday dinners most weeks — likely eating out.",         confidence: 0.85
kind: "cascade_success", body: "Chicken-based cascades work well and typically survive to Wednesday.", confidence: 0.72
kind: "time_preference", body: "Quick weeknight meals (≤30 min) are more likely to actually get cooked.", confidence: 0.68
```

**Tier 2 — This week context (free, from event store)**

A compact summary of the current week generated cheaply from raw events — no LLM call, just a query and a format. Regenerated fresh on every chat session open and every planning prompt render.

Example:
```
This week: plan generated Saturday. Mon: Roast chicken (assigned). Tue: skipped.
Wed: swapped to pasta. Thu–Fri: unplanned.
```

Tier 2 is never stored — generated on demand from the event store.

#### Synthesis cadence

The weekly job weights events before synthesising:
- `MealSkipped`, cascade failures → high importance (deviations reveal real patterns)
- `RecipeAssigned` after a swap → medium (shows preference)
- `PlanGenerated` with no changes → low (routine, little signal)

This follows the importance-weighted retention approach from the Generative Agents research (Park et al., 2023).

---

### Out of main nav (admin/occasional)

- Cost tracking and analytics (under "More")
- Store configuration
- User management and device tokens
- OpenRouter / LLM settings + cost visibility

Settings stays small. Only what's needed to run the household.

---

## AI Assistant (FAB + Chat)

### Opening

A floating action button, bottom-right, always visible on all screens. Tapping it opens a full-screen chat sheet sliding up from the bottom. The button is labelled "Ask Tore" when the context is informational (browsing recipes, viewing pantry) and "Tell Tore" when the context is action-oriented (viewing plan, grocery list).

### Photo upload entry points

Photo upload is available in two ways:

1. **Via the FAB chat** — always available. Attach one or more photos, optionally with a caption. The pipeline classifies, groups, and routes them (see Photo input section below).
2. **Contextual entry points** — recipe page has a "Add photo" action, pantry page has a camera shortcut. These are sugar: they open the chat with a pre-filled caption ("Here's a photo of my pantry") and immediately trigger the file picker. The same classification pipeline runs regardless of entry point.

There is no separate upload flow per page. The chat is the pipeline. Contextual entry points are shortcuts into it.

### Conversation model

- Message history at top, input + photo button at bottom.
- The AI can both **converse** ("what's in my pantry?") and **act** (updates app state directly).
- After acting, confirms in chat: "Done — added 1 kg chicken to pantry, expires Monday." The underlying screen updates live via PubSub.
- **Undo** appears as a tappable chip in the AI's response for Tier 1 and Tier 2 actions.
- No approval step for Tier 1/2. Tier 3 actions surface a confirmation chip in chat before executing.
- Act first, undo if wrong (for Tier 1/2).

### AIOperation / correlation

Every AI action carries a `correlation_id` and is logged to an `ai_operations` table:

```
ai_operations (
  id              INTEGER PRIMARY KEY,
  correlation_id  TEXT UNIQUE,
  family_id       → families,
  kind            TEXT,    -- "plan_swap", "pantry_add", "grocery_add", etc.
  payload         TEXT,    -- JSON, input to the action
  result          TEXT,    -- JSON AIActionResult
  undo_op_id      INTEGER, -- references ai_operations for compensating operation
  inserted_at     DATETIME
)
```

`AIActionResult` structure:
```json
{
  "changed": [
    {"entity": "plan_slot", "id": 42, "field": "recipe_id", "from": 7, "to": 12},
    {"entity": "grocery_item", "id": 88, "op": "added"}
  ],
  "undo_operation_id": "op_abc123",
  "summary": "Swapped Monday dinner to pasta. Added pasta and parmesan to grocery list."
}
```

This enables CRUD undo (pantry updates, grocery adds) that don't have a compensating event in the event store. The `undo_op_id` points to a pre-computed compensating operation that can be replayed directly.

AI operations are idempotent: replaying the same `correlation_id` is a no-op. The photo pipeline also generates a `correlation_id` per upload batch — re-submitting the same photo set returns the cached result.

### Actions the AI can take

| Domain | Actions | Tier |
|---|---|---|
| Planning | Assign recipe to slot, swap recipe, skip meal, pin slot | 2 |
| Planning | Reshuffle full week | 3 |
| Grocery list | Add item, remove item | 1 |
| Pantry | Add item (with quantity + expiry), remove item, update quantity | 1 |
| Pantry | Clear pantry | 3 |
| Recipes | Suggest alternatives for a slot | 1 |
| Recipes | Answer questions about a recipe | 1 (informational) |

### Photo input

Photo upload lives in the chat (or via contextual shortcuts that open the chat).

**Flow:**
1. User attaches one or more photos, optionally with a caption
2. Each photo is classified independently — cheap vision call per photo to identify: receipt / recipe / pantry items / fridge contents. Each classification carries a confidence score (0.0–1.0).
3. Low-confidence classifications (below 0.6) surface a disambiguation message: "I'm not sure what this is — a receipt or a recipe?" with tappable options.
4. Photos are **grouped by class** — all photos classified as `recipe` are sent together in one vision LLM call, etc.
5. Grouping enables multi-photo use cases: 3 screenshots of a recipe page → one extraction call → one complete recipe.
6. Each group routes to its structured output pipeline
7. AI acts or surfaces a review card per group in chat (see below)

**Classification → pipeline routing:**

| Classified as | Pipeline | Default behaviour |
|---|---|---|
| Receipt | OCR → line items → costs + pantry update | Surface review card (line items worth checking) |
| Recipe (photo or screenshot) | Recipe extraction → catalog | Surface review card (validate before saving) |
| Pantry items (packaging, shopping bag) | Vision → item list with quantities + expiry | Surface review card (list of items to confirm) |
| Fridge / ingredients | Vision → "what can I make?" suggestions | Show recipe suggestions in chat, no save |

### Review cards (polymorphic)

The review card appears as a chat message with a **"Review"** button. Tapping it opens a full review screen at `/review/:class/:id`. The screen rendered depends on the content type:

- **Receipt** — editable line items, total, store name. "Nothing saved yet." Confirm → saves to costs, updates pantry.
- **Recipe** — recipe card with ingredients, instructions, tags. "Nothing saved yet." Confirm → saves to catalog. "Save as-is" skips validation.
- **Pantry items** — list of inferred items with quantities and expiry dates. "Nothing saved yet." Confirm → adds to pantry.
- **Fridge/ingredients** — suggested recipes. No save step — just act on a suggestion.

Review is always optional. Dismiss from the chat without opening it. The chat still shows a summary of what was parsed. The review screen always shows "nothing saved yet" until the user confirms — there is no silent save.

---

## Kiosk UI (10.1" touchscreen)

Slim and sleek. No nav clutter. Optimised for large touch targets with potentially dirty hands.

### Home screen

- **Tonight's dinner** — large, prominent. Recipe name, food photo, brief prep note.
- **Upcoming dinners** — the rest of the week below, compact cards.
- **Something else** button — one tap to shuffle tonight's meal. Produces a Tier 2 swap (toast + undo).
- **FAB** — "Ask Tore" chat, bottom-right. For: cooking questions ("what are the steps for the entrecôte sauce?"), last-minute swaps, pantry questions. Opens a simplified chat that is mostly read-only (cooking questions, reading back recipes and steps).

### Preset action buttons

The kiosk exposes a set of large, labelled preset buttons for the most common interactions:
- "What's the recipe?" — opens recipe detail for tonight
- "We're out of [ingredient]" — opens a quick pantry correction flow
- "Swap tonight" — equivalent to "Something else"
- "I cooked it" — marks tonight's meal as done, flows ingredients to pantry depletion

These reduce the need for free-text input with dirty hands. The FAB chat is available for everything else.

### What the kiosk does NOT have

- Insights, cost tracking, user management, settings
- Planning controls (pins, slot toggles, regenerate)
- Receipt or photo upload
- Any admin surface

The grocery list is accessible (check off items), but nothing else from the main nav.

---

## Family Hierarchy

The app is multi-tenant at the family level. A `Family` is the top-level owner of all shared data.

```
Family
  ├── locale (e.g. "sv" — drives recipe translation, ingredient names, UI language)
  ├── home store(s) (determines which deals are scraped)
  ├── preferences (dietary constraints, dislikes — shared defaults)
  ├── recipe catalog
  ├── pantry
  ├── deals
  └── Users (1:n)
        ├── name, role (admin / member)
        ├── auth code (16-digit)
        └── personal preferences (override family defaults)
```

### Preference conflict resolution

When a user's personal preferences conflict with family defaults:

- **Hard constraints** (allergies, dietary restrictions): union rule. If anyone in the family has a nut allergy, the family-level constraint applies to all planning. No overrides.
- **Soft preferences** (dislikes, cuisine preferences): weighted by recency and frequency. A user who consistently skips fish-based meals raises the family-level fish aversion score. The AI uses the aggregate signal, not any individual's raw preference.

The locale on `Family` is the single source of truth for recipe and ingredient name translation, store scraping targets, UI language, and unit conventions (metric/imperial).

---

## Object Storage (Photos)

All photos (receipt images, recipe photos, food images, fridge photos) are stored in **Garage** — a self-hosted, S3-compatible object store. Runs as a single binary on the same VPS alongside Phoenix.

- Elixir client: `ex_aws` + `ex_aws_s3` pointing at the Garage endpoint
- Same API as real S3 — zero vendor lock-in, swappable
- Replaces the current `priv/static/uploads/` disk approach
- Buckets: `tore-recipes` (recipe photos), `tore-receipts` (receipt originals), `tore-uploads` (temporary chat uploads before classification)

Temporary chat uploads live in `tore-uploads` with a short TTL — cleaned up after classification and routing. Permanent assets (recipe photos, receipt originals) move to their respective buckets on confirm.

---

## Chat System Prompt Composition

Every chat session is opened with a system prompt assembled from:

```
1. Role + app context (static)
   "You are Tore, the AI assistant for the Rydholm family meal planning app..."

2. Hard constraints (from Family record)
   Locale, dietary restrictions, allergies — things you must never violate.

3. Stable patterns — Tier 1 (active insight records, sorted by confidence desc)
   Top N insights injected as NL observations. Dismissed insights excluded.

4. This week context — Tier 2 (live from event store)
   Current plan state: what's assigned, skipped, swapped, draft.

5. Situational context (live, per session)
   Today's date, pantry snapshot with confidence levels, current deals (compact).
```

Full recipe catalog is **not** injected — too large. It is passed only when the assistant needs to reason about specific recipes (e.g. a reshuffle command), fetched at dispatch time in the handler.

---

## Key Changes from Current SPEC

1. **Home screen** is "tonight + week strip" not a planner calendar
2. **Food photo alongside recipe name** — not behind text (readability + accessibility)
3. **"Something else"** replaces "Not feeling it" as the shuffle button label
4. **FAB + chat** is primary entry point; contextual shortcuts on recipe/pantry pages open the chat pre-filled
5. **Photo classification** step before routing to structured output pipelines, with confidence scores and disambiguation for low-confidence results
6. **Polymorphic review screen** — one route `/review/:class/:id`, content-driven rendering. "Nothing saved yet" until confirmed.
7. **Pantry confidence model** — confirmed / probably_have / maybe_have / stale / removed
8. **Insights** demoted from main nav — per-record (not single blob), with kind/confidence/evidence/status
9. **Cost analytics** under "More" — not main nav
10. **Kiosk** stripped to: tonight, upcoming, preset action buttons, "Ask Tore" FAB (mostly read-only)
11. **Act-then-undo** replaced by **risk-tiered model** (Tier 1/2 act-then-undo, Tier 3 confirm-first)
12. **AIOperation/correlation layer** for CRUD undo, idempotency, and audit trail
13. **Background AI produces drafts** — never silently replaces accepted plans
14. **Cascade metadata** stored in plan slots (role, produces, consumes) — not only in prompts
15. **Slot states** include `flexible` — explicitly planned but AI may adjust
16. **Staleness indicators** on plans, grocery lists, prep guides
17. **NL commands via chat** map to existing Decider commands — chat is a UI layer, not a new architecture
18. **Family** is a new top-level tenant — owns locale, stores, catalog, pantry; users belong to a family
19. **Preference conflict rules** — hard=union, soft=weighted aggregate
20. **Garage** replaces disk storage for all photos — self-hosted S3-compatible object store
21. **Multi-photo grouping** — photos classified per-image, then grouped by class for a single vision LLM call per group
22. **Family memory** — per-record `family_insights` table with confidence/evidence/status; injected into planning prompts

---

## AI-Native UX Primitives

The following primitives make the app feel genuinely alive without becoming a chatbot. The north star:

> Tore should feel like someone quietly left useful notes on the kitchen counter.

Not alerts. Not dashboards. Not "AI assistant." Just useful, contextual, low-pressure notes.

---

### Counter Notes

Counter notes are ambient, contextual AI suggestions shown inline on relevant screens. They never push notifications and never require action.

A note may propose one or more app commands. If accepted, commands are applied through normal handlers and produce a change receipt with undo. Notes expire automatically when no longer relevant.

**Example on home screen:**
```
Tore noticed
Chicken thighs are on sale at ICA.
Good fit for Sunday curry → leftovers Tuesday.
[Add to week]  [Ignore]
```

**Example on week view:**
```
This week looks fragile
Wednesday depends on Sunday prep, but Sunday has no prep block.
[Fix plan]  [Ignore]
```

**Example on pantry:**
```
Probably have rice
Bought 2 weeks ago. Tore will assume it exists unless corrected.
[Correct]  [Remove]
```

Schema:
```elixir
%CounterNote{
  id: String.t(),
  family_id: integer(),
  surface: :home | :week | :groceries | :pantry | :deals,
  kind: :deal_opportunity | :plan_repair | :pantry_assumption | :habit_pattern,
  title: String.t(),
  body: String.t(),
  commands: [struct()],
  confidence: :low | :medium | :high,
  status: :pending | :accepted | :ignored | :expired,
  expires_at: DateTime.t()
}
```

Notes are generated as a side-effect of plan generation, deal scraping, and the weekly synthesis job. They are stored in SQLite and are surfaced per-screen by querying on `surface + status = pending`.

---

### Change Receipts

Every AI mutation returns a structured change receipt. The receipt shows what changed, why (if useful), and an undo chip when supported.

```elixir
%AIActionResult{
  summary: "Moved salmon to Friday.",
  reason: "Tuesday fish often gets skipped.",
  changes: [
    %{area: :plan, before: "Tue: Salmon", after: "Tue: Pasta"},
    %{area: :plan, before: "Fri: Pasta", after: "Fri: Salmon"},
    %{area: :groceries, before: nil, after: "+ pasta"}
  ],
  undo_operation_id: "op_123"
}
```

Receipts appear as: toast (for background actions), chat response (for chat-initiated actions), or inline counter note (for plan repairs).

---

### Week Modes

Week modes are temporary planning biases applied to the current week only. They do not modify household preferences.

Available modes: `normal`, `low_effort`, `budget_week`, `use_pantry`, `more_leftovers`, `high_protein`, `freezer_week`, `guest_week`.

Selecting a mode triggers a constrained replan (as a draft) respecting pinned meals. The current mode is shown at the top of the week view as a subtle badge. Only one mode active at a time; resetting to `normal` removes all biases.

Prompt fragment injected when a mode is active:
```
Current week mode: Low effort.
Prefer ≤30 minute meals, fewer unique cooking sessions, and more leftovers.
Do not change pinned slots.
```

---

### Plan Health

A compact status for the current plan, shown at the top of the week view:

| Status | Meaning |
|---|---|
| Ready | Plan is complete, prep is covered, groceries are in order |
| Flexible | Plan exists but has unplanned slots or flexible slots |
| Fragile | One or more slots depend on missing prep or unavailable ingredients |
| Stale | Plan, grocery list, or prep guide changed since last sync |
| Unplanned | No plan for the week yet |

Plan health is derived cheaply from event store state — no LLM call. It updates on any plan event via PubSub.

---

### Week Repair

When a meal is skipped, swapped, or moved, Tore checks whether downstream meals, leftovers, prep guide, or grocery list are affected.

- **Small repair** (one slot affected): Tore acts immediately and shows undo.
- **Larger repair** (multiple slots or grocery list changes): Tore creates a counter note proposing the repair.

The user is never punished for skipping. Repair is offered, not imposed.

---

### Cascade Map

The week view may render a compact cascade map showing base meals and derived meals when cascade metadata is present on plan slots.

```
Sunday
Roast chicken  →  Tuesday: Chicken salad  →  Wednesday: Fried rice
(produces: chicken)    (consumes: chicken)     (consumes: chicken + rice)
```

This is explanatory only. Tapping any meal opens the slot sheet to change it. If a base meal changes, the planner checks downstream dependencies via the slot `consumes`/`produces` metadata.

---

### Contextual Command Bar

Planning surfaces include a one-line natural language command bar. It is contextual to the screen — not a general chatbot replacement.

```
Tell Tore what to change…
```

Examples: "make this week cheaper", "no fish this week", "I want fried rice Wednesday", "use the ICA chicken deal".

After submit, commands are parsed and dispatched through `ChatHandler`. A change receipt is shown inline.

---

### Cooking Substitution

On the recipe/cooking screen: "Missing something?" — user taps and types what they lack.

Tore responds with a substitution and optionally rewrites the affected steps for tonight:
```
No crème fraîche →
Use Greek yogurt + a little lemon. Add at the end so it doesn't split.
[Update steps for tonight]
```

This avoids pantry perfection — users correct reality in the moment, not in advance.

---

### Cook Mode

When opening a recipe from the home screen or kiosk, Tore shows a compressed, action-oriented recipe view:

```
Do first: potatoes, preheat oven
While it cooks: sauce, salad
Finish: plate
```

Option: **Make it faster** — Tore rewrites steps with shortcuts (skip sides, use store-bought components).

---

### Kitchen Memory (Insights UI)

The insights page is labelled "Things Tore has learned" — not "Insights" or "Analytics".

Each memory shows:
- The observation
- Short evidence summary ("7 of 10 Thursdays skipped")
- Confidence level
- **Keep / Forget** controls

No ratings, no feedback forms. The user edits memory by forgetting incorrect observations.

---

### Graceful Degradation

Every AI-derived feature must work even if ignored.

- If pantry is wrong → grocery list still works.
- If receipts are not scanned → costs page is less complete, nothing nags.
- If prep guide is stale → recipe pages still work.
- If weekly plan is ignored → home screen shows best-effort suggestions.

No feature may depend on perfect user maintenance. This is a core design law.

---

### AI Source of Truth Rule

The LLM never owns truth. It proposes commands. Handlers validate and apply commands. Current state comes from the event store and CRUD contexts. AI-generated content is always tagged as such and can be rejected or modified.

---

## What Does NOT Change

- Core architecture: Decider pattern for planning + groceries, CRUD everywhere else
- Event store, PubSub, handler pattern
- Phoenix + LiveView + SQLite stack
- OpenRouter LLM behind behaviour/adapter
- Quantum scheduled jobs (Saturday scrape, Saturday plan generation)
- 16-digit account codes + device token auth
- The cascade algorithm as a prompt concern, not a data model concern
