# Recipes Page Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the two search/import cards into one, strengthen the search bar, add a "More filters" toggle, add a hero prompt stub, and unify the import row into a single action.

**Architecture:** All changes are render-only in `lib/scullion_web/live/recipe_live.ex`. One new boolean assign (`show_more_filters`), one new event (`toggle_more_filters`), and one new event (`import_action`) replacing `scrape_submit` and `extract_from_images`. No backend, no new routes.

**Tech Stack:** Elixir, Phoenix LiveView, Tailwind CSS v4, HEEx templates

---

## File Map

| File | Change |
|------|--------|
| `lib/scullion_web/live/recipe_live.ex` | Main change — mount, events, render |
| `test/scullion_web/live/recipe_live_test.exs` | New test file |

---

### Task 1: Add `show_more_filters` assign and `toggle_more_filters` event

**Files:**
- Modify: `lib/scullion_web/live/recipe_live.ex`

- [ ] **Step 1: Add `show_more_filters: false` to mount assigns**

In `mount/3`, add to the assign block (around line 10):

```elixir
show_more_filters: false,
```

Full assign block after change:
```elixir
|> assign(
  recipes: Recipes.list(),
  search: "",
  filter_tags: [],
  filter_type: :all,
  filter_max_min: :any,
  sort: :recently_added,
  scrape_url: "",
  scrape_state: :idle,
  scrape_result: nil,
  image_extract_state: :idle,
  extracted_attrs: nil,
  selected: nil,
  detail_tab: "ingredients",
  form: nil,
  error: nil,
  sorts: @sorts,
  types: @types,
  time_filters: @time_filters,
  show_more_filters: false
)
```

- [ ] **Step 2: Add `toggle_more_filters` event handler**

Add after the `handle_event("sort", ...)` handler (around line 65):

```elixir
def handle_event("toggle_more_filters", _, socket) do
  {:noreply, assign(socket, show_more_filters: !socket.assigns.show_more_filters)}
end
```

- [ ] **Step 3: Add `get_ideas` stub event handler**

Add immediately after the `toggle_more_filters` handler:

```elixir
def handle_event("get_ideas", _, socket) do
  {:noreply, put_flash(socket, :info, "Coming soon")}
end
```

- [ ] **Step 4: Describe with jj**

```bash
jj describe -m "feat(recipes): add show_more_filters assign and toggle event"
```

---

### Task 2: Add unified `import_action` event, remove old import events

**Files:**
- Modify: `lib/scullion_web/live/recipe_live.ex`

- [ ] **Step 1: Add `import_action` handler**

Add after `handle_event("get_ideas", ...)`:

```elixir
def handle_event("import_action", %{"url" => url}, socket) do
  cond do
    socket.assigns.uploads.recipe_images.entries != [] ->
      binaries =
        consume_uploaded_entries(socket, :recipe_images, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)
      send(self(), {:extract_images, binaries})
      {:noreply, assign(socket, image_extract_state: :loading, error: nil)}

    String.trim(url) != "" ->
      send(self(), {:scrape, String.trim(url)})
      {:noreply, assign(socket, scrape_state: :loading, error: nil)}

    true ->
      {:noreply, assign(socket, error: "Paste a URL or drop screenshots first")}
  end
end
```

- [ ] **Step 2: Remove old `scrape_submit` and `extract_from_images` handlers**

Delete the entire `handle_event("scrape_submit", ...)` function (lines ~132–141) and the entire `handle_event("extract_from_images", ...)` function (lines ~162–176).

- [ ] **Step 3: Describe with jj**

```bash
jj describe -m "feat(recipes): unify import into single import_action event"
```

---

### Task 3: Rewrite the render — single control card

**Files:**
- Modify: `lib/scullion_web/live/recipe_live.ex` — `render/1` function

- [ ] **Step 1: Replace the two `.card` blocks with one**

Replace from `<.card class="mb-6">` (line ~224) through `</.card>` of the import card (line ~348) with:

