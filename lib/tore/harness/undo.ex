defmodule Tore.Harness.Undo do
  @moduledoc """
  How an applied run is reversed. A kind's `apply_proposal` captures the before-image of what
  it touches, so the undo is known when the run commits.

    * `{:steps, steps}`: restored in reverse order, in one transaction with the status change.
      `{:steps, []}` is the undo of an apply that changed nothing, such as a memory review
      with nothing to add.
    * `{:irreversible, reason}`: the Undo button is off and the receipt says why.

  `encode/1` and `decode/1` are strict: an unknown shape raises rather than turning into a
  no-op undo.
  """

  @type slot :: %{
          recipe_id: integer() | nil,
          servings: integer() | nil,
          skipped: boolean(),
          leftover: boolean(),
          reason: String.t() | nil
        }

  @type slot_before :: %{slot: slot() | :empty, pin: term() | :none}

  @type pantry_before :: %{
          name: String.t(),
          ingredient_id: integer() | nil,
          quantity: Decimal.t() | nil,
          unit: String.t() | nil,
          category: String.t() | nil,
          added_at: Date.t() | nil,
          expires_at: Date.t() | nil,
          expires_source: String.t() | nil,
          provenance: String.t() | nil,
          belief: String.t() | nil,
          last_seen_at: DateTime.t() | nil
        }

  @type step ::
          {:restore_plan_slots, plan_id :: String.t(), %{String.t() => slot_before()}}
          | {:restore_pantry_item, item_id :: integer(), pantry_before() | :absent}
          | {:restore_memory, added_ids :: [integer()], forgotten_ids :: [integer()]}
          | {:delete_receipt, receipt_id :: integer()}
          | {:delete_recipe, recipe_id :: integer()}

  @type t :: {:steps, [step()]} | {:irreversible, reason :: String.t()}

  @slot_keys ~w(recipe_id servings skipped leftover reason)a
  @pantry_keys ~w(name ingredient_id quantity unit category added_at expires_at expires_source provenance belief last_seen_at)a

  @spec reversible?(t()) :: boolean()
  def reversible?({:irreversible, _reason}), do: false
  def reversible?(_undo), do: true

  @spec encode(t()) :: map()
  def encode({:irreversible, reason}) when is_binary(reason), do: %{"irreversible" => reason}

  def encode({:steps, steps}) when is_list(steps),
    do: %{"steps" => Enum.map(steps, &encode_step/1)}

  def encode(other), do: raise(ArgumentError, "not an undo: #{inspect(other)}")

  @doc "Every map must hold exactly its own keys, so nothing in stored JSON is silently dropped."
  @spec decode(map()) :: t()

  def decode(%{} = undo) do
    case single!(undo) do
      {"irreversible", reason} when is_binary(reason) -> {:irreversible, reason}
      {"steps", steps} when is_list(steps) -> {:steps, Enum.map(steps, &decode_step/1)}
      _ -> raise ArgumentError, "not an undo: #{inspect(undo)}"
    end
  end

  def decode(other), do: raise(ArgumentError, "not an undo: #{inspect(other)}")

  defp encode_step({:restore_plan_slots, plan_id, slots})
       when is_binary(plan_id) and is_map(slots) do
    %{
      "restore_plan_slots" => %{
        "plan_id" => plan_id,
        "slots" => Map.new(slots, fn {key, before} -> {key, encode_slot_before(before)} end)
      }
    }
  end

  defp encode_step({:restore_pantry_item, id, :absent}) when is_integer(id),
    do: %{"restore_pantry_item" => %{"item_id" => id, "before" => "absent"}}

  defp encode_step({:restore_pantry_item, id, before}) when is_integer(id) and is_map(before),
    do: %{"restore_pantry_item" => %{"item_id" => id, "before" => encode_pantry(before)}}

  defp encode_step({:restore_memory, added, forgotten})
       when is_list(added) and is_list(forgotten),
       do: %{
         "restore_memory" => %{"added_ids" => ids!(added), "forgotten_ids" => ids!(forgotten)}
       }

  defp encode_step({:delete_receipt, id}) when is_integer(id), do: %{"delete_receipt" => id}
  defp encode_step({:delete_recipe, id}) when is_integer(id), do: %{"delete_recipe" => id}
  defp encode_step(other), do: raise(ArgumentError, "not an undo step: #{inspect(other)}")

  defp decode_step(%{} = step) do
    case single!(step) do
      {"restore_plan_slots", args} ->
        %{"plan_id" => plan_id, "slots" => slots} = exact!(args, ~w(plan_id slots))
        true = is_binary(plan_id) and is_map(slots)

        {:restore_plan_slots, plan_id,
         Map.new(slots, fn {key, before} -> {key, decode_slot_before(before)} end)}

      {"restore_pantry_item", args} ->
        %{"item_id" => id, "before" => before} = exact!(args, ~w(item_id before))
        true = is_integer(id)

        {:restore_pantry_item, id,
         if(before == "absent", do: :absent, else: decode_pantry(before))}

      {"restore_memory", args} ->
        %{"added_ids" => added, "forgotten_ids" => forgotten} =
          exact!(args, ~w(added_ids forgotten_ids))

        {:restore_memory, ids!(added), ids!(forgotten)}

      {"delete_receipt", id} when is_integer(id) ->
        {:delete_receipt, id}

      {"delete_recipe", id} when is_integer(id) ->
        {:delete_recipe, id}

      _ ->
        raise ArgumentError, "not an undo step: #{inspect(step)}"
    end
  rescue
    e in [MatchError] ->
      reraise ArgumentError, "not an undo step: #{inspect(e.term)}", __STACKTRACE__
  end

  defp decode_step(other), do: raise(ArgumentError, "not an undo step: #{inspect(other)}")

  # A missing "pin" key means the slot had no pin, since a pin's own value can be anything JSON.
  defp encode_slot_before(%{slot: slot, pin: :none}), do: %{"slot" => encode_slot(slot)}

  defp encode_slot_before(%{slot: slot, pin: pin}),
    do: %{"slot" => encode_slot(slot), "pin" => pin}

  defp encode_slot_before(other), do: raise(ArgumentError, "not a slot: #{inspect(other)}")

  defp decode_slot_before(%{"slot" => slot, "pin" => pin} = before) when map_size(before) == 2,
    do: %{slot: decode_slot(slot), pin: pin}

  defp decode_slot_before(%{"slot" => slot} = before) when map_size(before) == 1,
    do: %{slot: decode_slot(slot), pin: :none}

  defp decode_slot_before(other), do: raise(ArgumentError, "not a slot: #{inspect(other)}")

  defp encode_slot(:empty), do: "empty"

  defp encode_slot(%{} = slot) do
    Map.new(@slot_keys, fn key -> {Atom.to_string(key), Map.fetch!(slot, key)} end)
  end

  defp decode_slot("empty"), do: :empty

  defp decode_slot(%{} = slot) do
    slot = exact!(slot, Enum.map(@slot_keys, &Atom.to_string/1))

    %{
      recipe_id: optional(slot["recipe_id"], &is_integer/1),
      servings: optional(slot["servings"], &is_integer/1),
      skipped: required(slot["skipped"], &is_boolean/1),
      leftover: required(slot["leftover"], &is_boolean/1),
      reason: optional(slot["reason"], &is_binary/1)
    }
  end

  defp decode_slot(other), do: raise(ArgumentError, "not a slot: #{inspect(other)}")

  defp encode_pantry(before) do
    unknown = Map.keys(before) -- @pantry_keys
    if unknown != [], do: raise(ArgumentError, "unknown pantry fields #{inspect(unknown)}")

    Map.new(@pantry_keys, fn key ->
      {Atom.to_string(key), encode_value(Map.fetch!(before, key))}
    end)
  end

  defp decode_pantry(%{} = before) do
    before = exact!(before, Enum.map(@pantry_keys, &Atom.to_string/1))

    %{
      name: required(before["name"], &is_binary/1),
      ingredient_id: optional(before["ingredient_id"], &is_integer/1),
      quantity: optional(before["quantity"], &is_binary/1) |> then(&(&1 && Decimal.new(&1))),
      unit: optional(before["unit"], &is_binary/1),
      category: optional(before["category"], &is_binary/1),
      added_at:
        optional(before["added_at"], &is_binary/1) |> then(&(&1 && Date.from_iso8601!(&1))),
      expires_at:
        optional(before["expires_at"], &is_binary/1) |> then(&(&1 && Date.from_iso8601!(&1))),
      expires_source: optional(before["expires_source"], &is_binary/1),
      provenance: optional(before["provenance"], &is_binary/1),
      belief: optional(before["belief"], &is_binary/1),
      last_seen_at: optional(before["last_seen_at"], &is_binary/1) |> then(&(&1 && datetime!(&1)))
    }
  end

  defp decode_pantry(other), do: raise(ArgumentError, "not a pantry item: #{inspect(other)}")

  defp encode_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(%DateTime{time_zone: "Etc/UTC"} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(v) when is_binary(v) or is_integer(v) or is_nil(v), do: v
  defp encode_value(other), do: raise(ArgumentError, "can't encode #{inspect(other)}")

  defp datetime!(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, 0} -> dt
      _ -> raise ArgumentError, "not a UTC time: #{inspect(s)}"
    end
  end

  defp single!(map) when map_size(map) == 1, do: map |> Map.to_list() |> hd()
  defp single!(map), do: raise(ArgumentError, "expected one key: #{inspect(map)}")

  defp exact!(map, keys) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: map,
      else: raise(ArgumentError, "expected keys #{inspect(keys)}: #{inspect(map)}")
  end

  defp exact!(other, _keys), do: raise(ArgumentError, "expected a map: #{inspect(other)}")

  defp required(value, valid?) do
    if valid?.(value), do: value, else: raise(ArgumentError, "unexpected #{inspect(value)}")
  end

  defp optional(nil, _valid?), do: nil
  defp optional(value, valid?), do: required(value, valid?)

  defp ids!(ids) when is_list(ids) do
    if Enum.all?(ids, &is_integer/1),
      do: ids,
      else: raise(ArgumentError, "not ids: #{inspect(ids)}")
  end

  defp ids!(other), do: raise(ArgumentError, "not ids: #{inspect(other)}")
end
