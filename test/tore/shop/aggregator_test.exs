defmodule Tore.Shop.AggregatorTest do
  use ExUnit.Case, async: false

  import Tore.AccountsFixtures, only: [home_scope: 0]

  alias Tore.{Shop.Aggregator, Recipes}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  defp create_recipe(title, ingredients) do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: title,
        ingredients:
          Enum.map(ingredients, fn {name, qty, unit} ->
            %{name: name, quantity: qty, unit: unit}
          end)
      })

    recipe
  end

  test "returns empty list for no recipe IDs" do
    assert [] = Aggregator.aggregate_by_ids([])
  end

  test "aggregates ingredients from a single recipe" do
    recipe = create_recipe("Pasta", [{"pasta", Decimal.new("200"), "g"}, {"salt", nil, nil}])
    items = Aggregator.aggregate_by_ids([recipe.id])
    names = Enum.map(items, & &1.name)
    assert "pasta" in names
    assert "salt" in names
  end

  test "merges same name+unit across two recipes" do
    r1 = create_recipe("Dish A", [{"olive oil", Decimal.new("2"), "tbsp"}])
    r2 = create_recipe("Dish B", [{"olive oil", Decimal.new("3"), "tbsp"}])
    items = Aggregator.aggregate_by_ids([r1.id, r2.id])
    oil = Enum.find(items, fn i -> i.name == "olive oil" end)
    assert oil
    assert Decimal.eq?(oil.quantity, Decimal.new("5"))
    assert oil.unit == "tbsp"
  end

  test "leaves nil quantity when both quantities are nil" do
    r = create_recipe("Simple", [{"garlic", nil, nil}])
    items = Aggregator.aggregate_by_ids([r.id])
    garlic = Enum.find(items, fn i -> i.name == "garlic" end)
    assert garlic
    assert is_nil(garlic.quantity)
  end
end
