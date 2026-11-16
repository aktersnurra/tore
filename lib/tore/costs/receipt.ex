defmodule Tore.Costs.Receipt do
  use Ecto.Schema
  import Ecto.Changeset

  schema "receipts" do
    field :household_id, :integer
    field :date, :date
    field :week_start, :date
    field :store_name, :string
    field :total_amount, :decimal
    belongs_to :user, Tore.Accounts.User
    has_many :line_items, Tore.Costs.LineItem
    timestamps()
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:date, :week_start, :store_name, :total_amount, :user_id])
    |> validate_required([:date, :week_start, :user_id])
    |> validate_number(:total_amount, greater_than_or_equal_to: 0)
  end
end
