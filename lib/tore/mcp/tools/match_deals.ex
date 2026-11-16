defmodule Tore.Mcp.Tools.MatchDeals do
  @moduledoc """
  Which of the household's ingredients each offer is, decided by the person's own Claude, so a
  household without the server's model still gets offer prices in its estimates.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Pantry.Match
  alias Tore.Prices.Products
  alias Tore.Recipes.Ingredient

  @impl true
  def name, do: "match_deals"

  @impl true
  def description,
    do: """
    Says which ingredient each offer's product is, so its price counts in dinner and week \
    estimates. Take products from list_deals where `ingredient` is null and `matched` is false, \
    and ingredient names from the household's recipes (get_recipe). ingredient null means none \
    of them: the product won't be asked about again for four weeks. Only clear matches: \
    "Kycklingfilé Kronfågel" is chicken fillet; a ready meal with chicken isn't.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "matches" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 100,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "product" => %{"type" => "string"},
              "ingredient" => %{"type" => ["string", "null"]}
            },
            "required" => ["product", "ingredient"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["matches"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"matches" => [_ | _] = matches}) do
    results = Enum.map(matches, &store(scope, &1))
    unknown = for {:unknown, name} <- results, do: name

    {:ok,
     %{
       matched: Enum.count(results, &(&1 == :matched)),
       none: Enum.count(results, &(&1 == :none)),
       unknown_ingredients: unknown
     }}
  end

  def call(_scope, _args), do: {:error, "match_deals needs matches: [{product, ingredient}]."}

  defp store(scope, %{"product" => product, "ingredient" => nil}) when is_binary(product) do
    :ok = Products.put(scope, product, nil)
    :none
  end

  defp store(scope, %{"product" => product, "ingredient" => name})
       when is_binary(product) and is_binary(name) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, %Ingredient{id: id}} ->
        :ok = Products.put(scope, product, id)
        :matched

      :unknown ->
        {:unknown, name}
    end
  end

  defp store(_scope, other), do: {:unknown, inspect(other)}
end
