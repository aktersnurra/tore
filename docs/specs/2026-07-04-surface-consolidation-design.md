# Surface consolidation — layers, not pages; predictions, not chat

> Design delta against `UI_SPEC.md` (2026-07-04). Approved decisions from the
> 2026-07-03/04 design discussion. This document changes navigation shape,
> the primary interaction model, receipt placement, and surface compositions.
> It does not change the visual system (UI_SPEC §4) or the harness contract
> (SPEC.md §A) except where §A.9 requires new artifact fields.

## Goal

Fewer destinations, zero archaeology, and as little typing as possible.
Screens map to moments in the food loop, not to data types. Detail arrives
as layers (sheets that expand in place) instead of pages. The LLM's
processing goes into *predicting* the interaction ahead of time, not into
conversation. The interaction hierarchy, in order of frequency:

```
glance  →  tap a predicted action  →  undo if wrong  →  type (rare)
```

Maximum depth from any nav destination: two (surface → sheet).

## Decisions recorded

| Decision | Choice |
|---|---|
| Photo routing in Capture | Keep LLM classification (`classify_image`); explicit intent chips considered and rejected |
| Receipts & reviews | Layered: inline strips + expand-in-place sheets + one review pill on Today; full audit list in Settings; no inbox page in nav |
| Week strip on Today | Cut. The whole week is viewed on Plan, one tap away |
| Deals | Suggestions-only, no browsing surface; deal-linked items must carry exact product identity (brand, size, price, store) |
| Shop grouping | Store sections (already UI_SPEC §6.3 default; confirmed) |
| Navigation | Three tabs (Today · Plan · Shop) + the command pill, a global action, not a tab |
| Primary interaction | The anticipation layer: precomputed one-tap predicted actions replace generic affordances; typing is the fallback for the unpredicted |
| Text/photo entry | One command tray (tap the pill; drag as accelerator): multimodal input, no separate photo vs chat interfaces; no docked command bar anywhere, including Plan |
| Object-scoped commands | Long-press (or the object's existing tap-sheet) opens scoped predictions + a scoped input; touch resolves the referent (no LLM disambiguation) |
| Tone of the entry point | The pill is chrome, not a character — explicitly must not read as a customer-support AI widget |

## 1. Navigation

**Delta to UI_SPEC §3.1–3.3.**

Mobile bottom bar: three tabs with a command pill in the center slot.

```
[Today]  [Plan]  ( pill )  [Shop]
```

- Tap or swipe up on the pill → the command tray rises (§5).
- Long-press the pill → the tray opens straight in camera state.
- The pill is part of the bar's structure — it never floats over content,
  never covers list items, never moves.

Desktop left rail: Today / Plan / Shop, the command input summoned with a
keyboard shortcut (⌘K pattern) or a rail button; Settings at the bottom.

Route map deltas:

```
/shop             (rename from /groceries — completes the Shop rename)
/capture          stays routable (deep links) but presents as the tray
/settings         one page; /settings/memory|pantry|spending become anchors, not routes
/kiosk/capture    (rename from /kiosk/chat)
/prep             removed — prep renders inside Plan
/deals            removed from user-facing routes
inbox/run-review  never in nav; run detail stays routable for deep links, presents as a sheet
```

## 2. The layer doctrine

**Addition to UI_SPEC §4.8 (motion) and §5 (components).**

- The base surface never navigates away for detail. Detail expands in place
  (sheet or expanding card) and dismisses with a flick or scrim tap.
- Motion's only job is continuity: the element you tapped grows into the
  layer; the layer collapses back to it. 200–300 ms, standard curve.
  No decorative motion; respect reduced-motion (§11).
- Every hidden thing has a visible handle. A pill, a strip, a card edge —
  something you can see tells you where the layer lives. No mystery-meat
  gestures. (Bottom-edge swipes are OS territory; Tore's gestures start on
  Tore's own chrome — the pill, a strip, a grabber.)
- LiveView mapping: layers are function components + `JS.transition`,
  driven by `live_patch` where deep-linkable, plain assigns where not.
  No new LiveView modules per layer.

## 3. The anticipation layer

**New; generalizes UI_SPEC §2.3 and the CounterNote machinery.**

The LLM pre-computes the interactions the user was about to have, from
facts and history: insights × weekday ("Tuesdays go quick — swap with
Thursday's easier dish"), pantry beliefs × tonight's recipe ("no heavy
cream — crème fraîche works, you have it"), freezer beliefs × busy-day
insight ("take the frozen bolognese?"), purchase history × current list
("oat milk isn't on the list — you always buy it").

**Mechanism — nothing new in the harness.** These are `CounterNote`s from
the Tier 0 `:ambient_scan_run`: capsule-driven, verified by
`CounterNoteVerifier`, each carrying a `proposed_run` that one tap
dispatches (`started_by: :counter_note_followup`). The catalog grows new
kinds (`:swap_suggestion`, `:freezer_fallback`, `:missing_ingredient`,
`:usual_item_missing`, …) — per SPEC.md §3, extending the catalog, not the
machinery. The scan runs daily and re-triggers on plan/pantry mutation.

**Rule 1 — predictions replace generic affordances; they never add
elements.** The hero card's [Swap] becomes "Swap with Thursday's gratäng".
The Shop add-field's placeholder becomes the predicted item. The cooking
view's ingredient row carries its substitution inline. Same element count;
the intelligence is in the content of actions that would exist anyway.
Today's max-one-counter-note rule (UI_SPEC §6.1) stands.

**Rule 2 — precomputed, never awaited.** Surfaces render predictions
instantly from materialized CounterNotes. No LLM call on page load, no
spinner, no "predicting…" state. If nothing was precomputed, the surface
shows its ordinary generic affordances.

**Rule 3 — dismissal is signal.** A swiped-away prediction tombstones
(existing CounterNote dismissal) and feeds the next memory synthesis; the
system learns what not to predict.

**Shipped** 2026-08 — ambient scan + four kinds + `follow_up` dispatch: the
`:ambient_scan_run` Tier-0 headless run, `proposed_run` sum type
(`planner_command` | `add_item` | `nil`), `CounterNoteVerifier`,
`CounterNotes.follow_up/2` as the single accept-with-effect path, and Rule
1 wiring on Home/Plan/Shop/tray. Deferred: `:deal_opportunity_run`
(SPEC.md §3's original catalog kinds — `:expiring_pantry_match`,
`:cascade_break`, `:unplanned_week`, `:deal_match` — are not implemented;
the shipped scan uses its own four-kind catalog instead); cooking-view
inline substitutions (§11 leaves Cooking mode unchanged).

## 4. The command tray

**Replaces the Capture tab/page (UI_SPEC §6.4 content moves here) and the
docked planner command bar (UI_SPEC §5.4 becomes the tray's input).**

**Tap is the primary affordance; gestures are accelerators, never the only
path.** Tapping the pill opens the tray. Once open (and while opening) it
is draggable — swipe-up users get finger-following, interruptible physics
as a discovered bonus. Everything reachable by gesture is reachable by tap.
Long-press the pill jumps straight to camera state.

The interaction hierarchy the tray sits at the bottom of:

```
no input          predictions inline on the surface (§3)
point at a thing  object sheet: scoped predictions + scoped input (§4.1)
global tray       anything unscoped: photos, free text, plan-the-week
```

Each tier should visibly absorb demand from the one below it.

- **Half state (default):** the predicted actions for the current surface —
  the same CounterNotes from §3, as tappable rows — with one multimodal
  input field (text + camera button) below them. The model's guesses come
  first; typing is what you do when none of them fit.
  **Shipped** 2026-08 — `capture_live.ex` derives the origin surface from
  `return_to`, lists that surface's notes with a `proposed_run` above the
  input, and drops the list once a message is sent in the session (no AI
  branding).
- **Full state:** keep pulling or focus the field — keyboard up, full
  capture surface (UI_SPEC §6.4's layout and result pattern render here).
  Text and photos route through the same classifier-and-dispatch path;
  results render as artifact cards in the tray; state changes leave receipt
  strips on their home surfaces (§5).
- **No transcript.** Closing the tray discards the view; effects persist as
  receipts and run history. Reopening shows fresh predictions, not history.
- **One input, no modes.** There is no separate "photo interface" vs "pure
  chat" — intent is resolved after capture (classification), never asked
  for before.

**Not a support widget.** The pill and tray must never read as the
embedded customer-support AI bubble every site has:

- No sparkle/robot/assistant iconography, no "Ask AI" label, no branding
  of the model as a persona.
- Never opens itself, never pops a proactive message, never pulses,
  bounces, or badges for attention. Silent until touched.
- Sits in the bar's structure, not floating over content in a corner.
- Tray copy is domain actions in matter-of-fact voice — no greeting, no
  avatar, no "How can I help?".

The pill is chrome — the app's command surface, like an address bar — not
a character living in the app.

### 4.1 Object sheets — commands attach to nouns

Most utterances are about a thing already on screen ("swap *Tuesday*",
"I don't have *heavy cream*", "more of *this*"). So commands attach to
objects: long-pressing a plan slot, the tonight card, or a grocery row —
or opening the object's existing tap-sheet where one exists (UI_SPEC §6.2
slot interactions) — raises a scoped sheet:

```
Tuesday · Salmon pasta
─────────────────────────────
Swap with Thursday's gratäng      ← scoped predictions (§3)
Skip — Tuesdays usually go quick
Make leftovers from Sunday
─────────────────────────────
[ input field scoped to Tuesday ]
```

Anything typed in the scoped field already means that object — the
dispatched run receives the referent as a pre-resolved handle.

**Why this is architecture, not garnish:** the harness's hardest problem is
reference resolution (SPEC.md §A.6.2 — `resolve_slot("the salmon slot")`,
ambiguity, `ask_user`, confidence thresholds). Touch resolves the referent
with certainty: the object sheet constructs the handle directly
(`source: :direct_touch`, confidence 1.0), skipping the resolver round-trip
and deleting the ambiguity failure mode for every command that starts from
an object. Desktop maps one-to-one: right-click → object sheet, ⌘K → tray.
The kiosk gets neither.

**Shipped** 2026-07 for plan slots (scoped input + direct-touch handles +
recipe refs); tonight-card/grocery-row long-press and NL `resolve_slot`
ride Plan 3.

**Shipped** 2026-08 — tonight card and grocery rows: a plain `app.js`
`LongPress` hook (500 ms) opens the tonight card's sheet scoped to today
(reuses the plan-slot `scoped_slot` dispatch verbatim) and a grocery row's
item sheet. Grocery scoping is a text referent through `Capture.Router`
("[The user is referring to the grocery item ...]"), not a resolved
handle — `ResolvedGroceryItem`/`ResolvedPantryItem` handles and item-scoped
predictions on the grocery sheet stay deferred until grocery action tools
exist to consume them (SPEC.md §A.6.2). `resolve_slot` shipped structural,
per §3 above and SPEC.md §A.6.2 — no ref/registry indirection, since the
slot domain is closed.

## 5. Receipts and reviews, layered

**Delta to UI_SPEC §7.1 (placement/behavior; content unchanged) and to the
route map. Replaces `inbox_live` and `run_review_live` as destinations.**

- **Receipt strip.** When a run applies, a one-line receipt slides in at the
  bottom of the run's `surface` (the `KitchenRun.surface` field: Plan runs on
  Plan, grocery/pantry runs on Shop, capture ingestion in the tray).
  A run that changed multiple domains still gets one strip, on its starting
  surface; the expanded sheet shows all changed domains (UI_SPEC §7.1 already
  renders Plan + Shop sections in one receipt). If the user isn't on that
  surface when the run applies — scheduled runs especially — the receipt is
  simply unseen and reaches them through the review pill. Content per
  UI_SPEC §7.1: summary counts + `[Undo] [See changes]`.
- **Receipt sheet.** Tapping the strip expands it in place into the full
  receipt: diff rows (§16.4 alphabet), "Why this?", Undo. Flick down to
  dismiss. `run_review_live`'s content becomes this sheet.
- **Review pill.** Today carries one quiet pill — `2 to review` — rolling up
  unseen receipts and `:needs_user` runs across all surfaces. It expands
  into the same sheets. Not a red badge, not a count of unread anxiety:
  a calm handle, invisible when there is nothing to review.
- **Audit list.** Settings gains a **Run history** section: the full
  kitchen-runs table (SPEC.md success criterion 11) for the rare
  "what happened last month?" dig. Reachable, never surfaced.
- **Kiosk shows no receipts, pill, or reviews.** The kiosk shows the state
  of dinner, never the process of the system.

## 6. Today

**Delta to UI_SPEC §6.1.**

Composition, top to bottom:

```
Header      Today · date · avatar→Settings
Hero        Tonight card — actions are predicted where possible (§3):
            [Start cooking] stays; secondary action reads e.g.
            "Swap with Thursday's gratäng" instead of generic "Swap";
            a missing-ingredient line renders on the card when beliefs
            say an ingredient is absent
Secondary   Tomorrow compact card
            One counter note (max, unchanged)
            Review pill (only when something needs eyes)
Bar         [Today] [Plan] (pill) [Shop]
```

Removed: the week strip and the floating Capture/Ask FAB (the pill replaces
it). Today's rules (§6.1) gain one line:

```
Today must not duplicate the week — that is Plan.
```

## 7. Plan

**Delta to UI_SPEC §6.2.**

- **No docked command bar.** Plan commands go through the tray, whose
  half state on Plan shows plan-shaped predictions (skill chips like
  `Plan my week` / `Use the deals`, swap suggestions, fill-the-gap
  proposals). UI_SPEC §5.4's command-bar behavior spec applies to the
  tray's input field.
- **Prep folds in.** The prep guide renders inside the week — an expandable
  prep layer anchored to the day it serves. `/prep` is removed as a
  destination; `prep_live` content becomes a sheet.
- **Recipes stay search-first.** Assigning a slot opens the recipe search
  sheet; recipe detail is a sheet from there. No recipe library in nav.
- **Deals are suggestions only.** No deals rail, no deals browsing surface.
  Deals reach the user exactly three ways: the `UseTheDeals` skill chip, a
  `:deal_match` counter note, and per-slot rationale ("pork on sale at
  ICA"). `deals_live` is removed from user-facing routes.
- Receipt strips from plan runs appear here per §5.

## 8. Shop

**Delta to UI_SPEC §6.3 (small).**

- Grouping: store sections — confirmed as decided, no change to the §6.3
  group list.
- **Deal-linked rows carry exact product identity.** When an item is on the
  list because of a deal, the row names the actual product, not the generic
  ingredient:

  ```
  ☐ Feta
      Apetina 200 g · 25 kr · ICA
  ```

  Generic name stays primary (that's what you scan for in the aisle); the
  deal product line is tertiary weight. Rationale: multiple brands of the
  same ingredient exist; a deal is only real if you buy the right one.
- **Predicted adds** (§3 `:usual_item_missing`) surface as the add-field's
  placeholder or a single ghost row — never a stack of suggestions.
- Receipt photos: long-press the pill (tray opens in camera state). The
  store is where receipts happen; the gesture is one press away from Shop.

## 9. Settings

**Delta to UI_SPEC §6.7 and route map.**

One flat scrollable page, anchored sections, zero sub-pages:

```
Household preferences
Kitchen Memory
Pantry belief        (read-only "here's what we think you have")
Spending             (current cost_live content)
Run history          (audit list, §5 above)
Devices
Account
```

Section detail that needs interaction (e.g. a receipt in Spending, a run in
Run history) opens as a sheet. `/settings/memory`, `/settings/pantry`,
`/settings/spending` become in-page anchors.

## 10. Artifact-boundary implications (SPEC.md §A.9)

The UI needs fields the harness spec must name — per §A.9 that is a SPEC.md
amendment, listed here for the implementation plan:

1. **Deal product identity.** `DealsDigestCapsule` entries and any
   deal-attributed grocery item (in `GroceryDiff` / shop aggregate items)
   carry `product_label`, `package_size`, `price`, `store` — not just the
   ingredient name. Rationale strings citing a deal name the exact product.
2. **Receipt seen-state.** The review pill needs "unseen receipts" — runs
   carry a `seen_at`-style projection (likely on the run-receipts
   projection, not the aggregate). `:needs_user` runs are always unseen
   until answered or discarded.
3. **CounterNote catalog growth.** New kinds `:swap_suggestion`,
   `:freezer_fallback`, `:missing_ingredient`, `:usual_item_missing`, each
   with trigger rule and `proposed_run`, per the SPEC.md §3 kind table.
   `CounterNote` gains a `surface` targeting field if it doesn't already
   carry one, so predictions land on the right tray.
4. **Ambient scan re-triggers.** Besides the daily 07:00 job, the scan
   re-runs on plan or pantry mutation (debounced) so predictions stay
   fresh. Still Tier 0, cheap model tier, SpendGuard-gated.
5. **Direct-touch handles.** SPEC.md §A.6.2's handle types gain a
   `source: :direct_touch` provenance with confidence 1.0, constructed by
   the UI when a command originates from an object sheet. Action tools
   accept them like resolver-produced handles; `resolved_in_run` semantics
   apply unchanged (the handle is minted for the run the sheet dispatches).

No other harness changes: receipts, undo, diff rows, and the runs table all
exist; this design only moves where they render.

## 11. Out of scope

- Visual system changes (colors, type, shape — UI_SPEC §4 stands).
- Kiosk changes beyond the naming already in SPEC.md.
- Voice input, native apps, notifications (SPEC.md non-goals).
- Rebuilding surfaces not named here (Cooking mode unchanged, except
  inline substitution hints from §3 which reuse the counter-note slot).

## 12. Implementation order (for the plan)

1. Nav shell: 3 tabs + command pill; `/shop` rename; tray skeleton
   (half/full states) replacing the Capture page.
2. Receipt strip + sheet components; wire to existing run_receipts
   projection; review pill on Today; remove inbox/run-review from nav.
3. Today: drop week strip, add pill; hero card predicted-action slots
   (render generic until predictions exist).
4. Settings flattening (+ Run history section; fold Spending in).
5. Plan: tray predictions (skill chips first — they need no new scan),
   prep layer; remove `/prep`, `/deals` from user routes.
6. Object sheets: enrich the existing slot tap-sheet with a scoped input
   and direct-touch handles (SPEC.md amendment #5); extend to tonight
   card and grocery rows via long-press.
7. Anticipation layer backend: new CounterNote kinds + scan re-triggers
   (SPEC.md amendment #3/#4), then wire predicted content into hero
   card / Shop placeholder / tray half state / object sheets.
8. Shop: deal product line (needs SPEC.md amendment #1 first).

Each step is independently shippable; UI_SPEC gets amended alongside the
step that changes it.
