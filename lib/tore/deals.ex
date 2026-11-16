defmodule Tore.Deals do
  require Logger
  alias Tore.{Alerts, Household, Repo, Scope, Streams}
  alias Tore.Deals.{Deal, HouseholdStore, Parsers, Store}
  alias Tore.Prices.Products
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
  def list_current(%Scope{} = scope), do: valid_from(scope, Tore.Clock.today())

  @doc """
  The deals that can count for the week starting `week_start`: those still running on its Monday
  or later, at the stores the household uses and has switched on.
  """
  @spec valid_in_week(Scope.t(), Date.t()) :: [Deal.t()]
  def valid_in_week(%Scope{} = scope, %Date{} = week_start), do: valid_from(scope, week_start)

  defp valid_from(scope, date) do
    from(d in Deal,
      join: s in Store,
      on: s.name == d.store,
      join: hs in HouseholdStore,
      on: hs.store_id == s.id and hs.scrape_enabled,
      where: d.valid_until >= ^date,
      distinct: true
    )
    |> Repo.all(Scope.repo_opts(scope))
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
  Whether every store the household has switched on has its offers for the week after `today`'s:
  offers first seen this week that run past this Sunday. True with no stores, as nothing is coming.
  """
  @spec coming_week_in?(Scope.t(), Date.t()) :: boolean()
  def coming_week_in?(%Scope{} = scope, %Date{} = today),
    do: scope |> switched_on_stores() |> Enum.all?(&coming_week?(&1, today))

  defp coming_week?(%Store{name: name}, today) do
    monday = Streams.monday(today)
    since = NaiveDateTime.new!(monday, ~T[00:00:00])

    Repo.exists?(
      from(d in Deal,
        where:
          d.store == ^name and d.valid_until > ^Date.add(monday, 6) and d.inserted_at >= ^since
      )
    )
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