```heex
<.card class="mb-6">
  <header class="flex items-center justify-between gap-4 mb-5 pb-5 border-b border-[color:var(--hairline)]">
    <div>
      <h1 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h1);">Recipes</h1>
      <p class="mt-0.5 text-[color:var(--muted)]" style="font-size: var(--t-meta);">{recipe_count_label(@recipes)}</p>
    </div>
    <.button variant={:primary} phx-click="new_recipe">
      <.icon name="hero-plus" class="size-4" /> New recipe
    </.button>
  </header>

  <div class="space-y-4">
    <%!-- Search --%>
    <form phx-change="search" class="relative">
      <.icon name="hero-magnifying-glass" class="size-5 absolute left-3.5 top-1/2 -translate-y-1/2 text-[color:var(--subtle)]" />
      <input
        type="text"
        name="query"
        value={@search}
        placeholder="Search recipes, ingredients, or meals…"
        class="w-full h-12 pl-10 pr-3 bg-[color:var(--hairline)] rounded-[var(--r-lg)] border-2 border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
        style="font-size: var(--t-body);"
      />
    </form>

    <%!-- Type filters + More filters toggle --%>
    <div class="flex items-center justify-between gap-2">
      <div class="flex flex-wrap gap-2">
        <button
          :for={type <- @types}
          phx-click="filter_type"
          phx-value-type={type}
          class={[
            "px-3 h-8 rounded-[var(--r-pill)] transition-colors capitalize",
            @filter_type == type && "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)]",
            @filter_type != type && "bg-[color:var(--hairline)] text-[color:var(--muted)] hover:text-[var(--text)]"
          ]}
          style="font-size: var(--t-meta); font-weight: 500;"
        >
          {type}
        </button>
      </div>
      <button
        type="button"
        phx-click="toggle_more_filters"
        class={[
          "shrink-0 inline-flex items-center gap-1 px-3 h-8 rounded-[var(--r-pill)] transition-colors",
          @show_more_filters && "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)]",
          !@show_more_filters && "text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[color:var(--hairline)]"
        ]}
        style="font-size: var(--t-meta); font-weight: 500;"
      >
        More filters
        <.icon name={if @show_more_filters, do: "hero-chevron-up", else: "hero-chevron-down"} class="size-3.5" />
      </button>
    </div>

    <%!-- Expanded filters --%>
    <div :if={@show_more_filters} class="space-y-3 pt-1">
      <div class="flex flex-wrap gap-2">
        <button
          :for={tag <- common_tags()}
          phx-click="filter_tag"
          phx-value-tag={tag}
          class={[
            "px-3 h-7 rounded-[var(--r-pill)] transition-colors",
            tag in @filter_tags && "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)]",
            tag not in @filter_tags && "text-[color:var(--muted)] hover:text-[var(--text)]"
          ]}
          style="font-size: var(--t-meta);"
        >
          {tag}
        </button>
      </div>
      <div class="flex flex-wrap items-center gap-x-6 gap-y-2 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
        <span class="text-[color:var(--subtle)] font-medium">Time</span>
        <button
          :for={t <- @time_filters}
          phx-click="filter_time"
          phx-value-max={t}
          class={[
            @filter_max_min == t && "text-[color:var(--accent)] font-medium",
            @filter_max_min != t && "hover:text-[var(--text)]"
          ]}
        >
          {if t == :any, do: "Any", else: "≤ #{t} min"}
        </button>
        <span class="ml-4 text-[color:var(--subtle)] font-medium">Sort</span>
        <button
          :for={s <- @sorts}
          phx-click="sort"
          phx-value-by={s}
          class={[
            @sort == s && "text-[color:var(--accent)] font-medium",
            @sort != s && "hover:text-[var(--text)]"
          ]}
        >
          {sort_label(s)}
        </button>
      </div>
    </div>

    <%!-- Hero prompt --%>
    <div class="flex items-center justify-between gap-4 px-4 py-3 rounded-[var(--r-lg)] bg-[color:var(--accent-soft)]/40">
      <div class="flex items-start gap-3">
        <.icon name="hero-sparkles" class="size-5 text-[color:var(--accent)] shrink-0 mt-0.5" />
        <div>
          <p class="font-semibold text-[var(--text)]" style="font-size: var(--t-meta);">What can we cook tonight?</p>
          <p class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">Get ideas based on your pantry and this week's deals</p>
        </div>
      </div>
      <.button variant={:secondary} phx-click="get_ideas">Get ideas</.button>
    </div>

    <%!-- Import row --%>
    <form phx-submit="import_action" phx-change="validate" class="space-y-2">
      <div class="flex gap-2">
        <div class="relative flex-1">
          <input
            type="text"
            name="url"
            value={@scrape_url}
            placeholder="Paste a recipe URL or drop screenshots…"
            class="w-full h-11 px-3.5 bg-[var(--surface)] rounded-[var(--r-lg)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)] pr-10"
            style="font-size: var(--t-body);"
          />
          <label class="absolute right-3 top-1/2 -translate-y-1/2 cursor-pointer text-[color:var(--subtle)] hover:text-[color:var(--muted)]">
            <.live_file_input upload={@uploads.recipe_images} class="sr-only" />
            <.icon name="hero-camera" class="size-5" />
          </label>
        </div>
        <.button
          type="submit"
          variant={:primary}
          disabled={@scrape_state == :loading or @image_extract_state == :loading}
        >
          {cond do
            @scrape_state == :loading -> "Importing…"
            @image_extract_state == :loading -> "Extracting…"
            true -> "Import"
          end}
        </.button>
      </div>
      <div :for={entry <- @uploads.recipe_images.entries} class="flex items-center gap-2 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
        <span class="flex-1 truncate">{entry.client_name}</span>
        <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref}
                class="text-[color:var(--subtle)] hover:text-[color:var(--danger)]">✕</button>
      </div>
    </form>
  </div>
</.card>
```

