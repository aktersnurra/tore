# Ingredient Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a line-by-line ingredient editor to the recipe edit form, backed by full replace-on-save persistence.

**Architecture:** Two-part change: (1) extend `Recipes.update/2` to accept and replace ingredients, and (2) add `ingredient_rows` socket assign + three events + form UI to `RecipeLive`. Ingredients are sent as indexed form params, parsed into a list of maps, and passed to the context layer. On update, all existing `recipe_ingredients` rows are deleted and re-inserted.

**Tech Stack:** Elixir, Ecto, Phoenix LiveView, HEEx, Tailwind CSS v4. Use `jj describe -m "..."` for commits — never git.

---

## File Map

| File | Change |
|------|--------|
| `lib/scullion/recipes.ex` | Add `maybe_update_ingredients/2`, extend `update/2` |
| `lib/scullion_web/live/recipe_live.ex` | Add `ingredient_rows` assign, 3 events, form UI section |
| `test/scullion/recipes_test.exs` | Add ingredient update tests |
| `test/scullion_web/live/recipe_live_test.exs` | Add ingredient editor UI tests |

---

### Task 1: Extend `Recipes.update/2` to replace ingredients

**Files:**
- Modify: `lib/scullion/recipes.ex`
- Test: `test/scullion/recipes_test.exs`

- [ ] **Step 1: Write failing tests**

Open `test/scullion/recipes_test.exs`. Add at the end (or in a new `describe` block):

```elixir
describe "update/2 with ingredients" do
  test "replaces all ingredients on update" do
    {:ok, recipe} = Recipes.create(%{
      title: "Soup",
      recipe_type: :meal,
      ingredients: [%{name: "Water", quantity: "1", unit: "L"}]
    })

    {:ok, updated} = Recipes.update(recipe, %{
      ingredients: [
        %{name: "Chicken", quantity: "500", unit: "g"},
        %{name: "Salt", quantity: "1", unit: "tsp"}
      ]
    })

    names = Enum.map(updated.recipe_ingredients, & &1.ingredient.name)
    assert length(updated.recipe_ingredients) == 2
    assert "Chicken" in names
    assert "Salt" in names
    refute "Water" in names
  end

  test "clears all ingredients when passed empty list" do
    {:ok, recipe} = Recipes.create(%{
      title: "Soup",
      recipe_type: :meal,
      ingredients: [%{name: "Water", quantity: "1", unit: "L"}]
    })

    {:ok, updated} = Recipes.update(recipe, %{ingredients: []})
    assert updated.recipe_ingredients == []
  end

  test "does not touch ingredients when key is absent" do
    {:ok, recipe} = Recipes.create(%{
      title: "Soup",
      recipe_type: :meal,
      ingredients: [%{name: "Water", quantity: "1", unit: "L"}]
    })

    {:ok, updated} = Recipes.update(recipe, %{title: "Updated Soup"})
    assert length(updated.recipe_ingredients) == 1
    assert hd(updated.recipe_ingredients).ingredient.name == "Water"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /home/aktersnurra/projects/scullion && mix test test/scullion/recipes_test.exs 2>&1 | tail -20
```

Expected: failures referencing the new test cases (ingredient replacement not yet implemented).

- [ ] **Step 3: Implement `maybe_update_ingredients/2` and extend `update/2`**

In `lib/scullion/recipes.ex`, change `update/2` from:

```elixir
def update(%Recipe{} = recipe, attrs) do
  {tag_names, attrs} = Map.pop(attrs, :tags, nil)

  Repo.transaction(fn ->
    with {:ok, updated} <- do_update(recipe, attrs),
         {:ok, updated} <- maybe_update_tags(updated, tag_names) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end)
  |> case do
    {:ok, recipe} -> {:ok, get!(recipe.id)}
    {:error, reason} -> {:error, reason}
  end
end
```

To:

