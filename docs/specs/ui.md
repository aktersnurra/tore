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

### 3.1 Where the app opens, and the tab bar

Opening the app (`/`) lands on the screen the household most likely needs now, picked
ahead of time by a decision model and stored (`SPEC.md` §Interfaces): tonight at five,
the list on Saturday morning, next week's plan on Sunday evening. The pick is never
computed while someone waits.

Every main screen has the same tab bar at the bottom, each tab an icon with its name under it:

```md
 ⌂ Today    ▦ Plan    (💬) Tore    🛒 Shop    📖 Recipes
```

- **Tore**, in the middle, is a filled round button in the text colour, not saffron. It
  opens the chat as a sheet over the screen you're on, and Close returns there.
- **Quick swaps** sit in an empty chat, above its input: up to three chips that open a screen
  or send a short request. They come from the stored pick. Plain
  chips: no AI iconography, no animation. After an answer, the chips are pi's suggestions for
  what to say next (`suggest_replies`); tapping one sends it.
- **The top bar** is the same on every tab (2026-11-18): the sidebar icon on the left opens the
  menu; the right holds this page's own actions behind ⋯. Page shortcuts live in the page:
  search in Recipes' toolbar, the scanner at the end of Shop's add line.
- **The menu** is a drawer from the left, read when it opens: Ask Tore first, as a soft field
  under the household's name (like search in Notion), then the rest of this week (tonight
  marked, open days quiet), starred recipes, the collections with their counts, and the
  household's pages (At home, Weekly budget, Offers). Settings sits alone at its foot (2026-11-19):
  configuration, not a page you use every week; members and diet are inside it.
  It closes on the scrim, on Escape, or when one of its links is followed. Tap only; no edge
  swipe.
- **Settings** is reached from the menu. It's one grouped list (§6.6): the household,
  food, Tore, this device's look, and the account. The stores moved to Erbjudanden (§6.10).
- The current tab is in the text colour with a filled icon, the others muted and outlined.
  Prep counts as Plan. No sparkle icons anywhere: Tore is a chat glyph.

Without AI, a fixed rule picks the screen and the swaps, and nothing else changes.

### 3.2 Route map

```md
/              → The stored pick's screen (redirect)
/today         → Today (tab)
/plan          → Plan (tab)
/shop          → Shop, with this month's spending under the list (tab)
/recipes       → Recipes (tab)
/capture       → Tore's chat (the centre tab; presents as a sheet)
/settings      → Settings, from the menu's foot: the grouped list
/settings/:section → One setting's page (name, members, food, memory, ai, households)
/budget        → Veckobudget, from the menu and Plan's budget line (§6.9)
/budget/receipts/:id → A receipt, over Veckobudget
/deals         → Erbjudanden, with the stores at its foot, from the menu (§6.10)
/prep          → Prep guide, via Plan's ⋯ "Prep this week"
/recipes?type= → Recipes on one collection, from the menu
/recipes/:id/cook → Cook mode, no tab bar
/pantry        → Hemma: what's at home, from the menu and the At home rows
```

Removed on 2026-11-15: the review page (recipes save straight away with undo), the pantry
page (Tore keeps the pantry), the costs page (now under Shop) and `/cooking` (now in Settings).
The pantry came back on 2026-11-19 as Hemma (§6.8): a page to look at and correct, never one
that asks to be kept.

### 3.3 Navigation behavior

On a phone and a narrow tablet: the tab bar at the bottom, the chat as a sheet that rises over
the screen. The bar stays put across navigation.

From 1024 px wide (2026-11-19, "On a laptop" in the Tore kitchen pages mockup) the tab bar
gives way to a **sidebar** that stays open, 248 px on the left: the household, the tabs in the
phone's order with Tore as a row between Plan and Shop, then the menu's sections (this week,
favourites, collections, the household's pages), and Settings alone at its foot. Only where you are is lit. A tab's top bar has no menu button there. The phone is
unchanged.

---

## 4. Visual design direction

## 4.1 Visual metaphor

Tore should look like **a soft instrument panel for the kitchen**.

Use:

```md
Large calm surfaces
Cast-iron greys with white (light) or raised (dark) cards
Hairlines, not shadows
Precise typography
Sparse accent color
Generous spacing
Contextual cards
Subtle motion
```

The week of dinners is a *matsedel*, the typed weekly menu, and the screens are set like one:

- **The rim line.** One hairline under the screen's title (`.rim`), and nowhere else.
- **Lists are menu lines.** Days, recipes and shopping items sit on the page, separated by
  hairlines (`.menu-lines`). Cards are for things that are objects: a receipt, a form, a sheet.
- **Weekdays and months are written out** ("Onsdag 11 november"), through `ToreWeb.Dates`.
- **Today holds the largest type in the app**, under the date. One filled button per screen;
  the alternative is a text link.
- **No label that isn't information.** Today's top line is the date, not "Tonight".
- **Tuning stays quiet.** The week's mode sits behind "Planning for: …" below the week.
- **Removing is one step away.** A shopping item is removed from its long-press sheet.
- **Soft, not editorial.** Headlines are 26–30px bold, never poster-sized or tightly tracked.
  Lists sit on one rounded surface (`.menu-lines`), not as ruled lines on the page.
- **The dish's name is on its photograph** on Today (on a phone) and a gallery tile: the cover
  darkens at its foot (`.photo-shade`) and carries the name in white (`.on-photo-text`). A cover
  still waiting for its picture keeps its tint and the name in the page's own type colour, with
  no shade (2026-11-19).
- **A gallery tile's quick actions** (2026-11-20): on a laptop, the pointer on a tile shows Cook
  now, Put on the week and Ask Tore in its top corner, in the order of the recipe page's buttons,
  and the star in the other. Cook and the week open the recipe doing that (`?then=cook|week`), so
  Cook now still goes through the sheet before cooking when something's missing. A phone has no
  hover: a tap opens the recipe.
- **A toolbar control that an icon says is an icon only**: Recipes' gallery, list and new are
  icons, named for a screen reader and in a tooltip (2026-11-20).
- **A recipe page has a split hero, like Andy Cooks'** (2026-11-20): the words on the left (the
  collection as a breadcrumb, the name in capitals (`.t-hero`), prep, cook and total time with
  bold labels, the description, Cook now and Put on the week) and the picture on the right,
  whole and rounded rather than cropped to a strip. On a phone the picture comes first. Back and
  ⋯ sit on the page above it; the other properties follow below.
