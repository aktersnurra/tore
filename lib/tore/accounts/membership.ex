defmodule Tore.Accounts.Membership do
  @moduledoc "A user belonging to a household. A user's one active membership is the household they act for."
  use Ecto.Schema

  @primary_key false
  schema "memberships" do
    belongs_to :user, Tore.Accounts.User, primary_key: true
    belongs_to :household, Tore.Household.HouseholdSchema, primary_key: true
    field :active, :boolean, default: false
    timestamps(updated_at: false)
  end
end
