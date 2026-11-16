defmodule Tore.Mcp.Tools.SearchRecipes do
  @moduledoc "The household's recipes by a word in the title or an ingredient, or all of them."
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes

  @impl true
  def name, do: "search_recipes"

  @impl true
  def description,
    do: """
    The household's recipes. With `query`, those whose title or an ingredient contains it; \
    without, all of them. `max_minutes` keeps those that take at most that long. Use a result's \
    `recipe_id` to plan it or read it.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "max_minutes" => %{"type" => "integer", "minimum" => 1}
      },
      "additionalProperties" => false
    }

  @impl true
  def call(scope, args) do
    recipes =
      case args["query"] do
        query when is_binary(query) and query != "" -> Recipes.search(scope, query)
        _ -> Recipes.list(scope)
      end

    {:ok,
     %{
       recipes:
         recipes
         |> Enum.map(&summary/1)
         |> Enum.filter(&within?(&1, args["max_minutes"]))
         |> Enum.sort_by(& &1.title)
     }}
  end

  defp summary(recipe) do
    %{
      recipe_id: recipe.id,
      title: recipe.title,
      servings: recipe.base_servings,
      total_minutes: minutes(recipe),
      tags: Enum.map(recipe.tags, & &1.name),
      last_cooked: recipe.last_used_at
    }
  end

  defp minutes(%{prep_time_minutes: nil, cook_time_minutes: nil}), do: nil
  defp minutes(recipe), do: (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)

  defp within?(_recipe, max) when not is_integer(max), do: true
  defp within?(%{total_minutes: nil}, _max), do: true
  defp within?(%{total_minutes: total}, max), do: total <= max
end
