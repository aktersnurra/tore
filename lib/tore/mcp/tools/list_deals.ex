defmodule Tore.Mcp.Tools.ListDeals do
  @moduledoc "This week's offers from the stores the household follows."
  @behaviour Tore.Mcp.Tool

  import Ecto.Query

  alias Tore.{Deals, Repo, Scope}
  alias Tore.Prices.Products
  alias Tore.Recipes.Ingredient

  @impl true
  def name, do: "list_deals"

  @impl true
  def description,
    do: """
    Current offers at the stores the household follows: product, brand, size, price and the \
    offer's condition (such as "2 för 40 kr"). `price` is for `quantity` items, per `price_unit` \
    (st, kg or l); `regular_price` is the usual price for one. `ingredient` is the household's \
    ingredient the product was matched to; with `matched` false nobody has decided yet, and \
    match_deals can. Useful when planning dinners or the list.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    deals = Deals.list_current(scope)
    matches = Products.lookup(scope, Enum.map(deals, & &1.product_name))

    names =
      Map.new(
        Repo.all(
          from(i in Ingredient, where: i.id in ^Enum.reject(Map.values(matches), &is_nil/1)),
          Scope.repo_opts(scope)
        ),
        &{&1.id, &1.name}
      )

    {:ok,
     %{
       deals:
         for d <- deals do
           key = Ingredient.to_key(d.product_name)

           %{
             ingredient: names[matches[key]],
             matched: Map.has_key?(matches, key),
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
