defmodule Tore.Harness.Artifact.CostEntry do
  @moduledoc """
  Parsed receipt: store, date, total, line items, optional image path.
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
  defstruct [:store_name, :date, :total, :line_items, :image_path, date_inferred?: false]

  @type t :: %__MODULE__{
          store_name: String.t(),
          date: Date.t(),
          total: Decimal.t(),
          line_items: [line_item()],
          image_path: String.t() | nil,
          # True when the parser couldn't read a date from the receipt and
          # ReceiptIngestion filled in today's date as a fallback. The
          # review card uses this to flag "we couldn't read the date" so
          # the user knows to verify it before committing.
          date_inferred?: boolean()
        }

  @impl true
  def kind, do: "CostEntry"

  @impl true
  def summary(%__MODULE__{line_items: items, total: total}) do
    counts = %{added: length(items)}

    %{
      counts: counts,
      text_fallback: "#{length(items)} items, total #{format_total(total)}"
    }
  end

  @impl true
  def is_rationale_complete(%__MODULE__{store_name: s, date: d, total: t, line_items: items}) do
    is_binary(s) and s != "" and not is_nil(d) and not is_nil(t) and is_list(items)
  end

  @impl true
  def to_json(%__MODULE__{} = c) do
    %{
      "store_name" => c.store_name,
      "date" => Date.to_iso8601(c.date),
      "total" => decimal_to_string(c.total),
      "line_items" => Enum.map(c.line_items, &line_item_to_json/1),
      "image_path" => c.image_path,
      "date_inferred" => c.date_inferred?
    }
  end

  @impl true
  def from_json(%{"store_name" => s, "date" => d, "total" => t, "line_items" => items} = m) do
    %__MODULE__{
      store_name: s,
      date: Date.from_iso8601!(d),
      total: to_decimal(t),
      line_items: Enum.map(items, &line_item_from_json/1),
      image_path: Map.get(m, "image_path"),
      date_inferred?: m["date_inferred"] == true
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
      quantity: to_decimal(m["quantity"]),
      unit: m["unit"],
      total_price: to_decimal(m["total_price"]),
      category: m["category"]
    }
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(n) when is_number(n), do: to_string(n)

  defp format_total(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_total(n), do: to_string(n)
end