- **The day-to-day screens share one width** (2026-11-20): Today, Plan, Hemma and a recipe
  page are 56rem of content (`<.page max_width={:lg}>`; a recipe page's own parts are 59rem
  with their padding), so moving between them feels like one place. Today is one column at
  that width; side by side it looked like the recipe page.
- **Lists and dashboards use a laptop's width** (2026-11-20). Shop's list
  is one column and the month's spending another; on a wide screen the list's sections run down
  two columns in the store's order, each kept whole. Veckobudget is two columns on a laptop (the
  chart and where the money went beside the receipts); on a wide screen the chart takes the full
  width, drawn wide so its text stays a phone's size, with where the money went and the receipts
  as two equal columns under it. Veckobudget, Erbjudanden and Shop are as wide as Recipes; Plan and
  Hemma a step wider than before. Settings and the forms stay a reading column. A sheet from the
  bottom edge is a phone's gesture: on a laptop every sheet is a dialog in the middle of the
  screen, with × in its corner, that settles in place. A phone sees
  no change.
- **One palette, two lights.** Papper: ink on white, graphite when the phone is dark
  (follows the phone, or `data-theme`). The main action is ink; type on it uses `--on-accent`.
- **Pictures lead where there's a dish.** Today opens on tonight's cover; Recipes is a
  gallery. A recipe never shows an empty block: until its picture is drawn it shows its icon
  on its collection's tint (`<.blank_cover>`, `ToreWeb.Look`), never a stock image. Pictures
  that failed are drawn again at night (`Tore.Recipes.draw_missing_pictures/0`).
  Its + starts from a link: paste one and the sheet closes at once while Tore reads the recipe
  in; a toast at the bottom says "Sparade …" or why it couldn't, in pi's words. "Write it
  yourself" under the field is the way out to the form, taking along what was typed (a link as
  the source, anything else as the name).
  A link shared to Tore opens `/recipes?url=…` (or `?text=…`, where apps like Instagram put it)
  and is read in straight away. Android offers Tore in the share sheet through the manifest's
  share target; iPhone has no share targets for web apps, so a Shortcut opens that address.
- **Anything followed with hands full is step cards** (`ToreWeb.StepCards`): one large card
  per step, a tap for the next, and "All steps" to peek ahead. Cook mode and the week's prep
  use it.
- **Five tabs, Tore in the middle.** Everything else is reached from a tab's screen.

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
Theme: Papper
```

A kitchen notebook, after Notion's pages: ink on white paper, with graphite for a phone set to
dark. The page has almost no colour of its own. The photographs carry the appetite, and colour
elsewhere comes only from tags that mean something.

Four rules:

- **The main action is ink.** One filled button per screen; everything else is quiet.
- **The food is the colour.** Surfaces stay grey-white so tomatoes and dill are the brightest
  things on screen.
- **A tag's colour is its meaning.** Orange is dinner, yellow baking, green sauces & sides (and
  done), blue assemblies (and the week), red tonight or missing, purple leftovers, grey quiet.
- **Red never nags.** An open Thursday is not an error.
- **One icon family: Phosphor** (MIT, vendored under `assets/vendor/phosphor`, used as
  `ph-NAME`, `ph-NAME-fill` and `ph-NAME-duotone`). Regular in the chrome, fill for the current
  tab and Tore, duotone in a collection's ink for pages and dishes. No emoji. The one exception
  is Hemma's rows, which are food pictures (§ Hemma: Iconito Food).

Chosen 2026-11-18, replacing Gjutjärn (cast iron and saffron), which read as heavy. The mock it
came from: the "Tore kitchen pages" artifact.

## 4.3 Color tokens

`assets/css/app.css` is the source of truth; this is a copy. Screens use these tokens only, never raw colours.

```css
/* light                     dark */
--bg:           #FFFFFF;  /* #191919 */
--surface:      #F7F7F5;  /* #232322 */
--sunken:       #EFEEEB;  /* #2C2C2B */

