defmodule Tore.Recipes.Ingredient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ingredients" do
    field :name, :string
    field :key, :string
    field :category, :string
    field :default_unit, :string
    field :shelf_life_days, :integer
    field :estimated_price, :decimal
    field :estimated_unit, :string
    # A scanned pack's photo (`Tore.Pantry.Scan`), as a storage key.
    field :image_path, :string
    # How long a pack lasts the household, as Jev judged it (`Tore.Pantry.Lasts`).
    field :lasts, :string
    field :lasts_confidence, :float
    field :household_id, :integer
    has_many :recipe_ingredients, Tore.Recipes.RecipeIngredient
    timestamps()
  end

  # The shop's sections. An ingredient's category is the section it's found in.
  @sections ~w(produce meat fish dairy deli frozen bread dry_goods canned beverages herbs_spices condiments household other)

  @doc "The sections of a shop, in no order. An ingredient's `category` is one of them."
  @spec sections() :: [String.t()]
  def sections, do: @sections

  def changeset(ingredient, attrs) do
    ingredient
    |> cast(attrs, [:name, :key, :category, :default_unit, :shelf_life_days])
    |> validate_required([:name])
    |> validate_inclusion(:category, @sections)
    |> derive_key()
    |> unique_constraint([:household_id, :name])
    |> unique_constraint([:household_id, :key])
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
