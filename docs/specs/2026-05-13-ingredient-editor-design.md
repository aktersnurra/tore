# Ingredient Editor Design

**Date:** 2026-05-13  
**Scope:** `lib/scullion_web/live/recipe_live.ex`, `lib/scullion/recipes.ex`

---

## Goal

Allow users to view and edit a recipe's ingredients inline in the edit form, with line-by-line rows (name, quantity, unit) that can be added and removed.

---

## Data Flow

### Backend: `Recipes.update/2`

Add ingredient replacement to the update path. If `:ingredients` is present in attrs:
1. Delete all existing `recipe_ingredients` rows for that recipe
2. Re-insert from the new list using the existing `insert_ingredients/2` logic

This is a full replace — no diffing. Simple and correct.

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

defp maybe_update_ingredients(recipe, nil), do: {:ok, recipe}

defp maybe_update_ingredients(recipe, ingredients) do
  Repo.delete_all(from ri in RecipeIngredient, where: ri.recipe_id == ^recipe.id)
  insert_ingredients(recipe, ingredients)
  {:ok, recipe}
end
```

### Frontend: socket assign `ingredient_rows`

A list of maps held in the socket during editing:

```elixir
ingredient_rows: [%{name: "Chicken breast", quantity: "500", unit: "g"}, ...]
```

**Population sources (in priority order):**
1. When editing an existing recipe: populated from `recipe.recipe_ingredients`
2. When coming from image extraction: populated from `extracted_attrs[:ingredients]`
3. New recipe with no extraction: empty list `[]`

**Events:**
- `"add_ingredient_row"` — appends `%{name: "", quantity: "", unit: ""}` to the list
- `"remove_ingredient_row"` — removes row at given index
- `"update_ingredient_row"` — updates a field at given index (phx-change on each input)

**On save:** ingredient rows serialized into params as indexed keys:
`ingredients[0][name]`, `ingredients[0][quantity]`, `ingredients[0][unit]`

Parsed in `parse_recipe_params/1` into a list of maps, passed as `:ingredients` to `Recipes.create/1` or `Recipes.update/2`.

---

## UI: Ingredient section in the edit form

Placed below the Tags field, above Source URL.

```
Ingredients

[ Chicken breast    ] [ 500 ] [ g      ] [✕]
[ Garlic            ] [ 3   ] [ cloves  ] [✕]
[ Olive oil         ] [ 2   ] [ tbsp    ] [✕]
                               [ + Add ingredient ]
```

- Name input: `flex-1`, placeholder "Ingredient"
- Quantity input: `w-20`, placeholder "Qty", type text (allows fractions like "½")
- Unit input: `w-24`, placeholder "Unit"
- Remove button (✕): `phx-click="remove_ingredient_row"` with `phx-value-index`
- Add button: `phx-click="add_ingredient_row"`, aligned right below the rows
- Each input uses `phx-change="update_ingredient_row"` with `phx-value-index` and `phx-value-field`

---

## Scope

**In scope:**
- Ingredient rows in the edit form for both new and existing recipes
- Pre-populate from `recipe.recipe_ingredients` when editing
- Pre-populate from `extracted_attrs[:ingredients]` when from image extraction
- Persist on save via `Recipes.update/2` and `Recipes.create/1`

**Out of scope:**
- Notes field per ingredient
- Drag-to-reorder
- Ingredient name autocomplete
