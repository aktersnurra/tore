defmodule Tore.Household.Preferences do
  @moduledoc """
  The rules a plan must keep: dietary rules and allergies. `PlanVerifier` refuses a plan that
  breaks them. Tastes, cuisines and dislikes live in household memory instead.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "household_preferences" do
    field :dietary_restrictions, {:array, :string}, default: []
    field :allergies, {:array, :string}, default: []
    belongs_to :household, Tore.Household.HouseholdSchema
    timestamps()
  end

  def changeset(prefs, attrs), do: cast(prefs, attrs, [:dietary_restrictions, :allergies])
end
