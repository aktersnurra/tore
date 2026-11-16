defmodule Tore.Household.Preferences do
  @moduledoc """
  The rules a plan must keep: dietary rules and allergies. `PlanVerifier` refuses a plan that
  breaks them. Tastes, cuisines and dislikes live in household memory instead. Also the default
  weekly budget (`Tore.Budget`), which a plan is aimed at but never refused for.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "household_preferences" do
    field :dietary_restrictions, {:array, :string}, default: []
    field :allergies, {:array, :string}, default: []
    field :weekly_budget, :decimal
    belongs_to :household, Tore.Household.HouseholdSchema
    timestamps()
  end

  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, [:dietary_restrictions, :allergies, :weekly_budget])
    |> validate_number(:weekly_budget, greater_than: 0)
  end
end
