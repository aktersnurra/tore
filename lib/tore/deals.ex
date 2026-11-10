defmodule Tore.Deals do
  require Logger
  alias Tore.{Alerts, Household, Repo, Scope}
  alias Tore.Deals.{Deal, HouseholdStore, Parsers, Store}
  import Ecto.Query

  @http Application.compile_env(:tore, :http_client)

  @spec upsert_deals([map()]) :: {:ok, integer()} | {:error, term()}
  def upsert_deals(deals) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      deals
      |> Enum.filter(
        &(not is_nil(&1[:store]) and not is_nil(&1[:product_name]) and not is_nil(&1[:chain]))
      )
      |> Enum.map(fn d ->
        d
        |> Map.put_new(:source, :scraped)
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    {count, _} =
      Repo.insert_all(Deal, rows,
        on_conflict: :nothing,
        conflict_target: [:chain, :store, :product_name]
      )

    {:ok, count}
  end

  @doc "Current deals at the stores the household uses and has switched on."
  @spec list_current(Scope.t()) :: [Deal.t()]
  def list_current(%Scope{} = scope) do
    today = Date.utc_today()

    from(d in Deal,
      join: s in Store,
      on: s.name == d.store,
      join: hs in HouseholdStore,
      on: hs.store_id == s.id and hs.scrape_enabled,
      where: is_nil(d.valid_until) or d.valid_until >= ^today,
      distinct: true
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  @spec clear_expired() :: :ok
  def clear_expired do
    today = Date.utc_today()
    week_start_dt = today |> Date.beginning_of_week() |> NaiveDateTime.new!(~T[00:00:00])

    Repo.delete_all(
      from d in Deal,
        where:
          (not is_nil(d.valid_until) and d.valid_until < ^today) or
            (is_nil(d.valid_until) and d.inserted_at < ^week_start_dt)
    )

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

  @doc "Fetches each store some household has switched on, once however many households use it."
  @spec scrape_all() :: :ok
  def scrape_all do
    Household.list_ids()
    |> Enum.flat_map(&switched_on_stores(Scope.for_household(&1)))
    |> Enum.uniq_by(& &1.id)
    |> Enum.each(&scrape_store/1)
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
    end
  end
end
