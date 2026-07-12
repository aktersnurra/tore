# Recipes Page Redesign

**Date:** 2026-05-13  
**Scope:** `lib/scullion_web/live/recipe_live.ex` render/template only — no backend changes

---

## Goal

Improve hierarchy, focus, and usability of the recipes page. The existing two-card structure (search card + import card) collapses into a single card. No layout restructuring beyond collapsing those two cards into one.

---

## Single Control Card

Everything above the grid lives in one `.card`:

```
┌─────────────────────────────────────────────────┐
│  Recipes                        [ + New recipe ] │
│  2 recipes                                       │
│                                                  │
│  [ 🔍 Search recipes, ingredients, or meals… ]  │
│                                                  │
│  All  Meal  Component  Assembly      More filters⌄│
│                                                  │
│  ┌───────────────────────────────────────────┐  │
│  │ 💡 What can we cook tonight?             │  │
│  │ Get ideas from your pantry + this week's  │  │
│  │ deals                        [ Get ideas ]│  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  [ 📎 Paste URL or drop screenshots…  ] [Import] │
└─────────────────────────────────────────────────┘
```

### Search bar
- Height: `h-12` (up from `h-11`)
- Border: `border-2 border-[color:var(--border)]` resting, `border-[color:var(--accent)]` focus
- Background: `bg-[color:var(--hairline)]` (filled, not transparent)
- Makes search the visually dominant element in the card

### Type filter row
- Chips: All | Meal | Component | Assembly — always visible, unchanged active/inactive styles
- "More filters ⌄" button on the right of the same row
- Clicking it toggles an expanded section below showing: tag chips, time filter, sort
- Collapsed by default (new `show_more_filters` boolean assign)

### Hero prompt
- Subtle `bg-[color:var(--accent-soft)]/40` rounded row inside the card
- Left: spark icon + bold line "What can we cook tonight?" + muted sub-line
- Right: `[ Get ideas ]` button (secondary variant)
- For now the button opens a flash/toast saying "Coming soon" — no backend needed
- This is the one AI-native entry point; keeps the page from feeling like pure recipe storage

### Import row
- Single `<input>` row: placeholder "Paste a recipe URL or drop screenshots…"
- Camera icon button on the right edge of the input triggers the hidden `live_file_input`
- One `[ Import ]` button to the right of the input
- Button behavior: if `uploads.recipe_images.entries` is non-empty → `extract_from_images`; if URL is filled → `scrape_submit`; if both → prefer URL
- Removes the separate photo upload label and standalone Extract button
- Entry list (uploaded file names with cancel) renders below the input row as today

---

## Card Grid (unchanged structure, style tweaks only)

- Aspect ratio, image, title, time chip — no structural change
- Hover: keep existing `scale-[1.02]` on image + shadow lift
- Spacing: reduce `gap-5` to `gap-4` for tighter rhythm

---

## Spacing / vertical rhythm

- Inside the single card: use `space-y-4` between search, filter row, hero prompt, import row
- Remove the `mb-6` between the two old cards (they're now one)
- Header (title + count + button) separated from search by `mb-5` as today — keep

---

## "More filters" expand state

New assign: `show_more_filters: false`  
New event: `"toggle_more_filters"` — flips the boolean  
When expanded, renders below the type row:
- Tag chips row (same as today)
- Time filter row (same as today)  
- Sort row (same as today)

No animation required — simple `if` conditional is fine.

---

## Import button logic

```
[ Paste URL or drop screenshots…  📷 ] [ Import ]
```

Single `phx-click="import_action"` event (new):
```elixir
def handle_event("import_action", %{"url" => url}, socket) do
  cond do
    socket.assigns.uploads.recipe_images.entries != [] ->
      send(self(), {:extract_images, read_uploads(socket)})
      {:noreply, assign(socket, image_extract_state: :loading)}
    String.trim(url) != "" ->
      send(self(), {:scrape, String.trim(url)})
      {:noreply, assign(socket, scrape_state: :loading)}
    true ->
      {:noreply, assign(socket, error: "Paste a URL or drop screenshots first")}
  end
end
```

Old events `scrape_submit` and `extract_from_images` can be removed once the new event is wired.

---

## Out of scope

- No backend changes
- No new routes or live views
- No animation on the "More filters" expand
- Hero prompt does not call any AI endpoint in this iteration — stub only
- Card metadata improvements (cuisine, protein, etc.) — future iteration
- Recipe card images remain as-is (already working)
