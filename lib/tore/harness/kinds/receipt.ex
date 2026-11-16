defmodule Tore.Harness.Kinds.Receipt do
  @moduledoc """
  A receipt photo becomes a logged receipt. `ctx` holds `:image_binary`, and optionally `:date`.
  A typed total is submitted with its `CostEntry` and no lines, and `:week_start` names its week.

  It applies straight away; a reading without a store, date or total fails instead. Undo deletes
  the receipt. Once it commits, its lines' products are matched to ingredients for prices
  (`Tore.Prices.Products`), with the model unless it came over MCP.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Household, Scope}
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
  def propose(_run, %{scope: scope, image_binary: image} = ctx) do
    with {:ok, parsed} <- ReceiptIngestion.parse(scope, image, Household.locale(scope)) do
      {:ok, ReceiptIngestion.build_cost_entry(parsed, date: ctx[:date])}
    end
  end

  @impl true
  def verify(%CostEntry{} = cost, _ctx), do: CostEntryVerifier.verify(cost)

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
