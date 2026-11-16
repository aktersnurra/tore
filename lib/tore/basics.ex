defmodule Tore.Basics do
  @moduledoc """
  What the household buys regularly beyond its dinners, so the week's list and its estimate cover
  the whole shop. No model is asked.

  A basic is learned from what was bought: an ingredient ticked off a list or on a receipt line in
  three or more of the last twelve weeks, in weeks whose dinners didn't call for it. Its interval is
  the median gap between those weeks. Or someone asks for one ("we have milk and cereal for
  breakfast"), and it's due every week.

  A basic is due in a week when it was last bought its interval ago or more, and is then added to
  the list as a basic. Ticking it off records the purchase. Removing it from the list lengthens the
  interval by half; three removals in a row stop it.
  """

  import Ecto.Query

  alias Tore.{Budget, Planning, Recipes, Repo, Scope, Shop, Streams}
  alias Tore.Basics.Basic
  alias Tore.Costs.{LineItem, Receipt}
  alias Tore.Pantry.Match
  alias Tore.Prices.Products
  alias Tore.Recipes.Ingredient

  @history_weeks 12
  @min_weeks 3
  @stop_after 3
  @asked_interval 7

  @type item :: %{name: String.t(), quantity: Decimal.t() | nil, unit: String.t() | nil}

  @doc "The basics that aren't stopped, each with its ingredient's name."
  @spec list(Scope.t()) :: [%{basic: Basic.t(), name: String.t()}]
  def list(%Scope{} = scope) do
    from(b in Basic,
      join: i in Ingredient,
      on: i.id == b.ingredient_id,
      where: not b.stopped,
      order_by: i.name,
      select: %{basic: b, name: i.name}
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  @doc "The basics due in the week starting `week_start`."
  @spec due(Scope.t(), Date.t()) :: [%{basic: Basic.t(), name: String.t()}]
  def due(%Scope{} = scope, %Date{} = week_start) do
    week_end = Date.add(week_start, 6)

    Enum.filter(list(scope), fn %{basic: b} ->
      b.last_bought == nil or
        Date.compare(Date.add(b.last_bought, b.interval_days), week_end) != :gt
    end)
  end

  @doc "The due basics as lines to price (`Tore.Prices.cost/2`); one item when no amount is known."
  @spec lines(Scope.t(), Date.t()) :: [Tore.Prices.line()]
  def lines(%Scope{} = scope, %Date{} = week_start) do
    for %{basic: b} <- due(scope, week_start),
        do: %{
          ingredient_id: b.ingredient_id,
          quantity: b.quantity || Decimal.new(1),
          unit: b.unit
        }
  end

  @doc "The due basics as list items, marked as basics."
  @spec items(Scope.t(), Date.t()) :: [map()]
  def items(%Scope{} = scope, %Date{} = week_start) do
    for %{basic: b, name: name} <- due(scope, week_start),
        do: %{name: name, quantity: b.quantity, unit: b.unit, basic: true}
  end

  @doc """
  Adds basics someone asked for, due every week. An unknown name becomes a new ingredient. A basic
  that was stopped starts again.
  """
  @spec ask(Scope.t(), [item()]) :: :ok
  def ask(%Scope{} = scope, items) do
    for %{name: name} = item <- items, %Ingredient{} = ingredient <- [ingredient(scope, name)] do
      upsert(
        scope,
        %{
          ingredient_id: ingredient.id,
          interval_days: @asked_interval,
          source: :asked,
          quantity: item[:quantity],
          unit: item[:unit],
          removals: 0,
          stopped: false
        },
        [:interval_days, :source, :quantity, :unit, :removals, :stopped]
      )
    end

    :ok
  end

  @doc "Stops the basic named `name`, if there is one."
  @spec stop(Scope.t(), String.t()) :: :ok
  def stop(%Scope{} = scope, name) do
    with {:ok, %Ingredient{id: id}} <- Match.ingredient(scope, {:name, name}) do
      Repo.update_all(
        from(b in Basic, where: b.ingredient_id == ^id),
        [set: [stopped: true]],
        Scope.repo_opts(scope)
      )
    end

    :ok
  end

  @doc "Records that `names` were bought on `date`: a basic among them is due again from then."
  @spec bought(Scope.t(), [String.t()], Date.t()) :: :ok
  def bought(%Scope{} = scope, names, %Date{} = date) do
    ids =
      for name <- names,
          {:ok, %Ingredient{id: id}} <- [Match.ingredient(scope, {:name, name})],
          do: id

    Repo.update_all(
      from(b in Basic, where: b.ingredient_id in ^ids),
      [set: [last_bought: date, removals: 0]],
      Scope.repo_opts(scope)
    )

    :ok
  end

  @doc "A basic taken off the list: its interval grows by half, and three in a row stop it."
  @spec removed(Scope.t(), String.t()) :: :ok
  def removed(%Scope{} = scope, name) do
    with {:ok, %Ingredient{id: id}} <- Match.ingredient(scope, {:name, name}),
         %Basic{} = basic <- Repo.get_by(Basic, [ingredient_id: id], Scope.repo_opts(scope)) do
      basic
      |> Ecto.Changeset.change(
        interval_days: round(basic.interval_days * 1.5),
        removals: basic.removals + 1,
        stopped: basic.removals + 1 >= @stop_after
      )
      |> Repo.update!()
    end

    :ok
  end

  @doc """
  Learns basics from the last #{@history_weeks} weeks of ticks and receipt lines, up to `today`.
  A basic already known keeps its interval, removals and whether it's stopped; only when it was
  last bought moves.
  """
  @spec learn(Scope.t(), Date.t()) :: :ok
  def learn(%Scope{} = scope, %Date{} = today) do
    weeks = for n <- 0..(@history_weeks - 1), do: Date.add(Streams.monday(today), -7 * n)

    planned = Map.new(weeks, &{&1, planned_ingredients(scope, &1)})

    (ticked(scope, weeks) ++ paid(scope, List.last(weeks)))
    |> Enum.reject(fn p -> MapSet.member?(Map.get(planned, p.week, MapSet.new()), p.id) end)
    |> Enum.group_by(& &1.id)
    |> Enum.each(fn {id, purchases} ->
      bought_weeks = purchases |> Enum.map(& &1.week) |> Enum.uniq() |> Enum.sort(Date)
      latest = Enum.max_by(purchases, & &1.date, Date)

      if length(bought_weeks) >= @min_weeks do
        upsert(
          scope,
          %{
            ingredient_id: id,
            interval_days: median_gap(bought_weeks),
            source: :learned,
            quantity: latest.quantity,
            unit: latest.unit,
            last_bought: latest.date
          },
          [:last_bought]
        )
      end
    end)
  end

  # What each week's list had ticked off, by ingredient.
  defp ticked(scope, weeks) do
    for week <- weeks,
        {:ok, list} = Shop.load_list(scope, Streams.shop_list(scope, week)),
        %{checked: true} = item <- Map.values(list.items),
        {:ok, %Ingredient{id: id}} <- [Match.ingredient(scope, {:name, item.name})],
        do: %{
          id: id,
          week: week,
          date: week,
          quantity: Tore.Types.decimal(item.quantity),
          unit: item.unit
        }
  end

  defp paid(scope, from) do
    lines =
      from(l in LineItem,
        join: r in Receipt,
        on: r.id == l.receipt_id,
        where: r.week_start >= ^from,
        select: {l.product_name, r.week_start, r.date, l.quantity, l.unit}
      )
      |> Repo.all(Scope.repo_opts(scope))

    matches = Products.lookup(scope, Enum.map(lines, &elem(&1, 0)))

    for {name, week, date, quantity, unit} <- lines,
        id = Map.get(matches, Ingredient.to_key(name)),
        id != nil,
        do: %{id: id, week: week, date: date, quantity: quantity, unit: unit}
  end

  defp planned_ingredients(scope, week) do
    {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week))

    for recipe <- Recipes.get_many(scope, plan |> Budget.meals() |> Enum.map(&elem(&1, 0))),
        ri <- recipe.recipe_ingredients,
        into: MapSet.new(),
        do: ri.ingredient_id
  end

  defp median_gap(weeks) do
    gaps =
      weeks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> Date.diff(b, a) end)
      |> Enum.sort()

    Enum.at(gaps, div(length(gaps) - 1, 2))
  end

  defp ingredient(scope, name) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, ingredient} ->
        ingredient

      :unknown ->
        if Ingredient.to_key(name) != "" do
          %Ingredient{household_id: scope.household_id}
          |> Ingredient.changeset(%{name: String.trim(name)})
          |> Repo.insert!()
        end
    end
  end

  defp upsert(scope, attrs, replace) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert!(
      struct(
        Basic,
        Map.merge(attrs, %{household_id: scope.household_id, inserted_at: now, updated_at: now})
      ),
      on_conflict: {:replace, [:updated_at | replace]},
      conflict_target: [:household_id, :ingredient_id]
    )
  end
end
