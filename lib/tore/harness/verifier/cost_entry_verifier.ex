defmodule Tore.Harness.Verifier.CostEntryVerifier do
  @moduledoc """
  Deterministic verifier for `CostEntry`. Pure: no writes, no model calls.

  Checks:
    * store name, date, and total are present
    * date is not in the future (vision can hallucinate)

  The lines carry no prices, so they can't be checked against the total.
  """

  alias Tore.Harness.Artifact.CostEntry

  @type fail_code ::
          :missing_store | :missing_date | :missing_total | :date_in_future
  @type repair_action :: :reject

  @spec verify(CostEntry.t(), map()) :: :ok | {:fail, fail_code(), repair_action()}
  def verify(%CostEntry{} = entry, _ctx \\ %{}) do
    with :ok <- check_store(entry),
         :ok <- check_date(entry),
         :ok <- check_total(entry) do
      :ok
    end
  end

  defp check_store(%CostEntry{store_name: s}) when is_binary(s) and s != "", do: :ok
  defp check_store(_), do: {:fail, :missing_store, :reject}

  defp check_date(%CostEntry{date: nil}), do: {:fail, :missing_date, :reject}

  defp check_date(%CostEntry{date: d}) do
    if Date.compare(d, Tore.Clock.today()) == :gt do
      {:fail, :date_in_future, :reject}
    else
      :ok
    end
  end

  defp check_total(%CostEntry{total: nil}), do: {:fail, :missing_total, :reject}
  defp check_total(_), do: :ok
end
