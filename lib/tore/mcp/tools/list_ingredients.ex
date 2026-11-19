defmodule Tore.Mcp.Tools.ListIngredients do
  @moduledoc "The household's ingredients by name, with their shop section and price guess."
  @behaviour Tore.Mcp.Tool

  alias Tore.{Repo, Scope}
  alias Tore.Recipes.Ingredient

  @impl true
  def name, do: "list_ingredients"

  @impl true
  def description,
    do: """
    Every ingredient the household has, by name, with its shop section (null when Tore hasn't \
    learned it yet) and its price_guess per kg, l or st (null when there is none: \
    set_price_guesses). The names learn_ingredients, match_products and set_price_guesses take.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    ingredients =
      Ingredient
      |> Repo.all(Scope.repo_opts(scope))
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(&%{name: &1.name, section: &1.category, price_guess: guess(&1)})

    {:ok, %{ingredients: ingredients}}
  end

  defp guess(%Ingredient{estimated_price: nil}), do: nil

  defp guess(%Ingredient{estimated_price: price, estimated_unit: unit}),
    do: %{price: Decimal.to_float(price), unit: unit}
end
