defmodule Tore.Deals.Deal do
  @moduledoc """
  One store's offer on one product for one week. `price` is what the offer costs for `quantity`
  items, per `price_unit` ("st", "kg" or "l"); `regular_price` is the usual price per item.
  Ended offers are kept as the price history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "deals" do
    field :chain, :string
    field :store, :string
    field :store_location, :string
    field :product_name, :string
    field :brand, :string
    field :size, :string
    field :price, :decimal
    field :quantity, :integer, default: 1
    field :price_unit, :string
    field :regular_price, :decimal
    field :comparison_price, :decimal
    field :comparison_unit, :string
    field :offer_condition, :string
    field :valid_from, :date
    field :valid_until, :date
    # The day the store stopped listing it before it ended; kept, as the price history.
    field :withdrawn_on, :date
    field :source, Ecto.Enum, values: [:scraped, :vision, :manual]
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(deal, attrs) do
    deal
    |> cast(attrs, [
      :chain,
      :store,
      :store_location,
      :product_name,
      :brand,
      :size,
      :price,
      :quantity,
      :price_unit,
      :regular_price,
      :comparison_price,
      :comparison_unit,
      :offer_condition,
      :valid_from,
      :valid_until,
      :source
    ])
    |> validate_required([:chain, :store, :product_name, :valid_until, :source])
    |> validate_number(:quantity, greater_than: 0)
  end

  @doc "The offer's price for one item (or one kg or litre), or nil when the offer has no price."
  @spec unit_price(t()) :: Decimal.t() | nil
  def unit_price(%__MODULE__{price: nil}), do: nil

  def unit_price(%__MODULE__{price: price, quantity: quantity}),
    do: price |> Decimal.div(quantity) |> Decimal.round(2)
end
