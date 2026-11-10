defmodule Tore.Harness.Kinds.Receipt do
  @moduledoc """
  A receipt photo becomes a logged receipt. `ctx` holds `:image_binary`, and optionally
  `:image_path` (where the photo was stashed) and `:date`.

  It applies straight away when the lines add up to the total. When they don't, it waits for
  someone to check the store, total and week, since a misread total is the one error that matters.
  Undo deletes the receipt. The stashed photo is deleted once the run is settled.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.Household
  alias Tore.Harness.Artifact.CostEntry
  alias Tore.Harness.ReceiptIngestion
  alias Tore.Harness.Verifier.CostEntryVerifier

  @no_usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  @impl true
  def kind, do: "receipt_ingestion_run"

  @impl true
  def surface, do: :shop

  @impl true
  def open(ctx), do: %{input: %{"image_path" => ctx[:image_path]}, actor: :user}

  @impl true
  def propose(_run, %{scope: scope, image_binary: image} = ctx) do
    with {:ok, parsed} <- ReceiptIngestion.parse(scope, image, Household.locale(scope)) do
      cost =
        ReceiptIngestion.build_cost_entry(parsed, date: ctx[:date], image_path: ctx[:image_path])

      {:ok, cost, @no_usage}
    end
  end

  # Lines that don't add up send it to review rather than failing it.
  @impl true
  def verify(%CostEntry{} = cost, _ctx) do
    case CostEntryVerifier.verify(cost) do
      {:fail, :sum_mismatch, _repair} -> :ok
      result -> result
    end
  end

  @impl true
  def review_question(%CostEntry{} = cost) do
    if CostEntryVerifier.verify(cost) == {:fail, :sum_mismatch, :reject},
      do: "The lines don't add up to the total. Check the total before saving.",
      else: nil
  end

  @impl true
  def apply_proposal(%CostEntry{} = cost, %{scope: scope, run: run}) do
    with {:ok, receipt} <- ReceiptIngestion.apply!(scope, cost, scope.user_id || run.user_id) do
      {:ok, {:steps, [{:delete_receipt, receipt.id}]}, [cost]}
    end
  end

  @impl true
  def after_commit(%{status: status, input: %{"image_path" => path}})
      when status in [:applied, :discarded] and is_binary(path) and path != "" do
    Tore.Storage.RunPhotos.delete_async(path)
    :ok
  end

  def after_commit(_run), do: :ok
end
