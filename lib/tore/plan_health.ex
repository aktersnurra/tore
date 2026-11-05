defmodule Tore.PlanHealth do
  @type status :: :ready | :flexible | :fragile | :unplanned

  # The second element is the message-relevant count: skipped slots for
  # :fragile, unplanned slots for :flexible, 0 otherwise. The view turns
  # {status, count} into a localized message (gettext lives in the web layer).
  # Eating out is a decision, so it's neither unplanned nor skipped.
  @type result :: {status(), non_neg_integer()}

  alias Tore.Planning.State

  @weekdays ~w(mon tue wed thu fri)

  @spec compute(map()) :: result()
  def compute(plan_state) do
    slots = plan_state.slots || %{}
    week_keys = Enum.map(@weekdays, &"#{&1}_dinner")

    assigned =
      Enum.filter(week_keys, fn k ->
        slot = Map.get(slots, k)
        slot && slot.recipe_id && !slot.skipped
      end)

    skipped =
      Enum.filter(week_keys, fn k ->
        slot = Map.get(slots, k)
        slot && slot.skipped && !State.eating_out?(slot)
      end)

    eating_out = Enum.filter(week_keys, &State.eating_out?(Map.get(slots, &1)))

    unplanned_count = length(week_keys) - length(assigned) - length(skipped) - length(eating_out)

    cond do
      assigned == [] and eating_out == [] ->
        {:unplanned, 0}

      length(skipped) > 0 ->
        {:fragile, length(skipped)}

      unplanned_count > 0 ->
        {:flexible, unplanned_count}

      true ->
        {:ready, 0}
    end
  end
end
