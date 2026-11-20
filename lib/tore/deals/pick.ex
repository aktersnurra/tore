defmodule Tore.Deals.Pick do
  @moduledoc "Jev's guess at how likely a household is to want one offer, 0 to 1 (`Tore.Deals.Picks`)."
  use Ecto.Schema

  schema "deal_picks" do
    field :household_id, :integer
    field :deal_id, :integer
    field :chance, :float
    timestamps(updated_at: false)
  end
end
