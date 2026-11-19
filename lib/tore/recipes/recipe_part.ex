defmodule Tore.Recipes.RecipePart do
  @moduledoc """
  One part of a meal put together from other recipes (`Tore.Recipes.put_together/3`): the part
  and where it comes in the meal. Reached through the meal, as its ingredients are.
  """

  use Ecto.Schema

  schema "recipe_parts" do
    belongs_to :recipe, Tore.Recipes.Recipe
    belongs_to :part, Tore.Recipes.Recipe
    field :position, :integer
    timestamps()
  end
end
