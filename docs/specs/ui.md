It assumes Tore is **not** a CRUD planner with AI bolted on. It is a **calm, agentic kitchen operating surface**: the plan is already there, the grocery list is reliable, and the AI is visible only when useful. That lines up with your current product philosophy: good guesses, easy corrections, no nags, and the grocery list as reliability anchor.

---

# Tore UI/UX Spec — Calm Futuristic Kitchen OS

## 1. Product feel

Tore should feel like:

> **A quiet household food-control surface from the near future.**

Not a chatbot.
Not a spreadsheet.
Not a recipe Pinterest clone.
Not a dashboard.
Not “AI magic.”

The UI should feel **calm, precise, warm, and quietly intelligent**. The app should look futuristic through **layout, motion, restraint, and contextual intelligence**, not through neon gradients, glassmorphism spam, fake 3D, or sci-fi decoration.

The product personality:

```md
Warm, not cute.
Futuristic, not cyberpunk.
Minimal, not empty.
Intelligent, not chatty.
Useful, not impressive.
Calm, not sterile.
```

The UX foundation is aligned with established usability guidance: users need system status, real-world language, undo/control, consistency, error prevention, recognition over recall, flexibility for power users, and aesthetic/minimal design. ([Nielsen Norman Group][1]) AI-specific UX also needs careful expectation-setting, graceful failure, learning over time, and user control, because AI systems behave probabilistically and change over time. ([Microsoft][2])

---

## 2. Core UX principles

### 2.1 One surface, one job

Every screen must have one primary job.

```md
Home      → What matters tonight?
Plan      → What should the week look like?
Shop      → What do we need to buy?
Capture   → What can Tore understand from text/photo?
Cook      → What do I do right now?
Settings  → What does Tore know and how does it behave?
```

A screen fails review if it has more than one dominant action.

### 2.2 Agentic, but never mysterious

Tore may act proactively, but every agentic change must have:

```md
What changed
Why it changed
Undo
Optional detail
```

Default state:

```md
Tore adjusted the week
3 meals updated · grocery list refreshed

[Undo] [See changes]
```

Expanded state:

```md
Changed
- Tuesday: Salmon pasta → Pork skewers
- Friday: Empty → Leftovers from Wednesday
- Grocery list: + pork loin, + cucumber, - salmon

Why
- Pork matched this week's ICA deal
- Friday is often skipped unless it is leftovers
- Wednesday recipe scales well to two meals
```

This follows the same logic as good system-status and user-control design: the system can act, but users must understand outcomes and retain control. ([Nielsen Norman Group][1])

### 2.3 Surface intelligence inline, never as notifications

Ambient intelligence appears only where it helps:

```md
Home:      "Use the yoghurt before Friday?"
Plan:      "Thursday is fragile. Make it leftovers?"
Shop:      "This list changed after Tuesday's swap."
```

No push notifications. No nags. No streaks. Your current spec already requires proactive intelligence to appear inline and explicitly forbids interruption. 

Plan 3 built predictions on Today, the plan slot sheet, Shop and the Capture tray. They were removed on 2026-11-08 (SPEC.md §3).

### 2.4 The user never has to maintain the machine

The UI must not ask the user to manage pantry, maintain datasets, rate meals, or explain every skip.

Tore learns from behavior. It should infer gently, expose memory when useful, and allow correction. This matches the current spec’s event-stream learning model and its rule that there is no rating UI or “how was dinner?” prompt. 

### 2.5 Chat is a capture surface, not the app

Chat exists, but it should not become the main UI.

The app’s best interactions should be:

```md
Tap
Swipe
Inline command
Camera capture
Undo
```

Chat is for ambiguous input, photos, and complex commands. The main product should remain visual and direct.

---

## 3. Information architecture

### 3.1 Primary nav

Use **three main destinations plus one action** on phone/laptop:

```md
[Today]  [Plan]  ( pill )  [Shop]
```

Capture is not a destination — it is the command pill in the center slot of
the bottom bar (tabs are destinations; actions are buttons). Tapping the
pill opens Capture as a slide-up sheet over the current surface; closing it
returns exactly where you were (`return_to`). The pill is neutral chrome:
no AI iconography, no label, no animation, no badge — never a
support-widget bubble.

Settings is accessed from the desktop header / profile affordance, not the
mobile bar.

Do not expose these as primary tabs:

```md
Recipes
Pantry
Deals
Costs
Prep
```

Those are system resources, not user destinations. A pending review is reached
through Today's review pill, never from the nav.

### 3.2 Route map

```md
/              → Today
/plan          → Plan
/shop          → Shop
/capture       → Capture (routable for deep links; presents as a sheet)
/cooking       → Cooking mode
/settings      → Settings
/settings/pantry
/settings/costs
/review        → Opens the oldest pending review (not in nav; via review pill)
/runs/:id      → Run review: a receipt to check, or a recipe proposal to save or discard (not in nav; deep-linkable)
/recipes       → Recipe catalog (system resource, not in nav)
/prep          → Prep guide (system resource, via Plan's "Prep this week")
```

