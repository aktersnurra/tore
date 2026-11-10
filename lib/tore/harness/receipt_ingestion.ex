defmodule Tore.Harness.ReceiptIngestion do
  @moduledoc """
  Pure helpers for `:receipt_ingestion_run` (SPEC §5).

  The Orchestrator drives the Run aggregate; this module owns parsing the
  receipt image, shaping the `CostEntry` artifact, and logging it on commit.
  Receipts only record cost. They never touch the pantry or the shopping list:
  a misread line would drop an item off the list.
  """

  alias Tore.Costs
  alias Tore.Harness.Artifact.CostEntry

  @spec parse(Tore.Scope.t(), binary(), String.t() | nil) ::
          {:ok, %{store_name: String.t() | nil, total: Decimal.t() | nil, items: [map()]}}
          | {:error, term()}
  def parse(%Tore.Scope{} = scope, image_binary, locale) do
    Costs.parse_receipt(scope, image_binary, locale)
  end

  @spec build_cost_entry(map(), keyword()) :: CostEntry.t()
  def build_cost_entry(parsed, opts \\ []) do
    # Prefer the date the model extracted from the receipt itself. Fall
    # back to the caller-supplied date (tests pin this) and finally today.
    parsed_date = parsed[:purchase_date]
    supplied_date = Keyword.get(opts, :date)
    date = parsed_date || supplied_date || Date.utc_today()

    # The review card shows a "we couldn't read the date — please verify"
    # hint when this is true. Only flag when neither the OCR nor the caller
    # provided a real date.
    date_inferred? = is_nil(parsed_date) and is_nil(supplied_date)

    %CostEntry{
      store_name: parsed.store_name || "",
      date: date,
      date_inferred?: date_inferred?,
      total: parsed.total || Decimal.new(0),
      line_items:
        Enum.map(parsed.items || [], fn it ->
          %{
            name: it.name,
            quantity: it[:quantity],
            unit: it[:unit],
            total_price: it[:total_price],
            category: it[:category]
          }
        end),
      image_path: Keyword.get(opts, :image_path)
    }
  end

  @spec apply!(Tore.Scope.t(), CostEntry.t(), integer() | nil) ::
          {:ok, Costs.Receipt.t()} | {:error, term()}
  def apply!(%Tore.Scope{} = scope, %CostEntry{} = cost, user_id) do
    Costs.log_receipt(scope, %{
      date: cost.date,
      store_name: cost.store_name,
      total_amount: cost.total,
      user_id: user_id,
      image_path: cost.image_path,
      line_items: Enum.map(cost.line_items, &to_cost_line_item/1)
    })
  end

  @cost_categories ~w[dairy meat produce frozen dry_goods canned herbs_spices condiments other]

  defp to_cost_line_item(it) do
    %{
      product_name: it.name,
      quantity: it[:quantity],
      total_price: it[:total_price],
      category: sanitise_category(it[:category])
    }
  end

  # Defensive: if the LLM returns a category outside our enum (locale label,
  # made-up string, etc.) fall back to "other" rather than dropping it or
  # crashing the changeset — "other" is what the enum exists for.
  defp sanitise_category(c) when c in @cost_categories, do: c
  defp sanitise_category(_), do: "other"
end
