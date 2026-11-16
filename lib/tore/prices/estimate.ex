defmodule Tore.Prices.Estimate do
  @moduledoc """
  The model's guess at what an ingredient typically costs, for ingredients nothing better prices.
  One call per batch of ingredients without a guess, made when a planner run starts (it uses the
  model anyway), and kept on the ingredient. An estimate never counts as priced.
  """

  import Ecto.Query

  require Logger

  alias Tore.{Household, Repo, Scope}
  alias Tore.Prices.Units
  alias Tore.Recipes.{Ingredient, RecipeIngredient}

  @batch 80

  @doc "Guesses prices for the household's recipe ingredients that have none. Needs the model."
  @spec missing(Scope.t()) :: :ok
  def missing(%Scope{} = scope) do
    with :ok <- Tore.LLM.check(scope),
         [_ | _] = ingredients <- without_estimate(scope),
         {system, user} = Tore.LLM.Prompts.estimate_prices(ingredients, Household.locale(scope)),
         {:ok, %{"items" => items}, _usage} <-
           Tore.LLM.text(scope, system, user,
             response_format: Tore.LLM.Prompts.estimate_prices_schema(),
             feature: :estimate_prices
           ) do
      by_name = Map.new(ingredients, &{&1.name, &1})

      for %{"name" => name, "price" => price, "unit" => unit} <- items,
          ingredient = by_name[name],
          ingredient != nil,
          is_number(price) and price > 0,
          Units.base(unit) == unit do
        Repo.update_all(
          from(i in Ingredient, where: i.id == ^ingredient.id),
          [
            set: [
              estimated_price: Decimal.from_float(price / 1) |> Decimal.round(2),
              estimated_unit: unit
            ]
          ],
          Scope.repo_opts(scope)
        )
      end

      :ok
    else
      {:error, reason} when reason not in [:ai_unavailable, :budget_exceeded] ->
        Logger.warning("Couldn't estimate prices: #{inspect(reason)}")

      _ ->
        :ok
    end

    :ok
  end

  defp without_estimate(scope) do
    from(i in Ingredient,
      join: ri in RecipeIngredient,
      on: ri.ingredient_id == i.id,
      where: is_nil(i.estimated_price),
      distinct: true,
      order_by: i.id,
      limit: @batch
    )
    |> Repo.all(Scope.repo_opts(scope))
  end
end
