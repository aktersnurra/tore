defmodule Tore.Harness.ReceiptIngestion do
  @moduledoc """
  The receipt work behind `:receipt_ingestion_run` (SPEC §5).

  `Tore.Harness.Kinds.Receipt` drives the run; this module logs the `CostEntry` pi read on
  commit (a database write).
  Receipts only record cost. They never touch the pantry or the shopping list:
  a misread line would drop an item off the list.
  """

  alias Tore.Costs
  alias Tore.Harness.Artifact.CostEntry

  @doc "Logs the receipt. Without `week_start` it counts towards `Costs.receipt_week/2`'s week."
  @spec apply!(Tore.Scope.t(), CostEntry.t(), integer() | nil, Date.t() | nil) ::
          {:ok, Costs.Receipt.t()} | {:error, term()}
  def apply!(%Tore.Scope{} = scope, %CostEntry{} = cost, user_id, week_start \\ nil) do
    attrs = %{
      date: cost.date,
      store_name: cost.store_name,
      total_amount: cost.total,
      user_id: user_id,
      line_items: Enum.map(cost.line_items, &to_cost_line_item/1)
    }

    Costs.log_receipt(
      scope,
      if(week_start, do: Map.put(attrs, :week_start, week_start), else: attrs)
    )
  end

  defp to_cost_line_item(it) do
    %{
      product_name: it.name,
      quantity: it[:quantity],
      unit: it[:unit],
      total_price: it[:total_price],
      category: sanitise_category(it[:category])
    }
  end

  # Defensive: if the LLM returns a category outside our enum (locale label,
  # made-up string, etc.) fall back to "other" rather than dropping it or
  # crashing the changeset — "other" is what the enum exists for.
  defp sanitise_category(c) do
    if c in Tore.Recipes.Ingredient.sections(), do: c, else: "other"
  end
end