--text:         #2E2C29;  /* #ECEBE9: ink */
--muted:        #75726D;  /* #9B9A97 */
--subtle:       #C9C7C3;  /* #5E5D5B: rings and lines only, never text */

--border:       #E8E7E4;  /* #2F2F2E */
--hairline:     #EFEEEB;  /* #262625 */

--accent:       #2E2C29;  /* #ECEBE9: the main action is ink */
--on-accent:    #FFFFFF;  /* #191919 */

--done:         #3F7F5B;  /* #6FB38A */
--danger:       #B8403A;  /* #E26B63 */
```

Tags: a tint and an ink per colour (`.tag .tag-orange` …), with a dark pair for each.

```md
orange  #FAEBDD / #8C4A1A   dinner
yellow  #FBF3DB / #7A5A12   baking
green   #EDF3EC / #346648   sauces & sides, done
blue    #E7F3F8 / #1F5E85   assemblies, the week
red     #FDEBEC / #9F2F2D   tonight, missing
purple  #F4EFF8 / #6A4396   leftovers
grey    #F1F1EF / #5F5D58   quiet
```

Muted is 4.8:1 on the page; every tag ink is 4.5:1 or more on its tint. `--subtle` is for rings
and lines only.

Color must communicate hierarchy and state, not decoration.

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

The device's own sans-serif (`system-ui`), nothing downloaded.

```css
--t-display: 34px;
--t-h1:      26px;   /* page titles, bold */
--t-h2:      17px;
--t-body:    16px;
--t-meta:    14px;
--t-micro:   12px;
```

Rules:

```md
One screen has one typographic hero: tonight's dinner on Today is the largest type in the app.
Every page title is the same size and weight, and sits on the page, not inside a card.
Section labels are sentence case (`.section-label`), never tracked capitals.
Links say what they do, with no arrow.
Use tabular figures (`.num`) for servings, times, quantities and prices.
```

## 4.6 Shape

Corners follow hierarchy.

```css
--r-sm:   6px;    /* tags, checkboxes */
--r-md:   8px;    /* buttons, inputs, thumbnails */
--r-lg:   10px;   /* cards, photos */
--r-xl:   14px;   /* grouped rows, sheets */
--r-pill: 9999px; /* the chat box, the Tore button */
```

## 4.7 Elevation

Cards use a border and a background. Only things that float get a shadow (`--shadow-pop`): the chat sheet,
sheets, dialogs and flashes.

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

Timing (in `assets/css/app.css` since 2026-11-15):

```css
--dur-press: 90ms;   /* a press answers at once (.press scales to 0.96) */
--dur-fast:  150ms;
--dur-base:  240ms;  /* toasts, sheets' scrim, page cross-fade */
--dur-slow:  420ms;  /* arrivals (.reveal), sheets, the travelling photo */
--ease-out:    cubic-bezier(0.22, 1, 0.36, 1);
--ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1);  /* only the toast's check */
```

The one signature moment: a dish's photograph travels between screens. A page change
(navigate or patch) runs inside a View Transition; the photo you tap carries
`view-transition-name: dish-<id>`, and so does the photo on the page it opens. Only the
tapped photo is named, so the rest of the grid stays under the page. Reduced motion skips
the transition entirely.

Material’s interaction guidance emphasizes visible states, consistent state application, and accessible visual indicators. ([Material Design][6])

---

# 5. Component system

## 5.1 App shell

### Mobile shell

```md
Top:
- <.top_bar>: the menu (sidebar icon) left, the page's ⋯ (<.page_menu>) right
- Over a photo the two buttons are frosted

Main:
- A page: its icon (<.page_icon>, a duotone icon on a tinted square), the title, one muted
  line with the context and one number, then the content
- Single column, max width 480–672px

Bottom:
- The tab bar, Tore raised in the middle

Menu:
- The drawer from the left, in ToreWeb.TabBarLive (§3.1)
```

### Desktop shell

The sidebar (§3.3), then the page beside it. Recipes widens to five pictures a row. A recipe
is a full page beside the sidebar instead of a window over the list, at Plan's width (§ the
day-to-day screens share one width): the name and buttons beside the cover, and the
ingredients in a column to the left of the method. Plan, Hemma and Today are centered at the
same width; Plan with the month beside the week, and Tore as a column on the right, are next.

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
- Three dinners to choose between for tonight
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

Used in Settings → Kitchen Memory. One card per entry in the household memory (SPEC.md §1).

```md
Thursdays are fragile: leftovers or low-effort meals work best.
[Forget]
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

### Text fields

Every text field is one component (`CoreComponents.field/1`) and looks the same, except the chat's
own message box, which has no border: its send icon turns from grey to bright once something is
written (2026-11-20):

