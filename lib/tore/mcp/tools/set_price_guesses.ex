defmodule Tore.Mcp.Tools.SetPriceGuesses do
  @moduledoc "pi's guesses at typical prices, for ingredients nothing better prices (`Tore.Prices.Estimate`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Prices.Estimate

  @impl true
  def name, do: "set_price_guesses"

  @impl true
  def description,
    do: """
    Guesses what ingredients typically cost at a supermarket where the household lives, at \
    regular (not offer) prices in the local currency, so dinner and week estimates count them. \
    For ingredients list_ingredients shows with price_guess null. unit is how it's usually \
    priced: kg by weight, l for liquids, st for single items or packs; price is for one of it. \
    Receipts and offers price an ingredient better once there are some; a guess only fills in.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "guesses" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 100,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "ingredient" => %{"type" => "string"},
              "price" => %{"type" => "number", "exclusiveMinimum" => 0},
              "unit" => %{"type" => "string", "enum" => ["kg", "l", "st"]}
            },
            "required" => ["ingredient", "price", "unit"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["guesses"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"guesses" => [_ | _] = guesses}) do
    results =
      for g <- guesses,
          do: {g["ingredient"], Estimate.put(scope, g["ingredient"], g["price"], g["unit"])}

    {:ok,
     %{
       kept: Enum.count(results, &match?({_, :ok}, &1)),
       unknown_ingredients: for({name, {:error, :unknown_ingredient}} <- results, do: name)
     }}
  end

  def call(_scope, _args),
    do: {:error, "set_price_guesses needs guesses: [{ingredient, price, unit}]."}
end
