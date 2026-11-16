defmodule Tore.Mcp.Tools.DeleteReceipt do
  @moduledoc "Deletes a receipt, as Capture does. There is no undo."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "delete_receipt"

  @impl true
  def description, do: "Deletes a receipt, found with list_receipts. This can't be undone."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"receipt_id" => %{"type" => "integer"}},
      "required" => ["receipt_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"receipt_id" => id}) when is_integer(id),
    do: Tool.reply(Dispatch.delete_receipt(id, Tool.ctx(scope)))

  def call(_scope, _args), do: {:error, "delete_receipt needs receipt_id, a number."}
end
