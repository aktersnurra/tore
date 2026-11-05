defmodule Tore.Costs.DiningOut do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dining_out" do
    field :date, :date
    field :description, :string
    field :total_amount, :decimal
    field :plan_id, :string
    field :slot_key, :string
    belongs_to :user, Tore.Accounts.User
    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:date, :description, :total_amount, :plan_id, :slot_key, :user_id])
    |> validate_required([:date, :user_id])
    |> validate_number(:total_amount, greater_than_or_equal_to: 0)
    |> unique_constraint([:plan_id, :slot_key])
  end
end
