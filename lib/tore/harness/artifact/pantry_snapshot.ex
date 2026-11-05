defmodule Tore.Harness.Artifact.PantrySnapshot do
  @moduledoc """
  Per-row before/after snapshot of a pantry mutation. Added alongside
  `PantryBeliefUpdate` after `PantryUpdate.apply!` has run so the
  `UndoPayload` derived at commit time carries enough information to
  restore the affected rows exactly.

  Each item is `%{item_id, before, after}`:

    * `before == nil` → the row didn't exist before the run; revert deletes it.
    * `before == %{quantity, unit, last_seen_at, provenance, belief, added_at,
      expires_at, expires_source}` →
      revert restores those fields on the same row.
  """

  @behaviour Tore.Harness.Artifact

  @derive Jason.Encoder
  @enforce_keys [:items]
  defstruct [:items]

  @type before_attrs ::
          nil
          | %{
              quantity: term(),
              unit: String.t() | nil,
              last_seen_at: DateTime.t() | nil,
              provenance: String.t() | nil,
              belief: String.t() | nil,
              added_at: Date.t() | String.t() | nil,
              expires_at: Date.t() | String.t() | nil,
              expires_source: String.t() | nil
            }

  @type item :: %{
          item_id: integer(),
          before: before_attrs(),
          after: map()
        }

  @type t :: %__MODULE__{items: [item()]}

  @impl true
  def kind, do: "PantrySnapshot"

  @impl true
  def summary(%__MODULE__{items: items}),
    do: %{counts: %{snapshotted: length(items)}, text_fallback: "pantry snapshot"}

  @impl true
  def is_rationale_complete(_), do: true

  @impl true
  def to_json(%__MODULE__{items: items}) do
    %{"items" => Enum.map(items, &item_to_json/1)}
  end

  @impl true
  def from_json(%{"items" => items}) do
    %__MODULE__{items: Enum.map(items, &item_from_json/1)}
  end

  defp item_to_json(%{item_id: id, before: before, after: aft}) do
    %{
      "item_id" => id,
      "before" => attrs_to_json(before),
      "after" => attrs_to_json(aft)
    }
  end

  defp item_from_json(%{"item_id" => id, "before" => before, "after" => aft}) do
    %{
      item_id: id,
      before: attrs_from_json(before),
      after: attrs_from_json(aft)
    }
  end

  defp attrs_to_json(nil), do: nil

  defp attrs_to_json(attrs) when is_map(attrs) do
    %{
      "quantity" => decimal_to_string(attrs[:quantity]),
      "unit" => attrs[:unit],
      "last_seen_at" => datetime_to_iso(attrs[:last_seen_at]),
      "provenance" => attrs[:provenance],
      "belief" => attrs[:belief],
      "added_at" => date_to_iso(attrs[:added_at]),
      "expires_at" => date_to_iso(attrs[:expires_at]),
      "expires_source" => attrs[:expires_source]
    }
  end

  defp attrs_from_json(nil), do: nil

  defp attrs_from_json(attrs) when is_map(attrs) do
    %{
      quantity: attrs["quantity"],
      unit: attrs["unit"],
      last_seen_at: iso_to_datetime(attrs["last_seen_at"]),
      provenance: attrs["provenance"],
      belief: attrs["belief"],
      added_at: attrs["added_at"],
      expires_at: attrs["expires_at"],
      expires_source: attrs["expires_source"]
    }
  end

  defp date_to_iso(%Date{} = date), do: Date.to_iso8601(date)
  defp date_to_iso(other), do: other

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(other), do: other

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso(other), do: other

  defp iso_to_datetime(nil), do: nil

  defp iso_to_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp iso_to_datetime(other), do: other
end
