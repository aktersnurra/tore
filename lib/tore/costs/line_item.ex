defmodule Tore.Costs.LineItem do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tore.Recipes.Ingredient

  schema "line_items" do
    field :product_name, :string
    field :quantity, :decimal
    field :unit, :string
    field :unit_price, :decimal
    field :total_price, :decimal
    # The shop section the line belongs to (`Ingredient.sections/0`), as on Shop.
    field :category, :string
    belongs_to :receipt, Tore.Costs.Receipt
    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :product_name,
      :quantity,
      :unit,
      :unit_price,
      :total_price,
      :category,
      :receipt_id
    ])
    |> validate_required([:product_name, :receipt_id])
    |> validate_inclusion(:category, Ingredient.sections())
  end
end
