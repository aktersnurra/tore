defmodule Tore.Shop.Aggregator do
  alias Tore.Recipes

  @spec aggregate_by_ids(Tore.Scope.t(), [integer()]) :: [map()]
  def aggregate_by_ids(_scope, []), do: []

  def aggregate_by_ids(scope, recipe_ids) do
    recipe_ids
    |> Enum.flat_map(fn id ->
      recipe = Recipes.get!(scope, id)

      Enum.map(recipe.recipe_ingredients, fn ri ->
        %{name: ri.ingredient.name, quantity: ri.quantity, unit: ri.unit}
      end)
    end)
    |> merge_items()
  end

  defp merge_items(items) do
    items
    |> Enum.group_by(fn i -> {i.name, i.unit} end)
    |> Enum.map(fn {{name, unit}, group} ->
      total =
        Enum.reduce(group, Decimal.new(0), fn i, acc ->
          Decimal.add(acc, i.quantity || Decimal.new(0))
        end)

      %{
        id: Ecto.UUID.generate(),
        name: name,
        quantity: if(Decimal.eq?(total, Decimal.new(0)), do: nil, else: total),
        unit: unit,
        checked: false
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end