Surfaces stay routable so deep links work, but capture and run-review are
presented as layers, not destinations.

### 3.3 Navigation behavior

On mobile:

```md
Bottom bar:
[Today] [Plan] (pill) [Shop]
```

On desktop/tablet:

```md
Header:
Today · Plan · Shop · Capture · Settings
```

---

## 4. Visual design direction

## 4.1 Visual metaphor

Tore should look like **a soft instrument panel for the kitchen**.

Use:

```md
Large calm surfaces
Warm near-neutral backgrounds
Soft depth
Precise typography
Sparse accent color
Generous spacing
Contextual cards
Subtle motion
```

Avoid:

```md
Harsh white SaaS dashboards
Generic Tailwind cards everywhere
Dense tables
Colorful recipe-app chaos
Emoji decoration
Overused glass blur
Neon cyberpunk gradients
AI sparkle icons everywhere
```

## 4.2 Theme name

```md
Theme: Warm Future
```

## 4.3 Color tokens

Use a small semantic palette.

```css
--bg:              #F4EFE7;  /* warm oat */
--surface:         #FFFCF6;  /* warm porcelain */
--surface-raised:  #FFFFFF;
--surface-muted:   #ECE3D7;

--ink:             #1F211D;  /* soft black */
--ink-muted:       #6C6A61;
--ink-faint:       #9A9488;

--line:            #DED4C6;
--line-strong:     #C8BAA8;

--accent:          #556B5F;  /* muted sage */
--accent-ink:      #F8F4EA;
--accent-soft:     #DDE7DF;

--attention:       #A56A43;  /* warm copper */
--attention-soft:  #EFE0D3;

--danger:          #9B3E35;
--danger-soft:     #F1DAD6;

--success:         #536F4E;
--success-soft:    #DDE8DA;

--focus:           #1F211D;
```

Dark mode later:

```css
--bg:              #171814;
--surface:         #20211C;
--surface-raised:  #292A24;
--surface-muted:   #2F3029;

--ink:             #F6F0E6;
--ink-muted:       #B8B0A4;
--ink-faint:       #827B71;

--line:            #3C3A33;
--line-strong:     #565247;

--accent:          #B9C8B7;
--accent-ink:      #171814;
--accent-soft:     #303A32;
```

Color must communicate hierarchy and state, not decoration. Material Design’s current system guidance emphasizes design tokens and accessible color schemes that communicate hierarchy, state, and brand. ([Material Design][3])

## 4.4 Contrast and accessibility

Minimum requirements:

```md
Normal text:        4.5:1 contrast minimum
Large text:         3:1 contrast minimum
UI components:      3:1 contrast minimum against adjacent colors
Focus indicator:    visible, high contrast, not color-only
Touch targets:      44 × 44 px minimum, 48 × 48 preferred
```

WCAG 2.2 requires at least 4.5:1 contrast for normal text, 3:1 for large text, and 3:1 for UI components and meaningful graphical objects. ([W3C][4]) Apple’s button guidance also uses at least a 44×44 pt hit region as a general rule for selectable controls. ([Apple Developer][5])

## 4.5 Typography

Use one excellent sans-serif, no more.

Recommended:

```md
Primary: Inter, Geist, SF Pro, or system-ui
Numbers: tabular figures enabled
```

Type scale:

```css
--text-xs:   12px;
--text-sm:   14px;
--text-md:   16px;
--text-lg:   18px;
--text-xl:   22px;
--text-2xl:  28px;
--text-3xl:  36px;
--text-hero: 52px;
```

Rules:

```md
Use large type for decisions.
Use small type only for metadata.
Never use low-contrast tiny labels for important information.
One screen should have one typographic hero.
Use tabular numbers for servings, times, quantities, prices.
```

## 4.6 Shape

```css
--radius-sm:  10px;
--radius-md:  16px;
--radius-lg:  24px;
--radius-xl:  32px;
--radius-pill: 999px;
```

Rules:

```md
Primary cards:      24–32px radius
Buttons:            pill or 16px radius
Inputs:             pill for command/capture; 16px for forms
Images:             20–28px radius
Bottom sheets:      28px top radius
```

The style should be soft and physical, but not childish.

## 4.7 Elevation

Use almost no shadow.

```css
--shadow-soft: 0 12px 40px rgba(31, 33, 29, 0.08);
--shadow-float: 0 20px 80px rgba(31, 33, 29, 0.14);
```

Default cards should use border + background. Shadows are reserved for:

```md
Floating command bar
Bottom sheets
Run receipt drawer
Active dragged meal
```

## 4.8 Motion

Motion must explain causality.

Use motion for:

```md
Plan changes
Undo
Opening run receipt
Moving a meal between days
Checking grocery items
Camera capture → parsed result
AI thinking → applied result
```

Do not use motion for:

```md
Decoration
Looping ambient effects
Bouncy delight
Confetti
```

Timing:

