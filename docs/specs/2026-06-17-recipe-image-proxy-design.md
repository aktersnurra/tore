# Recipe image proxy — design

**Date:** 2026-06-17
**Status:** approved (design settled in prior session)
**Sub-spec of:** local Garage dev storage (`2026-06-12-local-garage-dev-storage-design.md`)

---

## Problem

Recipe images upload to Garage and live in the `tore-recipes` bucket. But the
browser cannot display them. `Tore.Storage.S3.get_object_url/2` returns a bare
S3-API URL (`http://host:3900/tore-recipes/recipes/:id/:uuid.jpg`). Garage's S3
API requires SigV4-signed requests, so an anonymous `<img src>` GET gets `403
AccessDenied`. Garage has no `[s3_web]` (anonymous web) endpoint configured
either.

`recipe.image_path` currently holds this un-displayable S3 URL, and three
LiveViews render it directly as `<img src={recipe.image_path}>`.

## Solution

A Phoenix image proxy: `garage → elixir → browser`. A controller route fetches
the object server-side with a signed request and streams the bytes to the
browser. No Caddy, no `X-Accel-Redirect`, no presigned URLs. Chosen over
`X-Accel-Redirect` (which Gustaf uses for *video* via Caddy) because the content
is tiny (~250 KB, household scale), so BEAM streaming cost is negligible, and it
adds no new internet-exposed surface — only the already-exposed Phoenix port.
Presigning would expose `:3900`; `X-Accel` would need Caddy plus a web endpoint.

### Route

```
GET /images/recipes/:id
```

`:id` is the recipe id. A recipe owns at most one image, so the id is a stable,
non-secret handle — no raw S3 keys in URLs. The route lives in the authenticated
`scope "/"` under `pipe_through [:browser, :require_auth]`, so `ToreWeb.Plugs.Auth`
sets `current_user` from the `user_id` session before the controller runs. No
extra per-recipe authorization: any authenticated household member may view any
recipe image, matching the existing LiveView access model (all recipes visible
to all members).

### What `image_path` stores

Changes from the bare S3 URL to the **S3 object key** (e.g.
`recipes/42/<uuid>.jpg`). The key is the durable identifier; the proxy
reconstructs `bucket + key` for the signed GET. This is the semantics change to
shipped code.

- `Tore.Recipes.generate_image/2` stores `key` in `image_path` instead of the
  URL returned by `put_object`.
- Existing rows (dev only; DB is rebuildable, app not live) hold full URLs. Not
  migrated — dev re-scrapes. No production data exists.

### Fetching bytes — new storage callback

The `Tore.Storage` behaviour currently has `put_object`, `get_object_url`,
`delete_object` — but no way to *fetch* an object body. Add:

```elixir
@callback get_object(bucket :: String.t(), key :: String.t()) ::
            {:ok, binary()} | {:error, term()}
```

- **`Tore.Storage.S3`:** `ExAws.S3.get_object(bucket, key) |> ExAws.request()`
  → on `{:ok, %{body: body}}` return `{:ok, body}`; on `{:error, reason}` return
  `{:error, reason}`. The request is SigV4-signed by ex_aws using the configured
  Garage credentials.
- **`Tore.Storage.Mock`:** return `{:ok, body}` from the Agent map if present,
  else `{:error, :not_found}`.

### Controller — `ToreWeb.RecipeImageController`

`show(conn, %{"id" => id})`:

1. `recipe = Tore.Recipes.get!(id)` (existing fetch; raises → 404 via Phoenix).
2. If `recipe.image_path` is `nil` → `send_resp(conn, 404, "")`.
3. `Tore.Storage.client().get_object(Tore.Storage.Buckets.recipes(), recipe.image_path)`:
   - `{:ok, body}` → `conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)`.
   - `{:error, _}` → `send_resp(conn, 404, "")`.

Content type is `image/jpeg` — `generate_image` always writes `.jpg` with
`content_type: "image/jpeg"`. No content negotiation needed.

### Rendering — proxy URL in LiveViews

LiveViews stop using `image_path` directly as `src`. Where `recipe.image_path`
is set, render `src={~p"/images/recipes/#{recipe.id}"}`. The `:if` guards stay
keyed on `image_path` presence (nil → show the placeholder icon, unchanged).

Touched: `planner_live.ex` (3 sites), `recipe_live.ex` (multiple sites tied to
`@selected` / `recipe`).

## Out of scope

- Caching / `Cache-Control` headers (revisit if it matters; household scale).
- Receipt images (`Tore.Costs` writes those to local disk — a separate "discard
  the pixels" decision deferred to the receipt-ingestion feature).
- Migrating existing URL-shaped `image_path` rows (dev-only, re-scrape).
- Streaming in chunks (whole body in memory is fine at ~250 KB).

## Testing

- **`Tore.StorageMockTest`:** `get_object/2` returns stored body; returns
  `{:error, :not_found}` for a missing key.
- **`ToreWeb.RecipeImageControllerTest`:** authenticated request for a recipe
  with an image returns 200 + `image/jpeg` + the body (Mock seeded);
  recipe with `nil` image_path → 404; unauthenticated → redirect to `/login`
  (pipeline behavior).
- **`Tore.RecipesTest`:** `generate_image/2` stores the S3 key (not a URL) in
  `image_path`.
