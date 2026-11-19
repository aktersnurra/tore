defmodule Tore.Mcp.Tools.GetRecipe do
  @moduledoc "One recipe in full: ingredients, steps, servings and times."
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes
  alias Tore.Recipes.Recipe

  @impl true
  def name, do: "get_recipe"

  @impl true
  def description, do: "One recipe in full: its ingredients, steps, servings and times."

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
      servings: recipe.base_servings,
      prep_minutes: recipe.prep_time_minutes,
      cook_minutes: recipe.cook_time_minutes,
      source_url: recipe.source_url,
      ingredients:
        for ri <- recipe.recipe_ingredients do
          %{name: ri.ingredient.name, quantity: ri.quantity, unit: ri.unit, notes: ri.notes}
        end,
      steps: Recipe.decode_steps(recipe),
      instructions: recipe.instructions,
      parts: for(part <- recipe.parts, do: %{id: part.id, title: part.title})
    }
  end
end
