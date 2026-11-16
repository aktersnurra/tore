defmodule Tore.Basics.Basic do
  @moduledoc """
  Something the household buys regularly beyond its dinners: milk, coffee, bread. Due when it was
  last bought `interval_days` ago or more, and added to the week's list then.
  """

  use Ecto.Schema

  schema "basics" do
    field :household_id, :integer
    field :ingredient_id, :integer
    field :interval_days, :integer
    field :source, Ecto.Enum, values: [:learned, :asked]
    field :quantity, :decimal
    field :unit, :string
    field :last_bought, :date
    field :removals, :integer, default: 0
    field :stopped, :boolean, default: false
    timestamps()
  end
end
