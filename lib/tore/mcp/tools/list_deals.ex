defmodule Tore.Mcp.Tools.ListDeals do
  @moduledoc "This week's offers from the stores the household follows."
  @behaviour Tore.Mcp.Tool

  alias Tore.Deals

  @impl true
  def name, do: "list_deals"

  @impl true
  def description,
    do: """
    Current offers at the stores the household follows: product, brand, size, price and the \
    offer's condition (such as "2 för 40 kr"). `price` is for `quantity` items, per `price_unit` \
    (st, kg or l); `regular_price` is the usual price for one. Useful when planning dinners or \
    the list.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    {:ok,
     %{
       deals:
         for d <- Deals.list_current(scope) do
           %{
             store: d.store,
             product: d.product_name,
             brand: d.brand,
             size: d.size,
             price: d.price,
             quantity: d.quantity,
             price_unit: d.price_unit,
             condition: d.offer_condition,
             regular_price: d.regular_price,
             valid_until: d.valid_until
           }
         end
     }}
  end
end
