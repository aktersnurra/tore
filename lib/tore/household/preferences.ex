defmodule Tore.Household.Preferences do
  use Ecto.Schema
  import Ecto.Changeset

  schema "household_preferences" do
    field :dietary_restrictions, {:array, :string}, default: []
    field :allergies, {:array, :string}, default: []
    field :dislikes, {:array, :string}, default: []
    field :cooking_style, {:array, :string}, default: []
    field :cuisine_preferences, :map, default: %{}
    field :default_portions, :integer, default: 4
    field :default_leftover_portions, :integer, default: 2
    field :include_lunches, :boolean, default: false
    field :planning_days, :integer, default: 5
    belongs_to :household, Tore.Household.HouseholdSchema
    timestamps()
  end

  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, [
      :dietary_restrictions,
      :allergies,
      :dislikes,
      :cooking_style,
      :cuisine_preferences,
      :default_portions,
      :default_leftover_portions,
      :include_lunches,
      :planning_days
    ])
    |> validate_number(:default_portions, greater_than: 0)
    |> validate_number(:default_leftover_portions, greater_than_or_equal_to: 0)
    |> validate_inclusion(:planning_days, [5, 7])
  end
end
