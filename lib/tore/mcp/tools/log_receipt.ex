defmodule Tore.Mcp.Tools.LogReceipt do
  @moduledoc """
  Logs a receipt pi read from a photo, or a total someone says they spent. It becomes the receipt
  run's proposal, so it passes `CostEntryVerifier` and undo deletes it, as for a receipt Tore read
  itself. `week` puts the spending in that week rather than the one `Tore.Costs.receipt_week/2`
  works out from the date.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.CostEntry
  alias Tore.Harness.Kinds.Receipt
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "log_receipt"

  @impl true
  def description,
    do: """
    Logs a grocery receipt you read: the store, the purchase date, the total in kronor, and its \
    lines as printed. Give each line the shop section it belongs to; the budget page groups by it. \
    Receipts record spending only; they don't change the pantry or the list. \
    A total someone tells you with no receipt ("we spent 1 900 this week") is logged too: store \
    is the shop they name, or what they called it, in the household's language; date is the \
    last day of that week not after today; `week` is that week's Monday; no lines.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "store" => %{"type" => "string"},
        "date" => %{"type" => "string", "format" => "date"},
        "total" => %{"type" => "number", "minimum" => 0},
        "week" => %{"type" => "string", "format" => "date"},
        "lines" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "quantity" => %{"type" => "number"},
              "unit" => %{"type" => "string"},
              "price" => %{"type" => "number"},
              "section" => %{"type" => "string", "enum" => Tore.Recipes.Ingredient.sections()}
            },
            "required" => ["name"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["store", "date", "total"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, args) do
    with {:ok, date} <- Tool.date(args["date"]),
         {:ok, ctx} <- week(args["week"]) do
      cost = %CostEntry{
        store_name: args["store"],
        date: date,
        total: Tore.Types.decimal(args["total"]),
        line_items: Enum.map(args["lines"] || [], &line/1)
      }

      case Runs.submit(scope, Receipt, cost, ctx) do
        {:ok, %KitchenRun{status: :applied, id: id}} ->
          {:ok, %{done: "Logged #{cost.store_name}, #{args["total"]} kr.", run_id: id}}

        {:ok, %KitchenRun{failure_code: code}} ->
          {:error, "Not logged: #{code}."}

        {:error, reason} ->
          {:error, "Not logged: #{inspect(reason)}."}
      end
    end
  end

  defp week(nil), do: {:ok, %{actor: :mcp}}

  defp week(value) do
    with {:ok, day} <- Tool.date(value),
         do: {:ok, %{actor: :mcp, week_start: Tore.Streams.monday(day)}}
  end

  defp line(line) do
    %{
      name: line["name"],
      quantity: Tore.Types.decimal(line["quantity"]),
      unit: line["unit"],
      total_price: Tore.Types.decimal(line["price"]),
      category: line["section"]
    }
  end
end
