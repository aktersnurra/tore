defmodule Tore.Harness.Artifact.CostEntry do
  @moduledoc """
  Parsed receipt: store, date, total, line items.
  Output of `:receipt_ingestion_run`.
  """

  @behaviour Tore.Harness.Artifact

  @type line_item :: %{
          name: String.t(),
          quantity: Decimal.t() | nil,
          unit: String.t() | nil,
          total_price: Decimal.t() | nil,
          category: String.t() | nil
        }

  @derive Jason.Encoder
  @enforce_keys [:store_name, :date, :total, :line_items]
  defstruct [:store_name, :date, :total, :line_items]

  @type t :: %__MODULE__{
          store_name: String.t(),
          date: Date.t(),
          total: Decimal.t(),
          line_items: [line_item()]
        }

  @impl true
  def kind, do: "CostEntry"

  @impl true
  def to_json(%__MODULE__{} = c) do
    %{
      "store_name" => c.store_name,
      "date" => Date.to_iso8601(c.date),
      "total" => decimal_to_string(c.total),
      "line_items" => Enum.map(c.line_items, &line_item_to_json/1)
    }
  end

  @impl true
  def from_json(%{"store_name" => s, "date" => d, "total" => t, "line_items" => items}) do
    %__MODULE__{
      store_name: s,
      date: Date.from_iso8601!(d),
      total: Tore.Types.decimal(t),
      line_items: Enum.map(items, &line_item_from_json/1)
    }
  end

  defp line_item_to_json(item) do
    %{
      "name" => item.name,
      "quantity" => decimal_to_string(item[:quantity]),
      "unit" => item[:unit],
      "total_price" => decimal_to_string(item[:total_price]),
      "category" => item[:category]
    }
  end

  defp line_item_from_json(m) do
    %{
      name: m["name"],
      quantity: Tore.Types.decimal(m["quantity"]),
      unit: m["unit"],
      total_price: Tore.Types.decimal(m["total_price"]),
      category: m["category"]
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(n) when is_number(n), do: to_string(n)
end