- [ ] **Step 2: Tighten card grid spacing**

Find the grid div (around line 355):
```heex
<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-5">
```
Change `gap-5` to `gap-4`:
```heex
<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
```

- [ ] **Step 3: Verify the page compiles**

```bash
mix compile --warnings-as-errors 2>&1 | tail -20
```

Expected: no errors. If there are template compilation errors, fix them before continuing.

- [ ] **Step 4: Describe with jj**

```bash
jj describe -m "feat(recipes): single control card with stronger search, more filters toggle, hero prompt, unified import"
```

---

### Task 4: Write LiveView tests

**Files:**
- Create: `test/scullion_web/live/recipe_live_test.exs`

- [ ] **Step 1: Create the test file**

```elixir
defmodule ScullionWeb.RecipeLiveTest do
  use ScullionWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Scullion.{Accounts, Recipes}

  setup do
    {:ok, {user, _code}} = Accounts.create_admin("Gustaf")
    {:ok, recipe} = Recipes.create(%{title: "Roast chicken", recipe_type: :meal})
    %{user: user, recipe: recipe}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  describe "page render" do
    test "shows recipe grid and single control card", %{conn: conn, user: user, recipe: recipe} do
      {:ok, _lv, html} = live(authed(conn, user), "/recipes")
      assert html =~ "Recipes"
      assert html =~ recipe.title
      assert html =~ "Search recipes"
      assert html =~ "What can we cook tonight?"
      assert html =~ "Paste a recipe URL"
    end

    test "more filters hidden by default", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(authed(conn, user), "/recipes")
      refute html =~ "quick"
      refute html =~ "Any"
    end
  end

  describe "toggle_more_filters" do
    test "expands and collapses filter panel", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "toggle_more_filters")
      assert html =~ "quick"
      assert html =~ "Any"
      html = render_click(lv, "toggle_more_filters")
      refute html =~ "quick"
    end
  end

  describe "get_ideas" do
    test "shows coming soon flash", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "get_ideas")
      assert html =~ "Coming soon"
    end
  end

  describe "import_action" do
    test "shows error when url and uploads are both empty", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_submit(lv, "import_action", %{"url" => ""})
      assert html =~ "Paste a URL or drop screenshots first"
    end
  end

  describe "filter_type" do
    test "filters recipes by type", %{conn: conn, user: user} do
      {:ok, _} = Recipes.create(%{title: "Salsa verde", recipe_type: :component})
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_click(lv, "filter_type", %{"type" => "component"})
      assert html =~ "Salsa verde"
      refute html =~ "Roast chicken"
    end
  end

  describe "search" do
    test "filters recipes by title", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      html = render_change(lv, "search", %{"query" => "roast"})
      assert html =~ "Roast chicken"
    end

    test "empty search shows all recipes", %{conn: conn, user: user, recipe: recipe} do
      {:ok, lv, _html} = live(authed(conn, user), "/recipes")
      render_change(lv, "search", %{"query" => "xyz"})
      html = render_change(lv, "search", %{"query" => ""})
      assert html =~ recipe.title
    end
  end
end
```

- [ ] **Step 2: Run the tests**

```bash
mix test test/scullion_web/live/recipe_live_test.exs 2>&1
```

Expected: all tests pass. If any fail, fix before continuing.

- [ ] **Step 3: Describe with jj**

```bash
jj describe -m "test(recipes): add recipe_live tests for redesigned page"
```

---

### Task 5: Manual smoke test

- [ ] **Step 1: Start the dev server**

```bash
mix phx.server
```

- [ ] **Step 2: Visit `/recipes` and verify**

Check each of the following:
- Single card containing search, filters, hero prompt, import row
- Search bar is visibly taller/stronger than before
- "More filters" button collapses/expands tag chips + time + sort
- "What can we cook tonight?" row with "Get ideas" button shows a flash on click
- Import row: URL input with camera icon, single Import button
- Uploading an image via camera icon shows filename below input with ✕ to cancel
- Recipe grid has tighter gap
- Existing recipe detail drawer still works (click a recipe card)
- New recipe form still works

- [ ] **Step 3: Fix any visual issues found during smoke test**

- [ ] **Step 4: Create a new jj commit for any fixes**

```bash
jj new -m "fix(recipes): smoke test corrections"
```

(Only if there were fixes — skip if step 2 had no issues.)