```md
At rest       grey border
Typing        blue border (the blue tag ink)
Just saved    green border, fading back in about a second and a half
Error         red border, and the reason in red under the field
```

Icons and buttons (search, +, scan, return) sit inside the box. Text is 16px, so a phone
doesn't zoom in on it.

A field on its own is sent with Enter, with no button beside it (the phone's key says Done or
Send). A field that sends something off (a recipe link, a question for Tore, Shop's add line)
looks like the chat's box: a fill, no border, the return icon inside, grey until something is
written. Shop's add line shows the scanner there while it's empty. Something just added, like a member, shows green for a moment on its new row, not on the
field. Removing something is a trash can, with no word; menus and forms of several fields keep
their words, and so does Undo.

### Asking about something on a screen

There is no command bar. The chat (Tore, the centre tab) is where you type. A screen's object
sheet has an input about the thing you touched, which asks the same chat with a line naming it:

```md
[ Anything about this day… ]
```

Behavior:

```md
- Lives inside the sheet of the day, tonight's dinner or the grocery item
- The person doesn't name the day or item; the sheet does
- A quiet working line while Tore works ("Changing the plan…")
- Tore's reply shows in a note on the screen, which can be closed
- What changed shows on the screen itself, and in the chat as a line with Undo
```

Examples:

```md
Make it leftovers from Monday
Find something quick instead
Move it to Friday
We already have this
```

Plan's "Plan the open days" asks the chat the same way, for the whole week.

### Capture input

Capture is for photos and messy input.

```md
[ Take photo ] [ Paste recipe ] [ Scan receipt ] [ Ask Tore ]
```

A photo goes to Tore with whatever was typed, and Tore reads it itself. With no words:

```md
Receipt → Logged as a cost, with Undo
Recipe photo → Saved, with Undo
Shelf or fridge → Into the pantry, a line with Undo per item
Unknown → Ask what to do
```

The tray looks like Claude's chat: a page beside the menu on a laptop, a sheet on a phone, one column about
48rem wide. What the person wrote sits on the right in a soft bubble, with no avatar. Tore's
answers are reading text under its name, with no avatar either, shown once per run of its messages, set as
markdown (`.chat-md`) with a caret while they stream in. A change pi made is a quiet line with a
check and Undo. The composer is one rounded box: the text grows with what's written, Enter sends
and Shift+Enter is a new line, with ↵ on its right; while pi works, ↵ becomes Stop, which aborts
it and keeps what it had written. The camera sits under the box. With nothing said yet, Tore's
mark and "What do you need?" sit in the middle.

The chat's title sits top left: pi names it after its first answer, and tapping it lets the person
change it (Enter or leaving the field saves). The caret beside it opens their chats, latest used
first, each with pi's one-line summary under its title, with New chat at the top and a search
field (focused) that narrows the list by title, tags and summary. Asking in a chat for an earlier
one ("laxgrejen från förra veckan") has pi find it and open it; the tray goes there. A new chat is empty until something is sent in it. A recipe's
own conversation shows "About <dish>" instead and isn't in the list.


---

# 6. Screen specs

## 6.1 Today

### Job

Answer:

```md
What matters for dinner today?
```

### Layout

Today answers one question at a glance: what's for dinner, and is anything needed before I can
start? One column on every screen, the phone's, read top to bottom (2026-11-20):

```md
Cover    — tonight's photo, or the dish's tinted icon while one is drawn, the one big thing on
           the page: 42% of a phone's height, about half a laptop's (at most 460px), not a
           letterbox. On it, the day as a tag (Ikväll red, Imorgon blue) over the dish's
           name; tapping it opens the recipe. No ⋯ menu (2026-11-21)
When     — the facts as the recipe page gives its times: 🕒 Totalt: 5 h  Klar: 18:40
           Portioner: 6 (`ToreWeb.Dates.duration/1`, shared with the recipe page); Lunch
           under it when one is planned. Klar only from 15:00 until the evening's over
           (`:cooking_from_hour`), since "ready 00:57" says nothing. Actions are the recipe
           page's large pills
Actions  — together, in one row under When, always in the same place (2026-11-21):
           [🔥 Cook now] [Something else] [Ask Tore]; on a phone Cook now spans the row and the
           other two share the one under it. Cook now is tonight only: with nothing to buy it
           starts cooking; with something still to buy it opens Before you start (what to use
           instead, or cook anyway), so swapping happens on the way in. Ask Tore is the dish's
           own conversation, with the question about what's missing typed when there is some.
           No dinner tonight is in Something else's sheet
Can I start? — under the actions, as the recipe page lays out Ingredienser: a section heading
           (`h2.t-head`, with the count beside it) over a card of rows:
           Handla 5
               ☐ 🍝 spaghetti   (each with its picture, as Hemma shows it)
               ☑ 🍅 passata     (ticked: at home now, and ticked on the week's list when it's
                                there; the row stays, tapping again undoes it, and a row the
                                tick made in the pantry goes again)
             the count is what's still to buy
           Finns det kvar?                                             Hemma ›
               🥛 mjölk, last seen 10 days ago      [Finns] [Slut]
             up to three; Slut puts it under Handla; "+2 more" opens Hemma
           tomorrow, nothing missing or unsure: [✓ Everything's at home] · Hemma ›
Note     — the home pick's one note, with its action, when there is one
```
No ingredient list: the recipe page has it. Opening Today asks Jev for the pictures of tonight's
ingredients that have none (`Tore.Pantry.Lasts.icons_later/2`), and Today redraws when they come.

### After dinner (2026-11-19)

Once tonight is cooked (Done in cook mode), or from 21:00, Today is tomorrow, because that's
what can still be sorted out this evening:

```md
✓ Kycklinggryta, lagad ikväll
[cover] Laxpasta
Tomorrow · 35 min
[🔥 Cook now] [Something else] [Ask Tore]
Handla 2
   ☐ lax
   ☐ dill
```

No Cook now and no ready-by time for tomorrow. An open tomorrow reads "Tomorrow is open".

### The note

At most one line, chosen by the home pick among notes code knows are true: "Buy lax and dill
before tomorrow · Put on the list", "6 things on the list · Open the list", "Tomorrow's dinner
isn't planned yet · Plan it". The model picks which, if any, fits the hour and the household's
habits; it never writes the words. Not shown when the page already says it.

### Before cooking (2026-11-19)

Cook now with something missing opens a sheet; with everything at home it goes straight to
cook mode:

```md
Before you start
Tore can't find these at home. Tick what you have.
☐ Gul lök
☐ Crème fraîche
Have something instead?  [rödlök, gräddfil     ] [Check]
  Gul lök → rödlök
  Crème fraîche → gräddfil · stir in on low heat
[Cook with these]  Cook anyway
```

Ticks are free and only count for this cook. Check asks pi once for all of it, in the person's
chat. Nothing is saved. Cook mode shows "rödlök instead of gul lök" where it's used, and the step text uses
the swap's name for the whole word ("Skiva vitlöken" → "Skiva vitlökspulver"). Done turns the
last card into "Cooked" with what's now used up at home; nothing moves: Close takes Done's
place and Undo the step buttons'.

### Empty state

```md
No dinner planned
Tore can make a good guess for tonight.

[Suggest dinner] [Open plan]
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

What's typed goes to the person's chat with a line naming tonight's dinner (§5.4).
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

Plan is the week as a list, or the month as a calendar (2026-11-19):

```md
Icon + "Week 47"           ‹ ›
16–22 november · about 575 of 900 kr      ← one line: the dates and the money
[Week] [Month]                [Plan 4 days]  ← views, filled when open; planning what's open
Run receipt, when there is one
mån 16  [photo] Oxfilé med potatisgratäng  [Cooked]
ons 18  [photo] Kycklinggryta  [Tonight]
tor 19  + New dinner                        ← an open day ahead, faint
        + Lunch                             ← a lunch day ahead, fainter, above the dinner
lör 21  [photo] Pannkakor
        Lunch  Ärtsoppa                     ← a planned lunch, one quiet line
⋯       Prep this week
```

Lunch (2026-11-20) is optional and never the default: nothing plans one unasked. Weekends,
Swedish public holidays and days the household is off offer it with a faint "+ Lunch" above the
dinner; any day's sheet has "+ Lunch". A lunch's sheet picks the recipe and servings and has
"Ta bort lunch"; no skip or eating out. A day off reads "Fridag" under its date. The month grid
shows dinners only.

Month: the heading is the month ("November 2026", ‹ › step a month) with how many dinners are
planned under it; a calendar of seven columns, Monday first, each day its number (today's in
red) over the dinner's photo or tinted cover, an empty square when nothing is planned. A day
opens its week. Servings are set in the day's sheet, not shown in the row.

### Day row

The date sits in the margin (today's number in red). A planned day shows the dish's photo or
tinted cover, its name, and tags: Cooked (green, when Done in cook mode was pressed that day),
Tonight (red, until it's cooked), Uses leftovers / Leftovers for (purple),
Eating out and Skipped (grey). A pinned day has a small lock. The dish's name opens its recipe;
the rest of the row opens the day.

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
planned:       a row with the dish's photo or tinted cover
empty:         a faint "+ New dinner" row
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

Ask about a day (§5.4):

```md
Input inside the open slot sheet, sent to the chat with the day named
Tore's reply shows in a note; changed slots animate subtly
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

Shop is a to-do page (2026-11-18):

```md
Icon + "Shop"
3 left · week 47
+ Add, e.g. 2 l milk                  [scan]   ← one line, sticky
⌄ [Fruit & veg] 2
    [ ] Gul lök     till kvällens kycklinggryta     3 st
⌄ [Dairy & eggs] 1
› [In the basket] 1                            ← folded shut
This month's spending (§6.7)
⋯   Show as text
```

Sections are tinted tags that fold (green fruit, veg and herbs; blue dairy, frozen and fish;
yellow the pantry and bread; orange meat and deli; grey the rest). Checkboxes are square.

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

Sections come from the item's ingredient with no model. A name Tore hasn't learned waits in
"Other" and moves once it has.

### Scanner (2026-11-16)

A round button beside "Show as text" opens a sheet:

```md
Scan what you unpack                         ✕
┌──────────────────────────────┐
│  camera, with a saffron frame │
└──────────────────────────────┘
Hold a barcode in the frame.
✓ Mjölk is in the pantry              Undo
✓ Bröd ticked off the list            Undo
```

- A pack is read once while it stays in view; the frame pulses when one is caught.
- "Looking it up…" while a new code is looked up; a code nobody knows asks for its name inline.
- Undo takes the pack out of the pantry, or unticks the item, as tapping it on the list does.
- If the camera can't be used, the sheet says so and points at adding by name.

This follows your spec’s rule that groceries are the reliability anchor and must survive missing plans, missing pantry data, and LLM failure. 

### Grocery-row long-press sheet (shipped, 2026-08)

Long-pressing a grocery row (500 ms) raises an item sheet, mirroring §6.2's
slot sheet:

```md
Greek yoghurt
─────────────────────────────
[ input field scoped to this item ]
```

The scoped input goes to the person's chat with a line naming the item
(`From the Shop screen, about "Greek yoghurt" on this week's shopping list: …`),
and Tore's reply shows in a note under the header (§5.4). Calm rules as §6.2's slot sheet: quiet placeholder ("Anything
about this item…"), no AI branding, silent until used. Escape or the scrim
closes without dispatching.

## 6.4 Capture

### Job

Answer:

```md
What can Tore do with this?
```

### Layout

```md
Sheet over the current screen, from the centre tab
- The conversation, from where it was
- Quick swaps above the input
- Input: text, photos, send
```

### Capture result pattern

Each change Tore makes is a line with Undo, not a paragraph:

```md
Logged the receipt · ICA · 438 kr        [Undo]
Saved Kycklingspett med tzatziki         [Undo]
Added mjölk to the pantry                [Undo]
```

Tore's words around them stay short: what it did in a line, or the one question it needs answered.

### Rule

The default outcome should be a change made, not a question. A photo with no words is something to
act on: a receipt logged, a recipe saved, a shelf or fridge put into the pantry.

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

One grouped list, like a phone's own settings (2026-11-20). Each row shows what it's set to, and
opens its setting on a page of its own (`/settings/<section>`, with ‹ Settings back to the list).
Like the other pages, each has its tinted duotone icon above its title, and the same icon small on
its row (2026-11-21): Settings gear (grey), Namn house (orange), Medlemmar users (blue), Kost och
allergier carrot (green), Saker Tore har lärt sig brain (purple), AI-användning coins (yellow),
Dina hushåll buildings (grey). The rows that aren't pages have one too, so every label lines up:
Språk translate, Utseende half circle, Logga ut sign-out (red).

```md
Household     Name › · Members › · Language (shown, chosen once)
Food          Diet and allergies ›
Tore          Things Tore has learned › · AI usage ›
This device   Look  [System | Light | Dark]
Account       Your households › (two or more) · Sign out
```

The look is the device's, kept in the browser, so it's chosen on the list itself.

Diet and allergies are two rows of chips, "We eat" and "Never include". Every plan is
checked against them. A chosen chip is filled in the text colour, not saffron.

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
Remove and Leave on members appear only when there is more than one member: the last member can't leave.
Someone still waiting can always be removed.
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
Shown at /welcome to a household's members until one of them picks. Everything the household stores is in this language.
It can't be changed later. New members, and anyone moved into it, start in it.
```

### Kitchen Memory

```md
Things Tore has learned

Your household                 ▰▰▱▱▱▱  40% full
Two adults and a six-year-old who dislikes mushrooms.   [Forget]

Notes                          ▰▱▱▱▱▱  25% full
Thursdays are fragile: leftovers or low-effort meals work best.   [Forget]
Fish rarely sticks on weekdays.                         [Forget]
```

Entries come from the weekly review and from what people tell Capture. Forgetting one is direct.
How full each part is shows as a small bar filled in blue (`.meter`), with the number beside it.

Rules:

```md
No rating UI.
No onboarding questionnaire.
No forced preference maintenance.
No AI debug logs for normal users.
```

Google’s PAIR guidance emphasizes that AI products need clear mental models, staged expectation-setting, and feedback/control mechanisms, especially because AI systems adapt over time. ([Pair][8])

## 6.7 Spending (under Shop)

What did food cost this month? It ends the Shop screen, below the add field.

```md
Spent this month                    [📷 Scan receipt]
1 610 kr
+12% compared with last month

ICA Kvantum   8/11             813 kr
Sushibaren    13/11            450 kr
```

Rules:

```md
No page of its own (2026-11-15). Scanning sits where the shopping ends.
A receipt is a photo, here or in the chat. No typed form.
No tabs, charts or breakdowns: nothing here that changes what Tore does next.
Receipts record cost only. They never change the list.
```

---

## 6.8 Hemma (2026-11-19)

### Job

Show what Tore believes is at home, and let it be corrected in one tap. Tore keeps the
pantry (§2.4): Shop's ticks put things here, Done in cook mode uses them up. Nothing on this
page asks to be done.

### Layout

- Title Hemma, with "8 saker · 3 går ut snart".
- One line to put something away, as on Shop: "1 l mjölk". It's sure from then on.
- Groups, each a tag that folds like Shop's sections: Kyl (dairy, meat, fish, deli), Frukt
  & grönt, Frys, Skafferi (the rest), and Slut folded shut at the bottom.
- A row: its picture, the name, the amount or when it was bought, and at most one thing said
  about it at the end. The picture is one of Iconito's Food icons (MIT, warm flat
  illustrations; served from `/images/food`, so every device shows the same one), 32 px, with
  no tile behind it. What a pantry has and the set lacks was drawn in the same style: tin, jar,
  salt, frozen, avocado, chili, ginger, crispbread. Jev picks one per ingredient from the 99
  Tore has (`Tore.Pantry.Icons`); until then the row has its category's (milk for dairy, beef
  for meat, carrot for produce, flour for dry goods, tin, jar…). Under Slut it's faded and
  grey. There are no photos: pack photos and the household's own were dropped (2026-11-20)
  for one consistent look.

### What a row says

- **Går ut fre** (red): a date from the label or the household, two days off or less.
- **Håller nog till fre** (red): the same, when Tore estimated the date from shelf life.
- **Gick ut igår** (red): a date it has outlived. Tapping asks.
- **Finns kvar?** (grey): Tore isn't sure any more. Tapping asks.
- Asking puts **Finns** and **Slut** where the tag was. Finns makes it sure (and drops a
  date it outlived); Slut moves it to Slut. Under Slut, **Finns** brings it back.

## 6.9 Veckobudget (2026-11-19)

### Job

Answer one question mid-week: where does this week land against the budget? A past-tense page
to read; the only thing to change on it is the budget itself. Mockup: "Veckobudget" in the
Tore kitchen pages artifact.

### Layout

- The top bar names the page; there's no title repeating it. Then "Vecka 47 · 16–22
  november", the one sentence "Veckan landar runt 972 kr", and a tag: "72 kr över budget"
  (red) or "226 kr under budget" (green). No budget, no tag.
- Once a forecast with a range has earned the page (SPEC.md, "Forecast": it beat the one below
  over the last weeks and its range held about 80 % of the time), the sentence is the range,
  to the ten kronor, wide side out: "Veckan landar på 940–1 010 kr". Once the simulation has
  earned it, a muted "12 % risk att gå över budget" sits beside the tag (1–99 %, never a sure
  thing). Which forecast has earned it is worked out after the page opens, so until then, and
  until there is history, the page reads as above.
- Four numbers, two by two on a phone, in a row on a laptop: **Budget** (tap the number or
  its pencil to change it in place; it becomes the household's budget and a week's own gives
  way to it; blank means none), **Betalt hittills** (receipts towards this week), **Kvar
  enligt planen** (expected minus paid, with how many open days were counted), **Snitt per
  vecka** (the weeks before this one that had receipts).
- **Åtta veckor**: what each week paid, one sage hue. Earlier weeks pale, this week strong
  with what's still expected paler above it ("≈972"), each week's budget as a dashed line that
  steps where it changed, named where it starts ("Budget 1 400") and at each step ("1 500").
  Changing the budget on the page sets it from the week shown on. A week over
  budget shows only as its red number. Each bar says its week and amount on hover.
- **Var pengarna gick**: the last four weeks' receipt lines by Shop's sections, costliest
  first, each a bar in its section's tint with kronor and share. A row opens to its five
  costliest items ("Kycklinglårfilé · 3 gånger · 327 kr").
- **Kvitton**: the latest receipts, a date, the store's initial and name, the total.
- On a laptop the chart and the sections sit side by side, the receipts under them.

### A receipt

Opens from Kvitton at `/budget/receipts/:id`: slides in from the right, beside the page on a
laptop and over it on a phone. Store, date, the week it counts towards (a tag; tap to move it to
the other week), total. Then its lines grouped by section with subtotals, costliest first. Tap
a line to list the sections and move it; its section is what Tore was told when it logged
the receipt, otherwise Övrigt.

## 6.10 Erbjudanden (2026-11-20)

### Job

Answer: what's on offer this week that we'd buy anyway? Mockups: "Erbjudanden, its own page"
and "Erbjudanden on a laptop" in the Tore kitchen pages artifact. The groups come from what Tore
already knows (`Tore.Deals.page/3`), and one from Jev's guesses (2026-11-20, below).

### Layout

- "Vecka 47 · 16–22 november", then one sentence: "Spara runt 62 kr på sånt ni ändå köper",
  the best deal per ingredient over the first two groups.
- **Till veckans middagar** (orange): deals on what a dinner from today on calls for, with the
  dinner's name. **Sånt ni brukar köpa** (green): deals on the household's basics. **Övriga
  erbjudanden** (grey): the rest, folded, with its count. Jev (`Tore.Deals.Picks`) sorts every
  offer from the household's diet, memory, meals, basics, recent receipts and recipes: something
  they buy joins Sånt ni brukar köpa; **Kanske något för er** (blue, open, surest first) is what
  they might want; **Inte för er** (grey, folded, last) is what Jev is at least half sure isn't
  for them (cat food for a household without a cat). Offers Jev hasn't been asked about, or
  says no to unsurely, stay under Övriga. It guesses from the little it knows at first and gets
  better as receipts come in.
- A deal: its name and size, the store's logo and name, "t.o.m. sön 22/11", the price
  ("89 kr", "2 för 20", "99 kr/kg") over the regular price struck through, and on a laptop
  what it saves. On a phone the store and end date sit under the name.
- A + square puts it on this week's list, under its ingredient's name when it's matched to one;
  a deal already on the list shows "På listan" (a check on a phone, in the same square). The
  item remembers its offer: if the store withdraws it before the item is ticked, Shop asks under
  the item, "Erbjudandet är borta. Behålla?", with Behåll and Ta bort. An offer that simply runs
  to its end date asks nothing.
- A folded group opened by hand stays open as the page updates (a + in it).
- A store's logo is the one its own site gives phones (`Tore.Deals.Logo`), taken from the page
  Tore reads offers from, so it costs no extra request and each morning keeps it current; the
  store's first letter until its page has been read.
- **Butiker** at the foot: each store with its offers this week, a switch, and × to remove.
  "Lägg till butik" opens the link field; it's open from the start when there are none. A link
  Tore has no parser for gets "Tore kan inte läsa den butiken än". A store just added is read at
  once, in the background, and a toast says how many offers Tore found, or that it couldn't
  read the store now (it tries again every morning).
- Without stores: "Erbjudanden från butikerna ni handlar i" and where to add one. With stores but
  nothing in yet: that Tore reads them every morning.

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

See §3.3 and the desktop shell in §5.1.

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

The tokens live at the top of `assets/css/app.css`: colour (§4.3), radius, shadow, type
scale and tap size. Screens use those tokens only, never raw colours or one-off values.

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
Today · Plan · Tore · Shop · Recipes
```

Recipes earned its tab on 2026-11-17: the household keeps baking, sauces and assemblies there
to find and start right away, without putting them on the week. It is a library you start
from (each recipe is a page with Cook/Bake now), not a table to manage.

Forbidden as top-level nav:

```md
Pantry
Deals
Receipts
Costs
KitchenRuns
Ingredients
```

Those are system resources and must appear contextually inside an operational
surface.

## 16.2a Pages and collections (2026-11-17)

Borrowed from Notion's structure, and since 2026-11-18 its look too (Papper, §4.2).

- **A recipe is a page:** cover photo, title, then quiet property rows (Collection, Time,
  Servings as a stepper that scales the amounts, At home, Source, Last made), then three
  actions (Cook/Bake now, Put on the week, Ask Tore), then sections. The star is in ⋯. Ask Tore
  opens the tray on that recipe's own conversation ("About <dish>"), which is there again next
  time. What's missing is asked about when cooking starts. The name is on the cover photo.
- **Put on the week** lists the next seven days. Tapping a day puts the dish there (green,
  with a tick); another day moves it, the same day again takes it off. "On Saturday · Undo"
  stays on one line under the days. A day that had the dish before shows it in plain text.
- **At home** checks the recipe against the pantry with no model: "All of it", or what's
  missing with Put on the list. When all of it is already on this week's list (not ticked off),
  it says "On the list" from the start, here and on Today.
- **Collections** are Dinner, Baking, Sauces & sides and Assemblies, each with a Phosphor
  icon and a tag colour (orange, yellow, green, blue). Recipes groups by them under their
  tags, in a Gallery (two to a row, 4:5 pictures, the name and time on the picture) or a List (one line
  each); a tag shows its collection alone. The view chosen is remembered per person. Only
  dinners are planned or suggested for a day.
- **Every dish has an icon**, read from its name (Swedish or English) and otherwise its
  collection's; no model is asked (`ToreWeb.Look.icon/1`). No emoji anywhere.
- **A meal of parts** (2026-11-19, `.docs/specs/meal-parts.md`): a dinner put together from
  other recipes, "Entrecote med bearnaise" from Bearnaise, Stekt entrecote, Pommes i airfryer
  and Tomatsallad. It follows its parts. Its page has a **Delar** row linking them, its
  ingredients under each part's name, and until its first cook each part's method with "Tore
  lägger delarna i en ordning när du börjar laga". Cook mode then writes one order that weaves
  the parts; changing a part writes it again. A part's page has **Ingår i**. New recipe offers
  **Sätt ihop av andra recept**: a name, servings and the recipes to tick, sauces and sides
  first. Everything else (planning, the list, At home, the budget, Done) sees one dinner.
- **Favourites:** a recipe's ⋯ stars it. Starred recipes lead Recipes and are listed in the
  menu.
- Rows answer hover with a soft background; chrome stays quiet.
- **Pictures** share one house style (one fixed art direction appended to every dish), so
  the library looks like one cookbook.

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

