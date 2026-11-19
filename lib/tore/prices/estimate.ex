defmodule Tore.Prices.Estimate do
  @moduledoc """
  pi's guess at what an ingredient typically costs, for ingredients nothing better prices
  (`set_price_guesses`, asked for in the `plan_week` job before planning), kept on the
  ingredient. A guess never counts as priced.
  """

  import Ecto.Query

  alias Tore.{Repo, Scope}
  alias Tore.Pantry.Match
  alias Tore.Prices.Units
  alias Tore.Recipes.Ingredient

  @doc """
  Keeps `price` per one `unit` (kg, l or st) as the guess for the ingredient called `name`.
  """
  @spec put(Scope.t(), String.t(), number(), String.t()) ::
          :ok | {:error, :unknown_ingredient | :bad_price}
  def put(%Scope{} = scope, name, price, unit) do
    with {:ok, %Ingredient{id: id}} <- found(scope, name),
         true <- is_number(price) and price > 0 and Units.base(unit) == unit do
      Repo.update_all(
        from(i in Ingredient, where: i.id == ^id),
        [
          set: [
            estimated_price: Decimal.round(Decimal.from_float(price / 1), 2),
            estimated_unit: unit
          ]
        ],
        Scope.repo_opts(scope)
      )

      :ok
    else
      false -> {:error, :bad_price}
      error -> error
    end
  end

  defp found(scope, name) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, ingredient} -> {:ok, ingredient}
      :unknown -> {:error, :unknown_ingredient}
    end
  end
end
