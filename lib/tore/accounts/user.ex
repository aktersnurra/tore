defmodule Tore.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :username, :string
    field :oidc_sub, :string
    field :ai_enabled, :boolean, default: false
    field :preferences, :map, default: %{}
    field :locale, :string, default: "sv"
    belongs_to :household, Tore.Household.HouseholdSchema
    timestamps()
  end

  @doc "What Pocket ID says about this person, refreshed at each sign-in."
  def sign_in_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :username, :oidc_sub, :ai_enabled])
    |> validate_required([:name, :username, :oidc_sub, :household_id])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:username)
    |> unique_constraint(:oidc_sub)
  end

  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:preferences])
    |> validate_required([:preferences])
  end
end
