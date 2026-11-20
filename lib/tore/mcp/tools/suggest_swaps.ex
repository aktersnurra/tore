defmodule Tore.Mcp.Tools.SuggestSwaps do
  @moduledoc """
  pi's swaps for what isn't at home before someone cooks (`Tore.Recipes.Swaps`). Nothing is
  saved: the sheet before cooking reads them from the tool's result, and cook mode uses them.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes
  alias Tore.Recipes.Swaps

  @impl true
  def name, do: "suggest_swaps"

  @impl true
  def description,
    do: """
    Before someone cooks a recipe: what to use instead of each ingredient that isn't at home. \
    Pick from what they said they have first, then from the pantry (get_context), never \
    anything else; when nothing fits, or the dish is fine without it, `use` is null and the \
    note says why or to leave it out. `note` is one short sentence on the amount or how to use \
    it, null when it's the same amount used the same way. `for` is the missing ingredient \
    exactly as you were given it, one swap per missing ingredient, in the household's language. \
    Nothing is saved; the sheet before cooking shows them and cook mode cooks with them.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "recipe_id" => %{"type" => "integer"},
        "swaps" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "for" => %{"type" => "string"},
              "use" => %{"type" => ["string", "null"]},
              "note" => %{"type" => ["string", "null"]}
            },
            "required" => ["for"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["recipe_id", "swaps"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"recipe_id" => id, "swaps" => swaps})
      when is_integer(id) and is_list(swaps) do
    case Recipes.get(scope, id) do
      nil ->
        {:error, "No recipe #{id} in this household. Find it with search_recipes."}

      recipe ->
        {:ok,
         %{done: "Swaps for #{recipe.title}. Nothing is saved.", swaps: Swaps.read(scope, swaps)}}
    end
  end

  def call(_scope, _args), do: {:error, "suggest_swaps needs recipe_id and a list of swaps."}
end
