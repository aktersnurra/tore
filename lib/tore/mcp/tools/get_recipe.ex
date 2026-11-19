defmodule Tore.Mcp.Tools.GetRecipe do
  @moduledoc "One recipe in full: ingredients, steps, servings and times."
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes

  @impl true
  def name, do: "get_recipe"

  @impl true
  def description,
    do: """
    One recipe in full, in the shape save_recipe and update_recipe take, so you can change it \
    and send it back: ingredients, steps, servings, times, collection and tags. `has_picture` \
    says whether it has a picture. `instructions` is its running text, which is all a \
    hand-written recipe has until its steps are written.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"recipe_id" => %{"type" => "integer"}},
      "required" => ["recipe_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"recipe_id" => id}) when is_integer(id) do
    case Recipes.get(scope, id) do
      nil -> {:error, "No recipe #{id} in this household. Find one with search_recipes."}
      recipe -> {:ok, full(Recipes.get!(scope, recipe.id))}
    end
  end

  def call(_scope, _args), do: {:error, "get_recipe needs recipe_id, a number."}

  defp full(recipe) do
    %{
      recipe_id: recipe.id,
      title: recipe.title,
      description: recipe.description,
      recipe_type: recipe.recipe_type,
      base_servings: recipe.base_servings,
      prep_time_minutes: recipe.prep_time_minutes,
      cook_time_minutes: recipe.cook_time_minutes,
      source_url: recipe.source_url,
      has_picture: recipe.image_path != nil,
      tags: Enum.map(recipe.tags, & &1.name),
      ingredients:
        for ri <- recipe.recipe_ingredients do
          %{item: ri.ingredient.name, quantity: ri.quantity, unit: ri.unit}
        end,
      steps: Recipes.cook_steps(recipe),
      instructions: recipe.instructions,
      parts: for(part <- recipe.parts, do: %{id: part.id, title: part.title})
    }
  end
end
