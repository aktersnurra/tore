defmodule Tore.Mcp.Tools.ListIngredients do
  @moduledoc "The household's ingredients by name, with their shop section once learned."
  @behaviour Tore.Mcp.Tool

  alias Tore.{Repo, Scope}
  alias Tore.Recipes.Ingredient

  @impl true
  def name, do: "list_ingredients"

  @impl true
  def description,
    do: """
    Every ingredient the household has, by name, with its shop section (null when Tore hasn't \
    learned it yet). The names learn_ingredients and match_products take.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    ingredients =
      Ingredient
      |> Repo.all(Scope.repo_opts(scope))
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(&%{name: &1.name, section: &1.category})

    {:ok, %{ingredients: ingredients}}
  end
end
