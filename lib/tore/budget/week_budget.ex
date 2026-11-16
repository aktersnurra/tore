defmodule Tore.Budget.WeekBudget do
  @moduledoc "A week's own budget, set when someone asks to plan that week to one."

  use Ecto.Schema

  schema "week_budgets" do
    field :household_id, :integer
    field :week_start, :date
    field :amount, :decimal
    timestamps()
  end
end
