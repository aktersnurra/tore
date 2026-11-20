defmodule Tore.Budget.BudgetChange do
  @moduledoc """
  The household's weekly budget from `from_week` (a Monday) on, until the next change. A nil
  `amount` is no budget from that week.
  """

  use Ecto.Schema

  schema "budget_changes" do
    field :household_id, :integer
    field :from_week, :date
    field :amount, :decimal
    timestamps()
  end
end
