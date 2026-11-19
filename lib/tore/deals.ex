defmodule Tore.Deals do
  require Logger
  alias Tore.{Alerts, Basics, Household, Repo, Scope, Shop, Streams}
  alias Tore.Deals.{Deal, HouseholdStore, Parsers, Store}
  alias Tore.Prices.Products
  alias Tore.Recipes.Ingredient
  import Ecto.Query

  @http Application.compile_env(:tore, :http_client)

  @doc """
  Stores offers, each week's as its own row. An offer without an end date is taken to run to
  Sunday, as ICA's do. The same offer seen again is left as it is.
  """
  @spec upsert_deals([map()]) :: {:ok, integer()} | {:error, term()}
  def upsert_deals(deals) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    sunday = Tore.Clock.today() |> Streams.monday() |> Date.add(6)

    rows =
      deals
      |> Enum.filter(
        &(not is_nil(&1[:store]) and not is_nil(&1[:product_name]) and not is_nil(&1[:chain]))
      )
      |> Enum.map(fn d ->
        d
        |> Map.put_new(:source, :scraped)
        |> Map.update(:valid_until, sunday, &(&1 || sunday))
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    {count, _} =
      Repo.insert_all(Deal, rows,
        on_conflict: :nothing,
        conflict_target: [:chain, :store, :product_name, :valid_until]
      )

    {:ok, count}
  end

  @doc "Current deals at the stores the household uses and has switched on."
  @spec list_current(Scope.t()) :: [Deal.t()]
  def list_current(%Scope{} = scope), do: scope |> valid_from(Tore.Clock.today()) |> all(scope)

  @doc """
  The deals that can count for the week starting `week_start`: those still running on its Monday
  or later and seen before it ended, at the stores the household uses and has switched on. A past
  week is priced as it was, never from offers that came later.
  """
  @spec valid_in_week(Scope.t(), Date.t()) :: [Deal.t()]
  def valid_in_week(%Scope{} = scope, %Date{} = week_start) do
    seen_by = week_end(week_start)
    scope |> valid_from(week_start) |> where([d], d.inserted_at < ^seen_by) |> all(scope)
  end

  @doc "The moment the week starting `week_start` ends: the next Monday at midnight."
  @spec week_end(Date.t()) :: NaiveDateTime.t()
  def week_end(%Date{} = week_start),
    do: NaiveDateTime.new!(Date.add(week_start, 7), ~T[00:00:00])

  defp valid_from(_scope, date) do
    from(d in Deal,
      join: s in Store,
      on: s.name == d.store,
      join: hs in HouseholdStore,
      on: hs.store_id == s.id and hs.scrape_enabled,
      where: d.valid_until >= ^date,
      distinct: true
    )
  end

  defp all(query, scope), do: Repo.all(query, Scope.repo_opts(scope))

  @typedoc """
  A deal on the page: `name` is what + puts on the list (the ingredient's name when the product
  is matched to one), `saving` what it saves over the regular price, `dinner` the title of the
  dinner that calls for it.
  """
  @type entry :: %{
          deal: Deal.t(),
          name: String.t(),
          saving: Decimal.t() | nil,
          dinner: String.t() | nil,
          on_list?: boolean()
        }

  @doc """
  The Erbjudanden page for the week starting `week_start`, as of `today`. Current deals in three
  groups, with no model: those a dinner from today on calls for, those on something the household
  usually buys (`Tore.Basics`), and the rest. `saving` is what the first two save together, the
  best deal per ingredient; `stores` the household's stores with their deals counted.
  """
  @spec page(Scope.t(), Date.t(), Date.t()) :: %{
          dinners: [entry()],
          usual: [entry()],
          others: [entry()],
          saving: Decimal.t(),
          stores: [%{store: HouseholdStore.t(), deals: non_neg_integer()}]
        }
  def page(%Scope{} = scope, %Date{} = week_start, %Date{} = today) do
    deals = list_current(scope)
    matches = Products.lookup(scope, Enum.map(deals, & &1.product_name))

    ingredients =
      from(i in Ingredient, where: i.id in ^(matches |> Map.values() |> Enum.reject(&is_nil/1)))
      |> Repo.all(Scope.repo_opts(scope))
      |> Map.new(&{&1.id, &1})

    dinners = Shop.dinners_for(scope, week_start, today)
    basics = MapSet.new(Basics.list(scope), & &1.basic.ingredient_id)
    list_id = Streams.shop_list(scope, week_start)

    entries =
      Enum.map(deals, fn deal ->
        ingredient = ingredients[matches[Ingredient.to_key(deal.product_name)]]

        %{
          deal: deal,
          ingredient: ingredient,
          name: if(ingredient, do: ingredient.name, else: deal.product_name),
          saving: saving(deal),
          dinner: ingredient && dinners[ingredient.key][:title]
        }
      end)

    names = Enum.map(entries, & &1.name)
    missing = MapSet.new(Shop.not_on_list(scope, list_id, names))
    entries = Enum.map(entries, &Map.put(&1, :on_list?, not MapSet.member?(missing, &1.name)))

    {for_dinners, rest} = Enum.split_with(entries, & &1.dinner)

    {usual, others} =
      Enum.split_with(rest, &(&1.ingredient && MapSet.member?(basics, &1.ingredient.id)))

    counts = Enum.frequencies_by(deals, & &1.store)

    %{
      dinners: sorted(for_dinners),
      usual: sorted(usual),
      others: sorted(others),
      saving: best_per_ingredient(for_dinners ++ usual),
      stores:
        for(hs <- list_stores(scope), do: %{store: hs, deals: Map.get(counts, hs.store.name, 0)})
    }
  end

  # What the offer saves over buying its quantity at the regular price, when both are known.
  defp saving(%Deal{price: price, regular_price: regular, quantity: quantity})
       when not is_nil(price) and not is_nil(regular) do
    saved = regular |> Decimal.mult(quantity) |> Decimal.sub(price)
    if Decimal.gt?(saved, 0), do: saved
  end

  defp saving(_deal), do: nil

  # Biggest saving first, then by name; deals without a known saving last.
  defp sorted(entries) do
    entries
    |> Enum.sort_by(&{is_nil(&1.saving), -Decimal.to_float(&1.saving || Decimal.new(0)), &1.name})
    |> Enum.map(&Map.delete(&1, :ingredient))
  end

  # Two offers on one ingredient, say this week's and next week's, are one saving, not two.
  defp best_per_ingredient(entries) do
    entries
    |> Enum.filter(& &1.saving)
    |> Enum.group_by(& &1.ingredient.id, & &1.saving)
    |> Enum.map(fn {_id, savings} -> Enum.max(savings, Decimal) end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @history_days 26 * 7

  @doc "Deletes offers that ended more than half a year ago. Newer ones are the price history."
  @spec clear_expired() :: :ok
  def clear_expired do
    cutoff = Date.add(Tore.Clock.today(), -@history_days)
    Repo.delete_all(from d in Deal, where: d.valid_until < ^cutoff)
    :ok
  end

  @doc "The stores the household uses, oldest first, each with its `store` loaded."
  @spec list_stores(Scope.t()) :: [HouseholdStore.t()]
  def list_stores(%Scope{} = scope) do
    from(hs in HouseholdStore, order_by: hs.id, preload: :store)
    |> Repo.all(Scope.repo_opts(scope))
  end

  @doc """
  Adds a store from just its link, switched on. The backend supplies its name. A store another
  household already uses is shared rather than added twice.
  """
  @spec add_store(Scope.t(), String.t()) ::
          {:ok, HouseholdStore.t()} | {:error, :unsupported_store | Ecto.Changeset.t()}
  def add_store(%Scope{} = scope, url) do
    url = String.trim(url)

    with {:ok, parser} <- Parsers.for_url(url),
         uri = URI.parse(url),
         {:ok, name} <- parser.store_name(uri) do
      url = parser.canonical_url(uri)

      Repo.transaction(fn ->
        store =
          Repo.get_by(Store, url: url) ||
            Repo.insert!(Store.changeset(%Store{}, %{url: url, name: name}))

        %HouseholdStore{household_id: scope.household_id, store_id: store.id}
        |> HouseholdStore.changeset(%{})
        |> Repo.insert()
        |> case do
          {:ok, household_store} -> %{household_store | store: store}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "Switches fetching the store's offers on or off for the household."
  @spec toggle_scraping(Scope.t(), integer()) ::
          {:ok, HouseholdStore.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def toggle_scraping(%Scope{} = scope, id) do
    case Repo.get(HouseholdStore, id, Scope.repo_opts(scope)) do
      nil ->
        {:error, :not_found}

      household_store ->
        household_store
        |> HouseholdStore.changeset(%{scrape_enabled: !household_store.scrape_enabled})
        |> Repo.update()
    end
  end

  @doc "Stops the household using the store. The store stays for any other household using it."
  @spec remove_store(Scope.t(), integer()) ::
          {:ok, HouseholdStore.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def remove_store(%Scope{} = scope, id) do
    case Repo.get(HouseholdStore, id, Scope.repo_opts(scope)) do
      nil -> {:error, :not_found}
      household_store -> Repo.delete(household_store)
    end
  end

  @doc """
  Fetches each store some household has switched on, once however many households use it, unless
  its offers for the week after `today`'s are already in (`coming_week?/2`).
  """
  @spec scrape_all(Date.t()) :: :ok
  def scrape_all(%Date{} = today \\ Tore.Clock.today()) do
    scopes = Enum.map(Household.list_ids(), &Scope.for_household/1)

    scopes
    |> Enum.flat_map(&switched_on_stores/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&coming_week?(&1, today))
    |> Enum.each(&scrape_store/1)

    Enum.each(scopes, &match_products/1)
  end

  @doc """
  Whether every store the household has switched on has its offers for the week after `today`'s.
  True with no stores, as nothing is coming.
  """
  @spec coming_week_in?(Scope.t(), Date.t()) :: boolean()
  def coming_week_in?(%Scope{} = scope, %Date{} = today),
    do: scope |> switched_on_stores() |> Enum.all?(&coming_week?(&1, today))

  # A store's coming week is in when most of the offers its latest fetch this week added run past
  # this Sunday. A fetch adds its offers with one timestamp, so the latest timestamp is its batch. Fetching starts on Friday, so this week's own offers are first seen this week
  # too; a few of them running longer mustn't count, which is why it's most, not any.
  defp coming_week?(%Store{name: name}, today) do
    monday = Streams.monday(today)
    sunday = Date.add(monday, 6)

    added =
      from(d in Deal,
        where: d.store == ^name and d.inserted_at >= ^NaiveDateTime.new!(monday, ~T[00:00:00]),
        select: {d.inserted_at, d.valid_until}
      )
      |> Repo.all()

    case added do
      [] ->
        false

      added ->
        latest = added |> Enum.map(&elem(&1, 0)) |> Enum.max(NaiveDateTime)
        ends = for {^latest, until} <- added, do: until
        Enum.count(ends, &(Date.compare(&1, sunday) == :gt)) * 2 > length(ends)
    end
  end

  # Each household matches the offers it can use to its ingredients, once per product name.
  defp match_products(scope) do
    case list_current(scope) do
      [] -> :ok
      deals -> Products.later(scope, Enum.map(deals, & &1.product_name))
    end
  end

  defp switched_on_stores(scope) do
    from(hs in HouseholdStore, join: s in assoc(hs, :store), where: hs.scrape_enabled, select: s)
    |> Repo.all(Scope.repo_opts(scope))
  end

  @spec scrape_url(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def scrape_url(url, store_name) do
    with {:ok, parser} <- Parsers.for_url(url),
         {:ok, html} <- @http.fetch(url),
         {:ok, deals} <- parser.parse(html) do
      chain = parser.chain()
      deals = Enum.map(deals, &Map.merge(&1, %{store: store_name, chain: chain}))

      case deals do
        [] ->
          Logger.warning("scrape returned 0 deals — parser may be broken",
            url: url,
            chain: chain
          )

          Alerts.scrape_zero_results(url, chain)
          {:ok, 0}

        _ ->
          upsert_deals(deals)
      end
    end
  end

  defp scrape_store(store) do
    case scrape_url(store.url, store.name) do
      {:ok, count} ->
        Logger.info("scraped #{count} deals", store: store.name, url: store.url)

      {:error, reason} ->
        Logger.error("scrape failed",
          store: store.name,
          url: store.url,
          reason: inspect(reason)
        )

        Alerts.scrape_failed(store.url, reason)
    end
  end
end
