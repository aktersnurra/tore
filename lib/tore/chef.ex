defmodule Tore.Chef do
  @moduledoc """
  The chef on Today, who grows as the household cooks. A dinner marked Done is a step, and one
  that used food at, near or past its best-before is two. Steps only add up: nothing takes them
  away, and a week without cooking leaves the chef as it is. Undoing Done takes its dinner back.
  """

  import Ecto.Query

  alias Tore.Chef.CookedDinner
  alias Tore.Pantry.PantryItem
  alias Tore.{Repo, Scope}

  @typedoc "Where the chef is on the ladder."
  @type stage :: :dishwasher | :apprentice | :cook | :sous_chef | :head_chef

  # Each stage and the steps it starts at.
  @ladder [dishwasher: 0, apprentice: 8, cook: 25, sous_chef: 60, head_chef: 120]
  # After the last stage, a thing in the kitchen every so many steps, up to so many.
  @extra_every 40
  @extras 6
  # Food used this many days before its best-before, or after it, was rescued.
  @near_days 2

  @doc """
  A dinner cooked now, of `recipe_id`, that took the pantry rows in `used` (`Pantry.use_up/2`'s
  result, or anything with their `id`s).
  """
  @spec cooked(Scope.t(), integer(), [%{id: integer()}]) :: {:ok, CookedDinner.t()}
  def cooked(%Scope{} = scope, recipe_id, used) do
    today = Tore.Clock.today()
    ids = Enum.map(used, & &1.id)

    rescued =
      from(p in PantryItem,
        where: p.id in ^ids and not is_nil(p.expires_at),
        where: p.expires_at <= ^Date.add(today, @near_days)
      )
      |> Repo.exists?(Scope.repo_opts(scope))

    {:ok,
     Repo.insert!(%CookedDinner{
       household_id: scope.household_id,
       recipe_id: recipe_id,
       cooked_on: today,
       rescued: rescued
     })}
  end

  @doc "Done undone: its dinner no longer counts."
  @spec uncooked(Scope.t(), CookedDinner.t()) :: :ok
  def uncooked(%Scope{} = scope, %CookedDinner{id: id}) do
    from(d in CookedDinner, where: d.id == ^id) |> Repo.delete_all(Scope.repo_opts(scope))
    :ok
  end

  @night 22
  @morning 6
  @coffee_until 9
  @dinner_from 16

  @doc """
  What the chef is doing on Today, from the hour and the day: asleep at night; then what's needed
  first (the list when something must be bought for tonight, the stove at dinner time); else
  coffee in the morning, or just himself.
  """
  @spec today_scene(%{
          hour: 0..23,
          cooked: boolean(),
          to_buy: boolean(),
          dinner_tonight: boolean()
        }) :: :sleep | :list | :stove | :morning | :chef
  def today_scene(%{hour: hour}) when hour >= @night or hour < @morning, do: :sleep
  def today_scene(%{cooked: true}), do: :chef
  def today_scene(%{to_buy: true}), do: :list
  def today_scene(%{dinner_tonight: true, hour: hour}) when hour >= @dinner_from, do: :stove
  def today_scene(%{hour: hour}) when hour < @coffee_until, do: :morning
  def today_scene(_day), do: :chef

  @doc "The household's chef: dinners cooked, how many rescued food, and the stage they reach."
  @spec now(Scope.t()) :: map()
  def now(%Scope{} = scope) do
    {dinners, rescued} =
      from(d in CookedDinner,
        select:
          {count(d.id), coalesce(sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", d.rescued)), 0)}
      )
      |> Repo.one(Scope.repo_opts(scope))

    steps = dinners + rescued
    Map.merge(%{dinners: dinners, rescued: rescued, steps: steps}, stage(steps))
  end

  @doc """
  The stage `steps` reach, the things in the kitchen past the last one, and what's next with how
  many steps left (`nil` once the kitchen is full).
  """
  @spec stage(non_neg_integer()) :: %{
          stage: stage(),
          extras: 0..6,
          next: %{stage: stage() | :extra, left: pos_integer()} | nil
        }
  def stage(steps) do
    {stage, _at} = @ladder |> Enum.filter(fn {_stage, at} -> steps >= at end) |> List.last()

    case Enum.find(@ladder, fn {_stage, at} -> at > steps end) do
      {next, at} ->
        %{stage: stage, extras: 0, next: %{stage: next, left: at - steps}}

      nil ->
        past = steps - @ladder[:head_chef]
        extras = min(div(past, @extra_every), @extras)

        next =
          if extras < @extras, do: %{stage: :extra, left: @extra_every - rem(past, @extra_every)}

        %{stage: stage, extras: extras, next: next}
    end
  end
end
