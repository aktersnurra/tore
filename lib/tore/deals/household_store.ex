defmodule Tore.Deals.HouseholdStore do
  @moduledoc "A store a household uses, and whether its offers are fetched."
  use Ecto.Schema
  import Ecto.Changeset

  schema "household_stores" do
    field :household_id, :integer
    field :scrape_enabled, :boolean, default: true
    belongs_to :store, Tore.Deals.Store
    timestamps()
  end

  def changeset(household_store, attrs) do
    household_store
    |> cast(attrs, [:scrape_enabled])
    |> unique_constraint(:store_id, name: :household_stores_household_id_store_id_index)
  end
end
