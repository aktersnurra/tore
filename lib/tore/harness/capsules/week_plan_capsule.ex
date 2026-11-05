defmodule Tore.Harness.Capsules.WeekPlanCapsule do
  @behaviour Tore.Harness.Capsule

  import Ecto.Query
  alias Tore.Planning
  alias Tore.Recipes.Recipe
  alias Tore.Repo

  @day_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  defstruct [:week_start, :slots]

  @type slot :: %{
          day: String.t(),
          date: Date.t(),
          slot_key: String.t(),
          status: :empty | :assigned | :skipped | :eating_out,
          recipe_title: String.t() | nil
        }
  @type t :: %__MODULE__{week_start: Date.t() | nil, slots: [slot()] | nil}

  @impl true
  def build(ctx) do
    case Planning.load_plan(ctx.plan_stream_id) do
      {:ok, state} ->
        %__MODULE__{week_start: ctx.week_start, slots: build_slots(state, ctx.week_start)}

      _ ->
        %__MODULE__{week_start: ctx.week_start, slots: nil}
    end
  rescue
    _ -> %__MODULE__{week_start: ctx.week_start, slots: nil}
  end

  @impl true
  def to_prompt(%__MODULE__{slots: nil}), do: nil

  def to_prompt(%__MODULE__{slots: slots}) do
    lines =
      Enum.map_join(slots, "\n", fn s ->
        body =
          case {s.status, s.recipe_title} do
            {:assigned, title} when is_binary(title) -> title
            {status, _} -> Atom.to_string(status)
          end

        "  #{s.day} #{Date.to_iso8601(s.date)} (#{s.slot_key}): #{body}"
      end)

    "This week's dinner plan:\n#{lines}"
  end

  defp build_slots(state, week_start) do
    title_lookup = recipe_titles(state)

    Enum.with_index(@day_names, fn day_name, i ->
      date = Date.add(week_start, i)
      slot_key = "#{String.downcase(String.slice(day_name, 0..2))}_dinner"
      slot = Map.get(state.slots, slot_key)

      %{
        day: day_name,
        date: date,
        slot_key: slot_key,
        status: slot_status(slot),
        recipe_title: slot_recipe_title(slot, title_lookup)
      }
    end)
  end

  defp recipe_titles(state) do
    ids =
      state.slots
      |> Enum.map(fn {_k, slot} -> slot[:recipe_id] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        Repo.all(from r in Recipe, where: r.id in ^ids, select: {r.id, r.title})
        |> Map.new()
    end
  end

  defp slot_recipe_title(%{recipe_id: id}, titles) when not is_nil(id), do: Map.get(titles, id)
  defp slot_recipe_title(_, _), do: nil

  defp slot_status(nil), do: :empty
  defp slot_status(%{reason: "eating_out"}), do: :eating_out
  defp slot_status(%{recipe_id: nil}), do: :empty
  defp slot_status(%{skipped: true}), do: :skipped
  defp slot_status(_slot), do: :assigned
end
