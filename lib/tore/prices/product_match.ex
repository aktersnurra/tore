defmodule Tore.Prices.ProductMatch do
  @moduledoc """
  Which ingredient a product on a deal or a receipt line is, for prices only. `product_key` is the
  name's key (`Tore.Recipes.Ingredient.to_key/1`). No ingredient means none of the household's fits.
  """

  use Ecto.Schema

  schema "product_matches" do
    field :household_id, :integer
    field :product_key, :string
    belongs_to :ingredient, Tore.Recipes.Ingredient
    timestamps()
  end
end
