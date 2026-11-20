defmodule Tore.Deals.Pick do
  @moduledoc """
  Jev's answer about one offer for a household (`Tore.Deals.Picks`): `"usual"`, something they
  buy; `"maybe"`, something they might want; `"no"`, not for them. With how sure it was, 0 to 1.
  """
  use Ecto.Schema

  schema "deal_picks" do
    field :household_id, :integer
    field :deal_id, :integer
    field :kind, :string
    field :confidence, :float
    timestamps(updated_at: false)
  end
end