```css
--ease-standard: cubic-bezier(.2, .8, .2, 1);
--ease-exit:     cubic-bezier(.4, 0, 1, 1);
--duration-fast: 120ms;
--duration-md:   220ms;
--duration-slow: 360ms;
```

Material’s interaction guidance emphasizes visible states, consistent state application, and accessible visual indicators. ([Material Design][6])

---

# 5. Component system

## 5.1 App shell

### Mobile shell

```md
Top:
- Household name or Tore wordmark
- Current week/date context
- Settings/avatar button

Main:
- Single-column content
- Max width 480px
- Bottom padding for nav + command bars

Bottom:
- 4-tab nav
```

### Desktop shell

```md
Left rail:
- Tore wordmark
- Today
- Plan
- Shop
- Capture
- Settings

Main:
- Max width depends on surface
- Plan may use full width
- Today/Shop/Capture stay readable and centered
```

## 5.2 Card types

### Hero card

Used for the most important thing on a screen.

```md
Examples:
- Tonight’s meal
- Current week plan status
- Grocery list readiness
```

Structure:

```md
Eyebrow
Title
One-line summary
Primary action
Optional secondary action
Image or visual anchor
```

### Decision card

Used when the user must pick or confirm.

```md
Examples:
- Three fridge-photo suggestions
- Swap recipe suggestions
- Deal opportunity
```

Rules:

```md
Max 3 options.
Each option has one primary action.
No dense metadata.
No more than two tags.
```

### Receipt card

Used after an agentic operation.

```md
Tore adjusted the plan
3 meals changed · 12 grocery items updated

[Undo] [See changes]
```

### Memory card

Used in Settings → Kitchen Memory.

```md
Thursdays are fragile
Tore will prefer leftovers or low-effort meals on Thursdays.

Seen 7 times
[This is wrong]
```

AI memory needs transparent controls. Microsoft’s Human-AI guidelines emphasize that systems should learn from behavior, adapt cautiously, and convey the consequences of user actions. ([Microsoft][7])

## 5.3 Buttons

Button hierarchy:

```md
Primary:      filled accent
Secondary:    subtle surface / outline
Tertiary:     text button
Danger:       muted red, never screaming red
Ghost:        icon-only or low emphasis
```

Button labels must be verbs:

```md
Start cooking
Add to tonight
Use this deal
Skip dinner
Undo
See changes
```

Avoid:

```md
Submit
Confirm
Proceed
AI
Generate
Execute
```

## 5.4 Inputs

### Command bar

The command bar is the agentic power path.

```md
[ Ask Tore to adjust the week…                       ↑ ]
```

Behavior:

```md
- Sticky bottom on Plan
- Expands into a larger composer on focus
- Supports examples when empty
- Shows agent status while running
- Final state becomes a run receipt, not a chat bubble
```

Examples:

```md
Make Thursday leftovers
Find something quick for Tuesday
Use the pork deal this week
Move salmon to Friday
Plan only three dinners
```

The current spec already defines the planner command bar and `PlannerAgent` tool loop; the UI should make that feel like a direct manipulation surface, not a separate chat mode. 

### Capture input

Capture is for photos and messy input.

```md
[ Take photo ] [ Paste recipe ] [ Scan receipt ] [ Ask Tore ]
```

After upload, Tore routes the content:

```md
Receipt → Review receipt
Recipe photo/text → Save recipe
Fridge photo → Suggestions
Pantry shelf → Pantry belief preview
Unknown → Ask what to do
```

This matches the existing photo pipeline goals for receipt, recipe, pantry, and fridge classification. 

---

# 6. Screen specs

## 6.1 Today

### Job

Answer:

```md
What matters for dinner today?
```

### Layout

```md
Header
- "Today"
- Date
- small Settings/avatar button

Hero
- Tonight’s meal card

Secondary
- Tomorrow compact card
- Review pill ("N to review") — only when runs await the user; opens the oldest pending review, then returns here; never red, never badge-styled

Bar
- [Today] [Plan] (pill) [Shop] — the pill is the Capture entry; no floating FAB
```

### Empty state

```md
No dinner planned
Tore can make a good guess for tonight.

[Suggest dinner] [Open plan]
```

### Hero card content

```md
Tonight
Pork skewers with cucumber yoghurt

35 min · 2 servings
Rice is already prepped

[Start cooking]
[Swap]
```

On a night marked as eating out, the hero says "Eating out tonight" instead, with no cooking action.

### Rules

```md
Today must not show a full calendar.
Today must not duplicate the week — that is Plan, one tap away.
Today must not show pantry inventory.
Today must not show spending charts.
Today must not show more than one proactive note by default.
```

### Tonight-card long-press sheet (shipped, 2026-08)

Long-pressing the tonight card (500 ms) raises a sheet scoped to today,
mirroring §6.2's slot sheet:

```md
Tonight · Pork skewers with cucumber yoghurt
─────────────────────────────
[ input field scoped to tonight ]
```

