defmodule Tore.Recipes.Ingredient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ingredients" do
    field :name, :string
    field :key, :string
    field :category, :string
    field :default_unit, :string
    field :shelf_life_days, :integer
    has_many :recipe_ingredients, Tore.Recipes.RecipeIngredient
    timestamps()
  end

  def changeset(ingredient, attrs) do
    ingredient
    |> cast(attrs, [:name, :key, :category, :default_unit, :shelf_life_days])
    |> validate_required([:name])
    |> derive_key()
    |> unique_constraint(:name)
    |> unique_constraint(:key)
  end

  defp derive_key(changeset) do
    case get_change(changeset, :key) do
      nil ->
        case get_change(changeset, :name) || get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :key, to_key(name))
        end

      _ ->
        update_change(changeset, :key, &to_key/1)
    end
  end

  def to_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[åÅ]/u, "a")
    |> String.replace(~r/[äÄ]/u, "a")
    |> String.replace(~r/[öÖ]/u, "o")
    |> String.replace(~r/[\s\-\/]+/u, "_")
    |> String.replace(~r/[^a-z0-9_]/u, "")
    |> String.trim("_")
  end
end
