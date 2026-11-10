defmodule Tore.Harness.Artifact.ShopChange do
  @moduledoc """
  One change to a shopping list: an item added, an item checked off, or the list built for a
  week. Output of `:shop_edit_run`.

  Items stay in their JSON form (string keys, quantity as a string, section as a string), the
  form the shop's event store already replays, so a stored change reads back unchanged.
  """

  @behaviour Tore.Harness.Artifact

  @enforce_keys [:list_id, :change, :items]
  defstruct [:list_id, :change, :items, :week_start]

  @type change :: :add | :check | :build
  @type item :: %{String.t() => String.t() | boolean() | nil}
  @type t :: %__MODULE__{
          list_id: String.t(),
          change: change(),
          items: [item()],
          week_start: Date.t() | nil
        }

  @item_keys ~w(id name quantity unit section checked)

  @doc "An item in the stored form, from the shop's own item map."
  @spec item(map()) :: item()
  def item(%{} = item) do
    %{
      "id" => fetch(item, :id),
      "name" => fetch(item, :name),
      "quantity" => quantity(fetch(item, :quantity)),
      "unit" => fetch(item, :unit),
      "section" => item |> fetch(:section) |> section(),
      "checked" => fetch(item, :checked) || false
    }
  end

  defp fetch(item, key), do: Map.get(item, key, Map.get(item, Atom.to_string(key)))

  defp quantity(nil), do: nil
  defp quantity(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp quantity(n) when is_number(n), do: to_string(n)
  defp quantity(s) when is_binary(s), do: s

  defp section(nil), do: "other"
  defp section(s), do: to_string(s)

  @impl true
  def kind, do: "ShopChange"

  @impl true
  def summary(%__MODULE__{change: change, items: items}),
    do: %{counts: %{change => length(items)}, text_fallback: "#{change} #{length(items)}"}

  @impl true
  def is_rationale_complete(_change), do: true

  @impl true
  def to_json(%__MODULE__{} = c) do
    %{
      "list_id" => c.list_id,
      "change" => Atom.to_string(c.change),
      "items" => c.items,
      "week_start" => c.week_start && Date.to_iso8601(c.week_start)
    }
  end

  @impl true
  def from_json(%{"list_id" => list_id, "change" => change, "items" => items, "week_start" => ws})
      when is_binary(list_id) and is_list(items) do
    %__MODULE__{
      list_id: list_id,
      change: change_atom(change),
      items: Enum.map(items, &stored_item!/1),
      week_start: ws && Date.from_iso8601!(ws)
    }
  end

  defp change_atom("add"), do: :add
  defp change_atom("check"), do: :check
  defp change_atom("build"), do: :build

  defp stored_item!(%{} = item) do
    true = item |> Map.keys() |> Enum.sort() == Enum.sort(@item_keys)
    item
  end
end
