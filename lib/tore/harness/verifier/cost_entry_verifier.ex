defmodule Tore.Harness.Verifier.CostEntryVerifier do
  @moduledoc """
  Deterministic verifier for `CostEntry`. Pure: no writes, no model calls.

  Checks:
    * store name, date, and total are present
    * date is not in the future (vision can hallucinate)
    * line item totals sum within tolerance of the receipt total

  Repair action is `:reject` — the user must edit the proposal on the
  `:needs_user` card before re-submitting.
  """

  alias Tore.Harness.Artifact.CostEntry

  @tolerance_pct Decimal.from_float(0.05)

  @type fail_code ::
          :missing_store | :missing_date | :missing_total | :date_in_future | :sum_mismatch
  @type repair_action :: :reject

  @spec verify(CostEntry.t(), map()) :: :ok | {:fail, fail_code(), repair_action()}
  def verify(%CostEntry{} = entry, _ctx \\ %{}) do
    with :ok <- check_store(entry),
         :ok <- check_date(entry),
         :ok <- check_total(entry),
         :ok <- check_sum(entry) do
      :ok
    end
  end

  defp check_store(%CostEntry{store_name: s}) when is_binary(s) and s != "", do: :ok
  defp check_store(_), do: {:fail, :missing_store, :reject}

  defp check_date(%CostEntry{date: nil}), do: {:fail, :missing_date, :reject}

  defp check_date(%CostEntry{date: d}) do
    if Date.compare(d, Date.utc_today()) == :gt do
      {:fail, :date_in_future, :reject}
    else
      :ok
    end
  end

  defp check_total(%CostEntry{total: nil}), do: {:fail, :missing_total, :reject}
  defp check_total(_), do: :ok

  # Sum-check only when at least one line item carries a price. The pantry
  # vision callback returns name/quantity/unit/category with no per-item total,
  # so a no-price proposal is a valid receipt that simply can't be cross-checked
  # against the printed total.
  defp check_sum(%CostEntry{line_items: items, total: total}) do
    priced = Enum.filter(items, fn it -> not is_nil(it[:total_price]) end)

    if priced == [] do
      :ok
    else
      item_sum =
        Enum.reduce(priced, Decimal.new(0), fn it, acc -> Decimal.add(acc, it.total_price) end)

      diff = Decimal.abs(Decimal.sub(item_sum, total))
      cap = Decimal.mult(Decimal.abs(total), @tolerance_pct)

      cond do
        Decimal.compare(total, Decimal.new(0)) == :eq -> :ok
        Decimal.compare(diff, cap) == :gt -> {:fail, :sum_mismatch, :reject}
        true -> :ok
      end
    end
  end
end
