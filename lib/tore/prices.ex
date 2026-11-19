defmodule Tore.Prices do
  @moduledoc """
  What an ingredient costs, and so what a recipe and a week cost. Derived every time from stored
  facts, never stored itself.

  An ingredient's price is the first that fits of:

  1. a deal still running in the week, matched to it (`Tore.Prices.Products`)
  2. the latest price paid for it on a receipt from before the week
  3. the latest regular price seen on a deal
  4. the model's estimate, kept on the ingredient

  A source fits when it has a price in the line's unit family (kg, l or st, `Tore.Prices.Units`):
  400 g of chicken takes a per-kg price, 3 onions a per-item one. Only the first three count as
  priced in the coverage figure; an estimate adds to the amount but not to the count.
  """

  import Ecto.Query

  alias Tore.{Deals, Repo, Scope}
  alias Tore.Costs.{LineItem, Receipt}
  alias Tore.Deals.{Deal, HouseholdStore, Store}
  alias Tore.Prices.{Products, Units}
  alias Tore.Recipes.{Ingredient, Recipe}

  @sources [:deal, :paid, :regular, :estimate]
  @measured [:deal, :paid, :regular]

  @typedoc "One source's prices for an ingredient, per base unit: `%{\"kg\" => 89.50}`."
  @type forms :: %{Units.base() => Decimal.t()}
  @type prices :: %{integer() => %{atom() => forms()}}
  @type line :: %{ingredient_id: integer(), quantity: Decimal.t() | nil, unit: String.t() | nil}
  @type cost :: %{amount: Decimal.t(), priced: non_neg_integer(), total: non_neg_integer()}

  @doc """
  Every source's prices for `ingredient_ids` in the week starting `week_start`, from offers and
  receipts Tore had by `as_of` (a UTC moment). The model's estimates have no history and are read
  as they stand.
  """
  @spec for_ingredients(Scope.t(), [integer()], Date.t(), NaiveDateTime.t()) :: prices()
  def for_ingredients(
        %Scope{} = scope,
        ingredient_ids,
        %Date{} = week_start,
        as_of \\ NaiveDateTime.utc_now()
      ) do
    ids = MapSet.new(ingredient_ids)

    [
      deal: deal_prices(scope, week_start, as_of),
      paid: paid_prices(scope, week_start, as_of),
      regular: regular_prices(scope, week_start, as_of),
      estimate: estimates(scope, ingredient_ids)
    ]
    |> Enum.reduce(%{}, fn {source, by_ingredient}, acc ->
      by_ingredient
      |> Enum.filter(fn {id, _} -> MapSet.member?(ids, id) end)
      |> Enum.reduce(acc, fn {id, forms}, acc ->
        Map.update(acc, id, %{source => forms}, &Map.put(&1, source, forms))
      end)
    end)
  end

  @doc """
  What `lines` cost at `prices`. Pure. A line without a quantity, or with no price that fits, is
  unpriced and adds nothing.
  """
  @spec cost([line()], prices()) :: cost()
  def cost(lines, prices) do
    Enum.reduce(lines, %{amount: Decimal.new(0), priced: 0, total: 0}, fn line, acc ->
      acc = %{acc | total: acc.total + 1}

      case line_cost(line, Map.get(prices, line.ingredient_id, %{})) do
        {source, amount} ->
          %{
            acc
            | amount: Decimal.add(acc.amount, amount),
              priced: acc.priced + if(source in @measured, do: 1, else: 0)
          }

        :unpriced ->
          acc
      end
    end)
    |> Map.update!(:amount, &Decimal.round(&1, 2))
  end

  @doc "The source and cost of one line, or `:unpriced`."
  @spec line_cost(line(), %{atom() => forms()}) :: {atom(), Decimal.t()} | :unpriced
  def line_cost(%{quantity: nil}, _sources), do: :unpriced

  def line_cost(%{quantity: quantity, unit: unit}, sources) do
    with {amount, base} <- Units.to_base(quantity, unit),
         {source, price} <-
           Enum.find_value(@sources, fn source ->
             case Map.get(sources, source) do
               %{^base => price} -> {source, price}
               _ -> nil
             end
           end) do
      {source, Decimal.mult(amount, price)}
    else
      _ -> :unpriced
    end
  end

  @doc """
  The lines of `recipe` (ingredients preloaded) for `servings`, scaled from its own servings.
  """
  @spec lines(Recipe.t(), pos_integer() | nil) :: [line()]
  def lines(%Recipe{} = recipe, servings) do
    factor =
      case {recipe.base_servings, servings} do
        {base, wanted} when is_integer(base) and base > 0 and is_integer(wanted) ->
          Decimal.div(wanted, base)

        _ ->
          Decimal.new(1)
      end

    for ri <- recipe.recipe_ingredients do
      %{
        ingredient_id: ri.ingredient_id,
        quantity: ri.quantity && Decimal.mult(ri.quantity, factor),
        unit: ri.unit
      }
    end
  end

  @doc "What each of `recipes` (ingredients preloaded) costs for `servings` in the week."
  @spec recipe_costs(Scope.t(), [{Recipe.t(), pos_integer() | nil}], Date.t()) ::
          %{integer() => cost()}
  def recipe_costs(%Scope{} = scope, recipes, %Date{} = week_start) do
    ids = for {recipe, _} <- recipes, ri <- recipe.recipe_ingredients, do: ri.ingredient_id
    prices = for_ingredients(scope, ids, week_start)

    Map.new(recipes, fn {recipe, servings} ->
      {recipe.id, cost(lines(recipe, servings), prices)}
    end)
  end

  @doc "Adds costs together."
  @spec sum([cost()]) :: cost()
  def sum(costs) do
    Enum.reduce(costs, %{amount: Decimal.new(0), priced: 0, total: 0}, fn c, acc ->
      %{
        amount: Decimal.add(acc.amount, c.amount),
        priced: acc.priced + c.priced,
        total: acc.total + c.total
      }
    end)
  end

  # ---- Sources ---------------------------------------------------------------

  # The cheapest offer per unit among the deals running in the week.
  defp deal_prices(scope, week_start, as_of) do
    scope
    |> Deals.valid_in_week(week_start, as_of)
    |> by_ingredient(scope, & &1.product_name, &deal_forms/1)
    |> Map.new(fn {id, forms} -> {id, Enum.reduce(forms, &cheapest/2)} end)
  end

  defp deal_forms(%Deal{} = deal) do
    forms([
      {Deal.unit_price(deal), deal.price_unit},
      {deal.comparison_price, deal.comparison_unit}
    ])
  end

  # The latest line per ingredient that says what it cost and how much it was, from receipts
  # counted towards earlier weeks: a week's estimate never learns from its own receipts, a
  # weekend shop for it included, so it can be worked out again later and compared with what was
  # paid.
  defp paid_prices(scope, week_start, as_of) do
    from(l in LineItem,
      join: r in Receipt,
      on: r.id == l.receipt_id,
      where:
        not is_nil(l.total_price) and l.quantity > 0 and r.week_start < ^week_start and
          r.inserted_at <= ^as_of,
      order_by: [desc: r.date, desc: l.id],
      limit: 500,
      select: l
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> by_ingredient(scope, & &1.product_name, &paid_forms/1)
    |> Map.new(fn {id, [latest | _]} -> {id, latest} end)
  end

  defp paid_forms(%LineItem{} = line) do
    case Units.to_base(line.quantity, line.unit) do
      {amount, base} -> %{base => Decimal.div(line.total_price, amount)}
      :unknown -> %{}
    end
  end

  # The latest regular price per ingredient, from any offer the household's stores had seen by
  # the week's end, and by `as_of`. It is per the offer's unit; the comparison price scales by the
  # same discount.
  defp regular_prices(scope, week_start, as_of) do
    seen_by = Deals.week_end(week_start)

    from(d in Deal,
      join: s in Store,
      on: s.name == d.store,
      join: hs in HouseholdStore,
      on: hs.store_id == s.id,
      where: not is_nil(d.regular_price) and d.inserted_at < ^seen_by and d.inserted_at <= ^as_of,
      order_by: [desc: d.valid_until],
      distinct: true
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> by_ingredient(scope, & &1.product_name, &regular_forms/1)
    |> Map.new(fn {id, [latest | _]} -> {id, latest} end)
  end

  defp regular_forms(%Deal{} = deal) do
    unit_price = Deal.unit_price(deal)

    comparison =
      if deal.comparison_price && unit_price && Decimal.gt?(unit_price, 0),
        do: deal.comparison_price |> Decimal.mult(deal.regular_price) |> Decimal.div(unit_price)

    forms([{deal.regular_price, deal.price_unit || "st"}, {comparison, deal.comparison_unit}])
  end

  defp estimates(scope, ingredient_ids) do
    from(i in Ingredient,
      where: i.id in ^ingredient_ids and not is_nil(i.estimated_price),
      select: {i.id, i.estimated_price, i.estimated_unit}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Map.new(fn {id, price, unit} -> {id, forms([{price, unit}])} end)
  end

  # Rows grouped by the ingredient their product matched, in order, each turned into its forms.
  defp by_ingredient(rows, scope, name, to_forms) do
    matches = Products.lookup(scope, Enum.map(rows, name))

    rows
    |> Enum.flat_map(fn row ->
      case Map.get(matches, Ingredient.to_key(name.(row))) do
        nil -> []
        id -> [{id, to_forms.(row)}]
      end
    end)
    |> Enum.reject(fn {_, forms} -> forms == %{} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # A price of `amount` per one `unit`, as a price per base unit.
  defp forms(pairs) do
    for {%Decimal{} = amount, unit} <- pairs,
        unit != nil,
        {one, base} <- [Units.to_base(Decimal.new(1), unit)],
        into: %{},
        do: {base, Decimal.div(amount, one)}
  end

  defp cheapest(a, b), do: Map.merge(a, b, fn _, x, y -> Decimal.min(x, y) end)
end
