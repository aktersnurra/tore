defmodule Tore.Pantry.Match do
  @moduledoc """
  Which ingredient a name or a barcode means, without the model: the ingredient with the same key,
  then a name or barcode learned before, else `:unknown`. Nothing matches part of a name, because
  a false match drops an item off the shopping list, and a missed one only costs a learning call.
  """

  import Ecto.Query

  alias Tore.{Repo, Scope}
  alias Tore.Pantry.IngredientAlias
  alias Tore.Recipes.Ingredient

  @type ref :: {:name, String.t()} | {:barcode, String.t()}

  @spec ingredient(Scope.t(), ref()) :: {:ok, Ingredient.t()} | :unknown
  def ingredient(%Scope{} = scope, {:name, name}) when is_binary(name) do
    case Ingredient.to_key(name) do
      "" ->
        :unknown

      key ->
        case Repo.get_by(Ingredient, [key: key], Scope.repo_opts(scope)) do
          nil -> by_alias(scope, key)
          ingredient -> {:ok, ingredient}
        end
    end
  end

  def ingredient(%Scope{} = scope, {:barcode, code}) when is_binary(code),
    do: by_alias(scope, barcode_alias(code))

  @doc "Remembers that `ref` means the ingredient. The first answer for a name or barcode stays."
  @spec learn_alias(Scope.t(), ref(), integer()) :: :ok
  def learn_alias(%Scope{} = scope, ref, ingredient_id) do
    Repo.insert!(
      %IngredientAlias{
        household_id: scope.household_id,
        alias: alias_for(ref),
        ingredient_id: ingredient_id
      },
      on_conflict: :nothing,
      conflict_target: [:household_id, :alias]
    )

    :ok
  end

  defp by_alias(scope, alias) do
    query =
      from(a in IngredientAlias,
        join: i in assoc(a, :ingredient),
        where: a.alias == ^alias,
        select: i
      )

    case Repo.one(query, Scope.repo_opts(scope)) do
      nil -> :unknown
      ingredient -> {:ok, ingredient}
    end
  end

  defp alias_for({:name, name}), do: Ingredient.to_key(name)
  defp alias_for({:barcode, code}), do: barcode_alias(code)

  defp barcode_alias(code), do: "ean:" <> code
end
