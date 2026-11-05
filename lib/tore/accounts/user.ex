defmodule Tore.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :account_code_hash, :string
    field :role, Ecto.Enum, values: [:admin, :member], default: :member
    field :preferences, :map, default: %{}
    field :locale, :string, default: "sv"
    belongs_to :household, Tore.Household.HouseholdSchema
    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :role, :account_code_hash, :locale])
    |> validate_required([:name, :role, :account_code_hash])
    |> validate_length(:name, min: 1, max: 100)
  end

  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:preferences])
    |> validate_required([:preferences])
  end
end
