defmodule Tore.Household.HouseholdSchema do
  use Ecto.Schema
  import Ecto.Changeset

  schema "households" do
    field :name, :string
    field :locale, :string
    field :ai_sponsor_id, :integer
    has_many :memberships, Tore.Accounts.Membership, foreign_key: :household_id
    has_one :preferences, Tore.Household.Preferences, foreign_key: :household_id
    timestamps()
  end

  @doc "A household's name, and its language when it has none yet. The language can't change once set."
  def changeset(household, attrs) do
    household
    |> cast(attrs, if(household.locale, do: [:name], else: [:name, :locale]))
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:locale, ~w(sv en))
  end
end
