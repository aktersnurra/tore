# Recipe image live-update — design

**Date:** 2026-06-17
**Status:** approved (in-session)
**Sub-spec of:** recipe image proxy (`2026-06-17-recipe-image-proxy-design.md`)

---

## Problem

Recipe image generation/fetch runs in a fire-and-forget `Task.start` after
`Recipes.create/1` returns (`maybe_generate_image/2`). When the user lands on a
just-scraped recipe, `image_path` is still `nil` — so the proxy `<img>` is hidden
by its `:if` guard and the placeholder icon shows. The image only appears on a
manual page reload, after the task has stored the object and written the key.

The user wants the image to appear on screen the moment it is available, without
a manual refresh. Scraping itself must stay snappy (no blocking on image work).

## Solution

Keep generation async; broadcast over PubSub when the image lands, and have the
recipe LiveView patch its assigns in place. Mirrors the existing
`Tore.Planning` → `Tore.PubSub` → `PlannerLive` pattern already in the codebase.

### Broadcast — `Tore.Recipes.generate_image/2`

On success (after the `Repo.update_all` that sets `image_path: key`), broadcast:

```elixir
Phoenix.PubSub.broadcast(Tore.PubSub, "recipes", {:recipe_image, recipe.id, key})
```

The topic is the literal string `"recipes"`. The message carries the recipe id
and the stored S3 key. No broadcast on failure (image stays absent, as today).

### Subscribe — `ToreWeb.RecipeLive`

`mount/3`: when `connected?(socket)`, `Phoenix.PubSub.subscribe(Tore.PubSub,
"recipes")`. (First connect mount has no socket transport; the second,
connected mount subscribes — same guard `PlannerLive` uses.)

`handle_info({:recipe_image, id, key}, socket)`:

- Patch the matching recipe in the `:recipes` list — set its `image_path` to
  `key` for the recipe whose `id == id`, leave the rest untouched.
- If `socket.assigns.selected` is non-nil and its `id == id`, set
  `selected.image_path` to `key` too (the open detail view).
- `{:noreply, ...}` with the updated assigns.

The `<img src={~p"/images/recipes/#{recipe.id}"}>` and its `:if={recipe.image_path}`
guard already exist (from the proxy change). Once `image_path` flips from `nil`
to the key, the guard passes and LiveView renders the `<img>`, which fetches via
the proxy. No template change needed.

### Why patch assigns instead of `reload_recipes/1`

A full `Recipes.list()` reload would also work but throws away the user's current
search/filter/sort state and re-queries the DB on every image. Patching the one
recipe in place is cheaper and preserves view state. The list is small
(household scale).

## Out of scope

- Receipt images (separate concern, disk-stored).
- A loading spinner on the image tile (placeholder icon already shows until the
  image lands; good enough).
- Synchronous fetch of site-provided images (considered; rejected in favor of
  keeping scrape snappy + live-update).
- Backfilling existing URL-shaped `image_path` rows (dev, re-scrapeable).

## Testing

- **`Tore.RecipesTest`:** `generate_image/2` broadcasts `{:recipe_image, id, key}`
  on the `"recipes"` topic on success. (Subscribe in the test, assert_receive.)
- **`ToreWeb.RecipeLiveTest`:** after the LiveView mounts, broadcasting
  `{:recipe_image, recipe_id, key}` causes the rendered page to include the proxy
  `src` (`/images/recipes/<id>`) for that recipe where it previously showed the
  placeholder. (Use `Phoenix.PubSub.broadcast` from the test, then `render(lv)`.)