```elixir
def update(%Recipe{} = recipe, attrs) do
  {tag_names, attrs} = Map.pop(attrs, :tags, nil)
  {ingredients, attrs} = Map.pop(attrs, :ingredients, nil)

  Repo.transaction(fn ->
    with {:ok, updated} <- do_update(recipe, attrs),
         {:ok, updated} <- maybe_update_tags(updated, tag_names),
         {:ok, updated} <- maybe_update_ingredients(updated, ingredients) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end)
  |> case do
    {:ok, recipe} -> {:ok, get!(recipe.id)}
    {:error, reason} -> {:error, reason}
  end
end
```

Then add `maybe_update_ingredients/2` after `maybe_update_tags/2`:

```elixir
defp maybe_update_ingredients(recipe, nil), do: {:ok, recipe}

defp maybe_update_ingredients(recipe, ingredients) do
  Repo.delete_all(from ri in RecipeIngredient, where: ri.recipe_id == ^recipe.id)
  insert_ingredients(recipe, ingredients)
  {:ok, recipe}
end
```

Make sure `import Ecto.Query` is already at the top of the file (it is).

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd /home/aktersnurra/projects/scullion && mix test test/scullion/recipes_test.exs 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(recipes): update/2 replaces ingredients on save"
```

---

### Task 2: Add `ingredient_rows` assign and three events to `RecipeLive`

**Files:**
- Modify: `lib/scullion_web/live/recipe_live.ex`

- [ ] **Step 1: Add `ingredient_rows: []` to `mount/3` assigns**

In `mount/3`, add to the assign block:

```elixir
ingredient_rows: [],
```

Full assign block becomes (showing only the new line in context):

```elixir
|> assign(
  ...
  form: nil,
  error: nil,
  sorts: @sorts,
  types: @types,
  time_filters: @time_filters,
  show_more_filters: false,
  ingredient_rows: []
)
```

- [ ] **Step 2: Populate `ingredient_rows` when opening the edit form**

Find `handle_event("edit_recipe", _, socket)`:

```elixir
def handle_event("edit_recipe", _, socket) do
  recipe = socket.assigns.selected
  {:noreply, assign(socket, form: recipe_to_form(recipe), error: nil)}
end
```

Change to:

```elixir
def handle_event("edit_recipe", _, socket) do
  recipe = socket.assigns.selected
  rows = Enum.map(recipe.recipe_ingredients, fn ri ->
    %{
      name: ri.ingredient.name,
      quantity: to_string(ri.quantity || ""),
      unit: ri.unit || ""
    }
  end)
  {:noreply, assign(socket, form: recipe_to_form(recipe), ingredient_rows: rows, error: nil)}
end
```

- [ ] **Step 3: Populate `ingredient_rows` when opening new recipe form**

Find `handle_event("new_recipe", _, socket)`:

```elixir
def handle_event("new_recipe", _, socket) do
  {:noreply, assign(socket, form: blank_form(), extracted_attrs: nil, selected: nil, error: nil)}
end
```

Change to:

```elixir
def handle_event("new_recipe", _, socket) do
  {:noreply, assign(socket, form: blank_form(), extracted_attrs: nil, selected: nil, error: nil, ingredient_rows: [])}
end
```

- [ ] **Step 4: Populate `ingredient_rows` after image extraction**

Find `handle_info({:extract_images, binaries}, socket)`. It currently does:

```elixir
{:noreply, assign(socket, image_extract_state: :idle, form: form, extracted_attrs: attrs, selected: nil, error: nil)}
```

Change to:

```elixir
rows = Enum.map(attrs[:ingredients] || [], fn ing ->
  %{
    name: to_string(Map.get(ing, :name) || Map.get(ing, "name") || ""),
    quantity: to_string(Map.get(ing, :quantity) || Map.get(ing, "quantity") || ""),
    unit: to_string(Map.get(ing, :unit) || Map.get(ing, "unit") || "")
  }
end)
{:noreply, assign(socket, image_extract_state: :idle, form: form, extracted_attrs: attrs, selected: nil, error: nil, ingredient_rows: rows)}
```

- [ ] **Step 5: Add three ingredient row event handlers**

Add after `handle_event("cancel_upload", ...)`:

```elixir
def handle_event("add_ingredient_row", _, socket) do
  rows = socket.assigns.ingredient_rows ++ [%{name: "", quantity: "", unit: ""}]
  {:noreply, assign(socket, ingredient_rows: rows)}
