defmodule Tore.Mcp.Tools.LearnIngredients do
  @moduledoc "What new ingredient names mean (`Tore.Pantry.Learn.learn/2`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Pantry.Learn
  alias Tore.Recipes.Ingredient

  @impl true
  def name, do: "learn_ingredients"

  @impl true
  def description,
    do: """
    Says what each new ingredient name means. same_as names an ingredient the household already \
    has (list_ingredients) when the new name is the same thing ("Mellanmjölk" is "Mjölk"): the \
    two become one and the new name finds it from then on. Otherwise same_as is null and the \
    name is its own ingredient. section is where it's found in a shop, and shelf_life_days how \
    long it keeps once bought, when you know.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 100,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "same_as" => %{"type" => ["string", "null"]},
              "section" => %{"type" => "string", "enum" => Ingredient.sections()},
              "shelf_life_days" => %{"type" => ["integer", "null"], "minimum" => 1}
            },
            "required" => ["name", "same_as", "section"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["items"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"items" => [_ | _] = items}) do
    results =
      for item <- items do
        {item["name"],
         Learn.learn(scope, %{
           name: item["name"],
           same_as: item["same_as"],
           section: item["section"],
           shelf_life_days: Tore.Pantry.Expiry.parse_shelf_life(item["shelf_life_days"])
         })}
      end

    {:ok,
     %{
       merged: Enum.count(results, &match?({_, :merged}, &1)),
       learned: Enum.count(results, &match?({_, :filled}, &1)),
       unknown_names: for({name, {:error, :unknown_name}} <- results, do: name),
       unknown_same_as: for({name, {:error, :unknown_same_as}} <- results, do: name)
     }}
  end

  def call(_scope, _args),
    do: {:error, "learn_ingredients needs items: [{name, same_as, section}]."}
end
