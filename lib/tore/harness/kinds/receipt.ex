defmodule Tore.Harness.Kinds.Receipt do
  @moduledoc """
  A receipt pi read from a photo, or a total someone said, becomes a logged receipt
  (`log_receipt`). A typed total has no lines, and `:week_start` in `ctx` names its week.

  It applies straight away; one without a store, date or total fails instead, and so does one
  already logged (the same store, date and total). Undo deletes the receipt. Once it commits, its
  lines' products are matched to ingredients for prices (`Tore.Prices.Products`).
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Costs, Scope}
  alias Tore.Prices.Products
  alias Tore.Harness.Artifact.CostEntry
  alias Tore.Harness.ReceiptIngestion
  alias Tore.Harness.Verifier.CostEntryVerifier

  @impl true
  def kind, do: "receipt_ingestion_run"

  @impl true
  def surface, do: :shop

  @impl true
  def open(_ctx), do: %{input: %{}, actor: :user}

  @impl true
  def verify(%CostEntry{} = cost, %{scope: scope}) do
    with :ok <- CostEntryVerifier.verify(cost) do
      if Costs.receipt_logged?(scope, cost.store_name, cost.date, cost.total),
        do: {:fail, :duplicate_receipt, :reject},
        else: :ok
    end
  end

  @impl true
  def review_question(%CostEntry{}), do: nil

  @impl true
  def after_commit(%{status: :applied, artifacts: artifacts} = run) do
    names = for %CostEntry{line_items: lines} <- artifacts, line <- lines, do: line.name
    Products.later(Scope.for_household(run.household_id), names, model: run.actor != :mcp)
  end

  def after_commit(_run), do: :ok

  @impl true
  def apply_proposal(%CostEntry{} = cost, %{scope: scope, run: run} = ctx) do
    with {:ok, receipt} <-
           ReceiptIngestion.apply!(scope, cost, scope.user_id || run.user_id, ctx[:week_start]) do
      {:ok, {:steps, [{:delete_receipt, receipt.id}]}, [cost]}
    end
  end
end