Calm rules (same as §6.2's slot sheet): quiet placeholder copy ("Anything
about tonight…"), no AI branding or iconography, silent until used. Escape
or tapping the scrim closes the sheet without dispatching.

## 6.2 Plan

### Job

Answer:

```md
What should the week look like?
```

### Layout

```md
Header
- "This week"
- Week range
- Generate/refresh subtle action

Top
- Run receipt, when there is one

Main
- Seven-day meal board
- "Prep this week" link, a quiet way to the prep guide. Optional and on demand: nothing asks you to prep

Bottom
- Sticky command bar
```

### Day slot card

```md
Tuesday
Pork skewers
35 min · 2 servings
uses ICA pork deal

[⋯]
```

States:

```md
planned
empty
skipped
leftover
locked/pinned
agent-updated
needs-attention
```

### Slot visual language

```md
planned:       raised card with image/thumb or tonal block
empty:         quiet dashed surface
skipped:       flat muted row, no guilt copy
leftover:      linked chain marker from source meal
locked:        tiny pin, not loud
agent-updated: temporary soft glow / marker
```

### Interactions

Tap slot:

```md
Assign recipe
Skip
Mark leftover
Set servings
Pin
Remove
Eating out
```

Eating out:

```md
Works on any day, with or without a recipe. Cancels any recipe that day
Optional place and amount, now or later from the same sheet
The row reads "Eating out"
"Not eating out", or picking a recipe, removes it and its cost entry
Not a plan gap. Tore's planner leaves the day alone
```

Drag meal:

```md
Move meal between days
Show preview
Drop applies immediately
Undo snackbar appears
```

Command:

```md
Natural language applies changes
Run receipt appears
Changed slots animate subtly
```

Slot sheet scoped input:

```md
Input inside the open slot sheet
Referent is the touched slot — pre-resolved, no need to name the day
```

Calm rules:

```md
Quiet placeholder copy ("Anything about this day…")
No AI branding, no AI iconography
Silent until used — no idle affordance calling attention to itself
```

### Critical rule

Skipping is neutral:

```md
Thursday skipped
[Undo]
```

Never:

```md
Why are you skipping?
This may affect your plan.
You are behind.
```

The current spec explicitly says skipping is first-class and neutral, with no “why?” and no cascade warning. 

## 6.3 Shop

### Job

Answer:

```md
What do we need to buy?
```

### Layout

```md
Header
- "Shop"
- Store/week context
- Add item input

Top
- List status card

Main
- Grocery groups

Bottom
- Manual add
```

### List status card

```md
Ready for this week
42 items · updated after Tuesday’s swap

[See plan changes]
```

### Grocery item

```md
[ ] Greek yoghurt
    Dairy · for Wednesday chicken
```

Checked state:

```md
[x] Greek yoghurt
    Added to pantry belief
```

### Grouping

Default groups:

```md
Produce
Protein
Dairy
Dry goods
Frozen
Household
Other
```

Rules:

```md
Manual add always works.
Offline/LLM failure must not block shopping.
Checked items may update pantry belief silently.
Do not show pantry as exact truth.
```

This follows your spec’s rule that groceries are the reliability anchor and must survive missing plans, missing pantry data, and LLM failure. 

### Grocery-row long-press sheet (shipped, 2026-08)

Long-pressing a grocery row (500 ms) raises an item sheet, mirroring §6.2's
slot sheet:

```md
Greek yoghurt
─────────────────────────────
[ input field scoped to this item ]
```

The scoped input routes through Capture's classifier with a text referent
("[The user is referring to the grocery item "Greek yoghurt" on the
shopping list.]") rather than a resolved handle — no grocery action tools
exist yet to consume one (`ResolvedGroceryItem` is deferred, SPEC.md
§A.6.2). Calm rules as §6.2's slot sheet: quiet placeholder ("Anything
about this item…"), no AI branding, silent until used. Escape or the scrim
closes without dispatching.

## 6.4 Capture

### Job

Answer:

```md
What can Tore understand from this messy input?
```

### Layout

```md
Header
- "Capture"

Primary actions
- Scan receipt
- Add recipe
- Fridge photo
- Pantry shelf
- Ask Tore

Recent captures
- Receipt parsed
- Recipe saved
- Fridge suggestions
```

### Capture result pattern

```md
Tore found a receipt
12 items · 438 kr

[Save] [Review]
```

```md
Tore found ingredients
Chicken · yoghurt · cucumber · rice

Suggested:
1. Chicken yoghurt skewers
2. Fried rice
3. Cucumber chicken bowls

[Add #1 to tonight]
```

### Rule

The default outcome should be a useful artifact, not a question. Your current spec says the fridge-photo flow must end in three concrete recipe suggestions with “add to tonight,” not stop at “Want me to suggest some recipes?” 

## 6.5 Cooking mode

### Job

Answer:

```md
What do I do right now?
```

### Layout

```md
Top
- Recipe title
- Time/servings
- Exit

Main
- One current step at a time
- Ingredients relevant to current step
- Large next button

Bottom
- Step progress
- Ask cooking question
```

### Visual rules

```md
High contrast.
Huge text.
No tiny metadata.
No planning controls.
No shopping controls.
No unrelated AI notes.
```

### Step card

```md
3 / 8

Mix yoghurt, garlic, salt, and lemon.

You need:
Greek yoghurt · garlic · lemon · salt

[Next]
```

## 6.6 Settings

### Job

Answer:

```md
What does Tore know, and how can I correct it?
```

### Sections

```md
Members
Your households
Household
Kitchen Memory
Stores
AI usage
Pantry belief
Spending
```

Household shows its name, which can be renamed, and the language, picked once and locked afterwards.

### Members

```md
Gustaf      gustaf          [Leave]
Anna        anna            [Remove]
bo          Joins at their first sign-in   [Remove]

Pocket ID username
[Add]

Sign out
```

Rules:

```md
Pocket ID's groups decide who may sign in. Tore decides only who shares a household.
Add someone by their Pocket ID username. No codes, no roles, no invite links, no confirmation.
Someone who hasn't signed in yet waits in the list and joins at their first sign-in.
Remove and Leave appear only when there is more than one member: the last member can't leave.
A removed member's open screens close.
"Sign out" ends the session in this browser and closes its other open tabs.
```

### Your households

```md
Rydholms        Current
Anna & Bo       [Switch]
```

Rules:

```md
Shown only to someone in two or more households.
Switching changes whose plan, list and recipes every screen shows.
```

### AI usage

```md
Use my credits for this household   [On]
```

Rules:

```md
Only someone with the tore_ai claim sees the switch, and only for themselves.
Everyone else sees who sponsors the household ("AI uses Gustaf's credits."), or "AI is off for this household."
Being added to a household never turns it on.
```

### First sign-in: language

```md
Welcome to Tore

Pick the language your household keeps its recipes, lists and receipts in. It can't be changed later.

[Svenska]
[English]
```

Rules:

```md
Shown once, at /welcome, to the person who starts a household. Everything the household stores is in this language.
It can't be changed later. Members who join start in it.
```

### Stores

```md
Paste a link to a store's offers
[Add]

ICA Supermarket Danvikstull    [On] [Remove]
```

Rules:

```md
The link is all it asks for. The store's name and chain come from the link.
A link Tore has no parser for gets "Tore can't read that store yet".
No page of deals. Tore's planner reads them.
```

### Kitchen Memory

```md
Tore has noticed

Thursdays are fragile
Tore will prefer leftovers or low-effort meals on Thursdays.
Seen 7 times
[This is wrong]

Fish rarely sticks on weekdays
Tore will avoid weekday fish unless explicitly requested.
Seen 4 swaps
[This is wrong]
```

Rules:

```md
No rating UI.
No onboarding questionnaire.
No forced preference maintenance.
No AI debug logs for normal users.
```

Google’s PAIR guidance emphasizes that AI products need clear mental models, staged expectation-setting, and feedback/control mechanisms, especially because AI systems adapt over time. ([Pair][8])

## 6.7 Costs

### Job

Answer:

```md
What did food cost this month?
```

### Layout

```md
Header
- "Food costs"

Main
- Total this month, with the change from last month
- Recent receipts (five)
- Eating out this month

Bottom
- Scan receipt photo, or enter a total by hand
```

Rules:

```md
One page, reached from Settings. Not in the nav.
No tabs, charts or breakdowns: nothing here that changes what Tore does next.
A receipt photo opens its review card, then returns here.
Receipts record cost only. They never change the pantry or the list.
```

---

# 7. Agentic interaction patterns

## 7.1 Run receipt

Every state-changing agent action ends with a compact receipt.

```md
Tore adjusted the plan
3 meals changed · grocery list refreshed

[Undo] [See changes]
```

Expanded:

```md
Plan
+ Wednesday: Chicken yoghurt skewers
~ Friday: Leftovers from Wednesday
- Thursday: Salmon pasta

Shop
+ chicken thighs
+ Greek yoghurt
- salmon

Why
Pork deal was used elsewhere. Wednesday recipe creates leftovers.
```

## 7.2 Thinking state

Do not show a fake chatbot typing indicator.

Use operational language:

```md
Checking the week…
Looking at deals…
Updating groceries…
Verifying changes…
```

Keep it short. No anthropomorphic “I’m thinking.”

## 7.3 Failure state

```md
Tore couldn’t safely update the plan
The salmon reference matched two recipes.

[Choose recipe] [Cancel]
```

Rules:

```md
Tell the user what blocked the action.
Offer a repair action.
Do not expose tool-call internals.
Do not blame the model.
```

## 7.4 Undo

Undo must be immediate and visible after any reversible action.

```md
Thursday skipped
[Undo]
```

```md
Plan updated
[Undo] [See changes]
```

NN/g’s usability heuristics explicitly call out undo/redo and clear exits as part of user control and freedom. ([Nielsen Norman Group][1])

## 7.5 “Why this?”

Use tiny, optional explainability.

```md
Pork skewers
35 min · uses ICA deal

[Why this?]
```

Expanded:

```md
Why Tore picked this
- Pork is on sale this week
- Similar recipes were kept recently
- Works as leftovers for Friday
```

Do not show reasoning by default. Show just enough to build trust.

---

# 8. Empty states

Empty states must be useful, not decorative.

## Today empty

```md
No dinner planned
Tore can make a good guess from your week, pantry belief, and recent meals.

[Suggest dinner]
```

## Plan empty

```md
This week is open
Plan a calm week in one step.

[Plan 4 dinners]
[Use deals]
```

## Shop empty

```md
Nothing to buy yet
Add items manually or generate from the week.

[Add item]
[Build from plan]
```

## Kitchen Memory empty

```md
No kitchen memory yet
Tore learns quietly from skips, swaps, leftovers, and repeated choices.
```

No illustrations unless they are exceptionally tasteful. Most empty states should be typography + one action.

---

# 9. Responsive behavior

## Mobile

```md
Single column
Bottom nav
Sticky command/input surfaces
Bottom sheets for slot actions
Large hit targets
No hover-only affordances
```

## Tablet

```md
Two-column Today possible:
- left: tonight
- right: tomorrow/week strip

Plan can show 7-day horizontal board.
```

## Desktop

```md
Left rail
Centered content for Today/Shop/Capture
Full-width board for Plan
Keyboard shortcuts allowed
```

WCAG’s reflow guidance also matters for the web app: content should adapt without loss of information/functionality and avoid two-dimensional scrolling except where the layout itself requires it. ([W3C][4])

---

# 10. Microcopy rules

## Voice

Use Swedish in the app, but English examples here.

Tone:

```md
Matter-of-fact
Warm
Brief
Never guilt-inducing
Never overly enthusiastic
Never “AI assistant” theatrical
```

Good:

```md
Dinner is planned.
Rice is already prepped.
Thursday is open.
Tore changed 3 meals.
This is probably in your pantry.
```

Bad:

```md
Great job!
Oopsie!
Your AI chef has a suggestion!
You forgot to plan Thursday.
Let’s optimize your food journey.
```

## Vocabulary

Use household language:

```md
Dinner
Tonight
Tomorrow
Leftovers
Shopping list
Probably have
Use before Friday
Already prepped
```

Avoid system language:

```md
LLM
Agent
Tool call
Inference
Aggregate
Decider
Pipeline
```

---

# 11. Accessibility requirements

## Baseline

```md
WCAG 2.2 AA minimum.
Keyboard navigable.
Visible focus.
Screen-reader labels.
No color-only meaning.
No text embedded in images.
Reduced motion support.
Hit targets 44×44 minimum.
```

## Focus

Every interactive element must have:

```md
:focus-visible outline
minimum 2px visual indicator
contrast against both element and background
```

## Reduced motion

When `prefers-reduced-motion: reduce`:

```md
Disable springy transitions.
Keep opacity/fade under 120ms.
Do not animate meal movement across screen.
Use instant state change + highlight.
```

## Screen reader language

Expose semantic states:

```md
"Tuesday, planned, Pork skewers, 35 minutes"
"Thursday, skipped"
"Greek yoghurt, checked, added to pantry belief"
"Plan updated, undo available"
```

W3C’s WCAG quick reference is the implementation companion for accessibility success criteria and techniques. ([W3C][9])

---

# 12. Implementation guidance for Phoenix LiveView

## 12.1 Components

Create UI primitives:

```elixir
ToreWeb.UI.Shell
ToreWeb.UI.TopBar
ToreWeb.UI.BottomNav
ToreWeb.UI.LeftRail
ToreWeb.UI.Card
ToreWeb.UI.HeroCard
ToreWeb.UI.DecisionCard
ToreWeb.UI.RunReceipt
ToreWeb.UI.CommandBar
ToreWeb.UI.BottomSheet
ToreWeb.UI.WeekStrip
ToreWeb.UI.MealSlot
ToreWeb.UI.GroceryItem
ToreWeb.UI.EmptyState
```

## 12.2 Design tokens

Create a token file:

```css
assets/css/tokens.css
```

With:

```css
:root {
  color-scheme: light;

  --bg: #F4EFE7;
  --surface: #FFFCF6;
  --surface-raised: #FFFFFF;
  --surface-muted: #ECE3D7;

  --ink: #1F211D;
  --ink-muted: #6C6A61;
  --ink-faint: #9A9488;

  --line: #DED4C6;
  --line-strong: #C8BAA8;

  --accent: #556B5F;
  --accent-ink: #F8F4EA;
  --accent-soft: #DDE7DF;

  --attention: #A56A43;
  --attention-soft: #EFE0D3;

  --danger: #9B3E35;
  --danger-soft: #F1DAD6;

  --radius-sm: 10px;
  --radius-md: 16px;
  --radius-lg: 24px;
  --radius-xl: 32px;

  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 20px;
  --space-6: 24px;
  --space-8: 32px;
  --space-10: 40px;
  --space-12: 48px;

  --shadow-soft: 0 12px 40px rgba(31, 33, 29, 0.08);
  --shadow-float: 0 20px 80px rgba(31, 33, 29, 0.14);
}
```

## 12.3 LiveView states

Every async/agentic surface should explicitly model:

```elixir
:idle
:submitting
:running
:needs_user
:applied
:failed
:reverted
```

Do not infer UI status from string messages. Use explicit assigns.

## 12.4 Run receipt assign

```elixir
%{
  title: "Tore adjusted the plan",
  summary: "3 meals changed · grocery list refreshed",
  changes: [
    %{kind: :plan, label: "Tuesday", before: "Salmon pasta", after: "Pork skewers"},
    %{kind: :grocery, label: "Greek yoghurt", before: nil, after: "added"}
  ],
  reason: [
    "Pork matches this week's deal",
    "Friday works better as leftovers"
  ],
  undo_event_id: "...",
  status: :applied
}
```

## 12.5 Slots should not be tables

The Plan UI must not render days as equal-weight CRUD cells. A meal slot is a **decision card**, not a database row.

---

# 13. Design review checklist

Before merging UI work, answer:

```md
Can the screen's primary job be understood in two seconds?
Is there one dominant action?
Is there less text than before?
Can the user undo meaningful changes?
Does the UI explain AI changes without exposing internals?
Does the screen work if the LLM fails?
Does manual grocery add still work?
Are pantry and costs still demoted?
Are touch targets large enough?
Is focus visible?
Is important meaning available without color?
Does it avoid generic SaaS/card/table clutter?
```

---

# 14. Non-goals

Do not build:

```md
A recipe discovery social feed
A pantry management dashboard
A cost analytics dashboard in main nav
A chatbot-first app
Push notifications
Meal ratings
A big onboarding questionnaire
A generic admin settings maze
AI mascot/personality
```

Your current spec already removes the primary pantry route, moves costs out of main nav, bans meal ratings, bans “you haven’t logged in” reminders, and treats pantry as approximate inference rather than a management screen. 

---

# 15. The key product move

The most important UI idea is this:

Tore should show outcomes, not process.
```

The user should mostly see:

```md
Tonight
This week
Shopping list
Useful opportunity
Clean undoable changes
```

Not:

```md
Prompts
Agents
Models
Pipelines
Pantry tables
Debug traces
Recipe databases
Cost dashboards
```

That is how Tore gets the “agentic harness for food” feeling while still being beautiful: **the intelligence is operational, the interface is quiet, and the user remains in control.**

[1]: https://www.nngroup.com/articles/ten-usability-heuristics/ "10 Usability Heuristics for User Interface Design - NN/G"
[2]: https://www.microsoft.com/en-us/research/project/guidelines-for-human-ai-interaction/ "Guidelines for Human-AI Interaction - Microsoft Research"
[3]: https://m3.material.io/foundations/design-tokens?utm_source=chatgpt.com "Design tokens – Material Design 3"
[4]: https://www.w3.org/TR/WCAG22/ "Web Content Accessibility Guidelines (WCAG) 2.2"
[5]: https://developer.apple.com/design/human-interface-guidelines/buttons?utm_source=chatgpt.com "Buttons | Apple Developer Documentation"
[6]: https://m3.material.io/foundations/interaction/states?utm_source=chatgpt.com "States – Material Design 3"
[7]: https://www.microsoft.com/en-us/research/blog/guidelines-for-human-ai-interaction-design/?utm_source=chatgpt.com "Guidelines for human-AI interaction design"
[8]: https://pair.withgoogle.com/chapter/mental-models/ "Mental Models"
[9]: https://www.w3.org/WAI/WCAG22/quickref/ "How to Meet WCAG (Quickref Reference)"

---

# 16. Enforcement (the Kole doctrine)

This section is the non-negotiable checklist that turns the principles above into
rules you can fail a PR on. The earlier sections explain *why*; this section
states *what must be true* before UI work merges.

Companion BE spec: `docs/specs/run-receipts.md` defines the artifact and undo
machinery this section depends on.

## 16.1 The product is not what people think it is

Tore is not a recipe app, grocery app, pantry app, or AI chat app. The central
object is **household food state**: tonight's plan, the week, what needs
buying, what's already handled, what's uncertain, what the agent changed.

The UI must answer these questions, in this order:

```md
What are we eating?
What needs buying?
What is already handled?
What is uncertain?
What did Tore change?
```

It must not answer:

```md
What are my recipes?
What's in my pantry?
What did Tore's pipeline do?
```

## 16.2 Top-level surfaces are operational, not entity-shaped

Allowed top-level destinations:

```md
Today · Plan · Shop · Capture
```

Forbidden as top-level nav:

```md
Recipes
Pantry
Deals
Receipts
Costs
KitchenRuns
Ingredients
```

Those are system resources and must appear contextually inside an operational
surface.

## 16.3 Agent acts; user undoes

Tore's model is **agent acts immediately; the user undoes if wrong** — not
approval-gated proposals. This is a deliberate choice for trust through
visibility + reversibility rather than friction.

Therefore every agent-driven state change must:

1. Produce a **run receipt** (see §7.1 and `docs/specs/run-receipts.md`).
2. Be reversible by a single Undo for at least a short window.
3. Be visible in Capture as a structured diff, not prose.
4. Respect user locks (see §16.6).

A run receipt is mandatory. Prose-only confirmation ("I added milk to the
shop list") is a UI bug.

## 16.4 The diff alphabet

Agent-driven changes render as structured rows with a single-character prefix:

```md
+   added
-   removed
~   changed
?   assumed / uncertain
```

Examples:

```md
+ Grädde
- Pasta
~ Move tacos from Thursday to Friday
? Assume olive oil at home
```

This alphabet is the canonical vocabulary across run receipts, Capture
bubbles, and any other diff surface. Do not invent new prefixes.

## 16.5 Belief state, not booleans

Pantry rows must not render as "in pantry: yes/no". Use the belief vocabulary:

```md
Confirmed at home
Probably at home
Probably missing
Unknown
```

Surface uncertainty inline, not in modals. The receipt review card's
inferred-date amber border is the canonical pattern: a quiet visual hint
beats a confident lie.

In shop rows, items the agent thinks the user already has render with a `?`
prefix and inline copy ("probably at home, last confirmed 12 days ago"). Do
not silently omit them.

## 16.6 User intent outranks the agent

User-set state wears one of these labels:

```md
Locked by you
Edited by you
```

Agent flows must not mutate locked slots/items. When the agent declines to
change something because the user locked it, the run receipt says so
explicitly:

```md
Tore left Friday unchanged because it is locked by you.
```

This is a trust-building detail. Do not omit it.

## 16.7 Backend vocabulary stays out of the user UI

Never expose these terms in any user-facing surface:

```md
KitchenRun
Capsule
Verifier
Artifact
Run
Aggregate
Decider
Pipeline
LLM
Agent
Tool call
Inference
```

Allowed surfaces for these terms: developer/debug views under
Settings → Developer (or dev-only routes). Nothing else.

User-facing copy uses household language: dinner, tonight, leftovers,
shopping list, probably have, already prepped.

## 16.8 Chat is capture, not product

Capture accepts messy input — text, photos, URLs, voice — and produces typed
artifacts (a saved recipe, a run receipt with diffs, a parsed receipt review
card). The agent's text reply is the *fallback*, not the *product*.

If the agent calls tools, the user sees the resulting run receipt with diff
rows. They should not need to read a paragraph to learn what changed.

## 16.9 Uncertainty is visible; precision is honest

Do not invent defaults to hide that the agent didn't know something. The
inferred-date amber border on the receipt review card is the canonical
pattern. The `add_to_shopping_list` tool deliberately does not impute
default units for the same reason.

When the agent is uncertain, render `?`. When it's confident, render no
prefix. When it's wrong, the user undoes.

## 16.10 One primary action per screen

Every screen has exactly one primary action. Secondary actions render as
plain/ghost. If a design has two primaries, one must be demoted before
merge.

Examples of the single primary action per surface:

```md
Today     Open dinner / Suggest dinner
Plan      Improve plan
Shop      Finish shopping
Capture   Send
Cook      Next step
```

## 16.11 Empty states are operational, not decorative

Empty states must offer a useful next step, not an illustration. The
template is:

```md
[State sentence]
[One-line context]

[Primary action]
[Optional secondary action]
```

See §8 for the canonical empty-state copy for each surface.

## 16.12 Loading states name the work, not the system

```md
✅ Reading recipe
✅ Checking pantry
✅ Building grocery changes
❌ Loading
❌ Please wait
❌ AI is thinking
```

No anthropomorphic copy. No fake precision (no progress bars unless the work
actually has a measurable length).

## 16.13 Errors explain consequence and recovery

Every error must answer: what failed, what state is the system in now, and
what can the user do next.

```md
Could not read the recipe
The page may block scraping.
Nothing was saved.

[Paste text]
[Try again]
```

The "nothing was saved" line — explicit consequence — is mandatory whenever
true. Trust depends on knowing the system didn't half-apply something.

## 16.14 PR checklist (must be true before merge)

```md
□ One primary action on this screen
□ Agent-driven changes produce a run receipt with Undo
□ No backend vocabulary in user-facing copy
□ Pantry/shop uncertainty rendered inline with `?` or belief labels
□ User-locked items are visibly labeled and respected
□ Empty state is operational, not decorative
□ Loading copy names the work, not the system
□ Error copy explains consequence and recovery
□ Touch targets ≥ 44×44px
□ Focus visible without color alone
□ No new top-level nav for backend entities
```

If any line is false, the work is not ready.

