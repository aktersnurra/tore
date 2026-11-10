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
          expires_on: Date.t() | nil,
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

  # The canonicaliser's answer (`catalogue_name`, `matched_key`, `default_unit`,
  # `shelf_life_days`) is nil until the run resolves the items.
  @resolved ~w(catalogue_name matched_key default_unit shelf_life_days)a
  @json_keys ~w(name change quantity unit category expires_on provenance last_seen_at catalogue_name matched_key default_unit shelf_life_days)

  defp item_to_json(it) do
    %{
      "name" => it.name,
      "change" => Atom.to_string(it.change),
      "quantity" => decimal_to_string(it[:quantity]),
      "unit" => it[:unit],
      "category" => it[:category],
      "expires_on" => it[:expires_on] && Date.to_iso8601(it[:expires_on]),
      "provenance" => it.provenance,
      "last_seen_at" => DateTime.to_iso8601(it.last_seen_at)
    }
    |> Map.merge(Map.new(@resolved, &{Atom.to_string(&1), it[&1]}))
  end

  # Strict: a stored item has exactly these keys, and a quantity that isn't a number raises.
  defp item_from_json(m) do
    true = m |> Map.keys() |> Enum.sort() == Enum.sort(@json_keys)

    %{
      name: m["name"],
      change: change_atom(m["change"]),
      quantity: to_decimal(m["quantity"]),
      unit: m["unit"],
      category: m["category"],
      expires_on: m["expires_on"] && Date.from_iso8601!(m["expires_on"]),
      provenance: m["provenance"],
      last_seen_at: parse_dt(m["last_seen_at"]),
      catalogue_name: m["catalogue_name"],
      matched_key: m["matched_key"],
      default_unit: m["default_unit"],
      shelf_life_days: m["shelf_life_days"]
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
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(n) when is_number(n), do: to_string(n)
  defp decimal_to_string(s) when is_binary(s), do: s
end