end

def handle_event("remove_ingredient_row", %{"index" => idx}, socket) do
  idx = String.to_integer(idx)
  rows = List.delete_at(socket.assigns.ingredient_rows, idx)
  {:noreply, assign(socket, ingredient_rows: rows)}
end

def handle_event("update_ingredient_row", %{"index" => idx, "field" => field, "value" => value}, socket) do
  idx = String.to_integer(idx)
  rows = List.update_at(socket.assigns.ingredient_rows, idx, fn row ->
    Map.put(row, String.to_existing_atom(field), value)
  end)
  {:noreply, assign(socket, ingredient_rows: rows)}
end
```

- [ ] **Step 6: Extend `parse_recipe_params/1` to parse ingredient rows**

Find `parse_recipe_params/1`. Change it to also extract ingredients from params:

```elixir
defp parse_recipe_params(params) do
  tag_names =
    (params["tags"] || "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  ingredients =
    (params["ingredients"] || %{})
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, ing} ->
      %{
        name: String.trim(ing["name"] || ""),
        quantity: ing["quantity"],
        unit: ing["unit"]
      }
    end)
    |> Enum.reject(fn %{name: name} -> name == "" end)

  %{
    title: params["title"],
    recipe_type: String.to_existing_atom(params["recipe_type"] || "meal"),
    prep_time_minutes: parse_int(params["prep_time_minutes"]),
    cook_time_minutes: parse_int(params["cook_time_minutes"]),
    base_servings: parse_int(params["base_servings"]),
    source_url: params["source_url"],
    instructions: params["instructions"],
    tags: tag_names,
    ingredients: ingredients
  }
end
```

- [ ] **Step 7: Verify compilation**

```bash
cd /home/aktersnurra/projects/scullion && mix compile --warnings-as-errors 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(recipes): ingredient_rows assign and events"
```

---

### Task 3: Add ingredient editor UI to `render_form`

**Files:**
- Modify: `lib/scullion_web/live/recipe_live.ex` — `render_form/1`

- [ ] **Step 1: Add ingredient rows section to the form**

In `render_form/1`, find the Tags field:

```heex
<.field name="recipe[tags]" label="Tags" value={@form[:tags] || ""} placeholder="quick, batch, vegetarian" />
```

Add the ingredient section immediately after it:

```heex
<div>
  <span class="block mb-2 text-[color:var(--muted)]" style="font-size: var(--t-meta);">Ingredients</span>
  <div class="space-y-2">
    <div :for={{row, idx} <- Enum.with_index(@ingredient_rows)} class="flex items-center gap-2">
      <input
        type="text"
        name={"ingredients[#{idx}][name]"}
        value={row.name}
        placeholder="Ingredient"
        phx-change="update_ingredient_row"
        phx-value-index={idx}
        phx-value-field="name"
        class="flex-1 h-10 px-3 bg-[var(--surface)] rounded-[var(--r-md)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
        style="font-size: var(--t-body);"
      />
      <input
        type="text"
        name={"ingredients[#{idx}][quantity]"}
        value={row.quantity}
        placeholder="Qty"
        phx-change="update_ingredient_row"
        phx-value-index={idx}
        phx-value-field="quantity"
        class="w-20 h-10 px-3 bg-[var(--surface)] rounded-[var(--r-md)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
        style="font-size: var(--t-body);"
      />
      <input
        type="text"
        name={"ingredients[#{idx}][unit]"}
        value={row.unit}
        placeholder="Unit"
        phx-change="update_ingredient_row"
        phx-value-index={idx}
        phx-value-field="unit"
        class="w-24 h-10 px-3 bg-[var(--surface)] rounded-[var(--r-md)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
        style="font-size: var(--t-body);"
      />
      <button
        type="button"
        phx-click="remove_ingredient_row"
        phx-value-index={idx}
        class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--subtle)] hover:text-[color:var(--danger)] hover:bg-[color:var(--hairline)]"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
  </div>
  <button
    type="button"
    phx-click="add_ingredient_row"
    class="mt-2 inline-flex items-center gap-1 text-[color:var(--accent)] hover:underline"
    style="font-size: var(--t-meta); font-weight: 500;"
  >
    <.icon name="hero-plus" class="size-4" /> Add ingredient
  </button>
