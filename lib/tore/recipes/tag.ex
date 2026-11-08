defmodule Tore.Recipes.Tag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tags" do
    field :name, :string
    field :household_id, :integer
    many_to_many :recipes, Tore.Recipes.Recipe, join_through: Tore.Recipes.RecipeTag
    timestamps()
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint([:household_id, :name])
  end
end
