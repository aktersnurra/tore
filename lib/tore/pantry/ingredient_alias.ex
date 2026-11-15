defmodule Tore.Pantry.IngredientAlias do
  @moduledoc """
  Another name, or a barcode, that Tore has learned means an ingredient. `alias` is a name's key
  (`Tore.Recipes.Ingredient.to_key/1`) or `ean:<digits>`, so a name and a barcode never collide.
  """

  use Ecto.Schema

  schema "ingredient_aliases" do
    field :alias, :string
    field :household_id, :integer
    belongs_to :ingredient, Tore.Recipes.Ingredient
    timestamps()
  end
end
