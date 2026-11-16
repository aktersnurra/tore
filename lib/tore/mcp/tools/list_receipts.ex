defmodule Tore.Mcp.Tools.ListReceipts do
  @moduledoc "The household's latest receipts."
  @behaviour Tore.Mcp.Tool

  alias Tore.Costs

  @impl true
  def name, do: "list_receipts"

  @impl true
  def description, do: "The latest receipts, newest first: store, date and total in kronor."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}},
      "additionalProperties" => false
    }

  @impl true
  def call(scope, args) do
    limit = if is_integer(args["limit"]), do: min(max(args["limit"], 1), 50), else: 10

    {:ok,
     %{
       receipts:
         for r <- Costs.recent_receipts(scope, limit) do
           %{receipt_id: r.id, store: r.store_name, date: r.date, total: r.total_amount}
         end
     }}
  end
end