</div>
```

- [ ] **Step 2: Verify compilation**

```bash
cd /home/aktersnurra/projects/scullion && mix compile --warnings-as-errors 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(recipes): ingredient editor UI in edit form"
```

---

### Task 4: LiveView tests for ingredient editor

**Files:**
- Modify: `test/scullion_web/live/recipe_live_test.exs`

- [ ] **Step 1: Add ingredient editor tests**

Add a new describe block at the end of the file:

```elixir
describe "ingredient editor" do
  test "shows ingredient rows when editing a recipe", %{conn: conn, user: user} do
    {:ok, recipe} = Recipes.create(%{
      title: "Pasta",
      recipe_type: :meal,
      ingredients: [%{name: "Spaghetti", quantity: "200", unit: "g"}]
    })
    {:ok, lv, _html} = live(authed(conn, user), "/recipes")
    render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
    html = render_click(lv, "edit_recipe")
    assert html =~ "Spaghetti"
    assert html =~ "200"
    assert html =~ "g"
  end

  test "add_ingredient_row appends a blank row", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(authed(conn, user), "/recipes")
    render_click(lv, "new_recipe")
    html = render_click(lv, "add_ingredient_row")
    assert html =~ ~s(placeholder="Ingredient")
  end

  test "remove_ingredient_row removes a row", %{conn: conn, user: user} do
    {:ok, recipe} = Recipes.create(%{
      title: "Pasta",
      recipe_type: :meal,
      ingredients: [%{name: "Spaghetti", quantity: "200", unit: "g"}]
    })
    {:ok, lv, _html} = live(authed(conn, user), "/recipes")
    render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
    render_click(lv, "edit_recipe")
    html = render_click(lv, "remove_ingredient_row", %{"index" => "0"})
    refute html =~ "Spaghetti"
  end

  test "saving recipe persists ingredient rows", %{conn: conn, user: user} do
    {:ok, recipe} = Recipes.create(%{title: "Pasta", recipe_type: :meal})
    {:ok, lv, _html} = live(authed(conn, user), "/recipes")
    render_click(lv, "select_recipe", %{"id" => to_string(recipe.id)})
    render_click(lv, "edit_recipe")
    render_submit(lv, "save_recipe", %{
      "recipe" => %{
        "title" => "Pasta",
        "recipe_type" => "meal",
        "prep_time_minutes" => "",
        "cook_time_minutes" => "",
        "base_servings" => "",
        "tags" => "",
        "source_url" => "",
        "instructions" => ""
      },
      "ingredients" => %{
        "0" => %{"name" => "Spaghetti", "quantity" => "200", "unit" => "g"}
      }
    })

    updated = Recipes.get!(recipe.id)
    assert length(updated.recipe_ingredients) == 1
    assert hd(updated.recipe_ingredients).ingredient.name == "Spaghetti"
  end
end
```

- [ ] **Step 2: Run the tests**

```bash
cd /home/aktersnurra/projects/scullion && mix test test/scullion_web/live/recipe_live_test.exs 2>&1
```

Expected: all tests pass. If `select_recipe` requires auth or setup adjustments, check the existing `setup` block and ensure recipes are created with the right attrs.

- [ ] **Step 3: Commit**

```bash
jj describe -m "test(recipes): ingredient editor LiveView tests"
```

---

### Task 5: Run full test suite

- [ ] **Step 1: Run all tests**

```bash
cd /home/aktersnurra/projects/scullion && mix test 2>&1 | tail -20
```

Expected: no failures. Fix any regressions before proceeding.

- [ ] **Step 2: Commit if any fixes were needed**

```bash
jj describe -m "fix(recipes): test suite regressions after ingredient editor"
```

(Skip if no fixes were needed.)
