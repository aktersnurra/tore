defmodule Tore.Harness.Artifact.PantryBeliefUpdate do
  @moduledoc """
  Pantry items added, removed, or `last_seen_at`-bumped by a run, each with
  provenance. Output of `:pantry_belief_update_run`.

  Pantry is modelled as belief, not fact (SPEC §4): every write carries
  provenance and the user's last observation timestamp. The verifier checks
  that those invariants are honoured before commit.
  """

  @behaviour Tore.Harness.Artifact

  @type change_kind :: :added | :bumped | :removed

  @type item :: %{
          name: String.t(),
          change: change_kind(),
          quantity: Decimal.t() | nil,
          unit: String.t() | nil,
          category: String.t() | nil,
          provenance: String.t(),
          last_seen_at: DateTime.t()
        }

  @derive Jason.Encoder
  @enforce_keys [:items]
  defstruct [:items]

  @type t :: %__MODULE__{items: [item()]}

  @impl true
  def kind, do: "PantryBeliefUpdate"

  @impl true
  def summary(%__MODULE__{items: items}) do
    counts = Enum.frequencies_by(items, & &1.change)

    %{
      counts: counts,
      text_fallback: Enum.map_join(counts, ", ", fn {k, v} -> "#{v} #{k}" end)
    }
  end

  @impl true
  def is_rationale_complete(%__MODULE__{items: items}) do
    Enum.all?(items, fn it ->
      is_binary(it.name) and it.name != "" and is_binary(it.provenance) and
        not is_nil(it.last_seen_at)
    end)
  end

  @impl true
  def to_json(%__MODULE__{items: items}) do
    %{"items" => Enum.map(items, &item_to_json/1)}
  end

  @impl true
  def from_json(%{"items" => items}) do
    %__MODULE__{items: Enum.map(items, &item_from_json/1)}
  end

  defp item_to_json(it) do
    %{
      "name" => it.name,
      "change" => Atom.to_string(it.change),
      "quantity" => decimal_to_string(it[:quantity]),
      "unit" => it[:unit],
      "category" => it[:category],
      "provenance" => it.provenance,
      "last_seen_at" => DateTime.to_iso8601(it.last_seen_at)
    }
  end

  defp item_from_json(m) do
    %{
      name: m["name"],
      change: change_atom(m["change"]),
      quantity: to_decimal(m["quantity"]),
      unit: m["unit"],
      category: m["category"],
      provenance: m["provenance"],
      last_seen_at: parse_dt(m["last_seen_at"])
    }
  end

  defp change_atom("added"), do: :added
  defp change_atom("bumped"), do: :bumped
  defp change_atom("removed"), do: :removed

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
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
  defp decimal_to_string(s) when is_binary(s), do: s
end
