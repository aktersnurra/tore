defmodule Tore.Deals do
  require Logger
  alias Tore.{Alerts, Repo, Deals.Deal, Deals.Parsers, Deals.StoreConfig}
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

  @spec list_current() :: [Deal.t()]
  def list_current do
    today = Date.utc_today()
    Repo.all(from d in Deal, where: is_nil(d.valid_until) or d.valid_until >= ^today)
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

  @spec list_store_configs() :: [StoreConfig.t()]
  def list_store_configs, do: Repo.all(StoreConfig)

  @doc "Adds a store from just its link, switched on. The backend supplies its name."
  @spec add_store(String.t()) ::
          {:ok, StoreConfig.t()} | {:error, :unsupported_store | Ecto.Changeset.t()}
  def add_store(url) do
    url = String.trim(url)

    with {:ok, parser} <- Parsers.for_url(url),
         {:ok, name} <- parser.store_name(URI.parse(url)) do
      %StoreConfig{}
      |> StoreConfig.changeset(%{url: url, name: name, scrape_enabled: true})
      |> Repo.insert()
    end
  end

  @spec update_store_config(StoreConfig.t(), map()) ::
          {:ok, StoreConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_store_config(config, attrs) do
    config
    |> StoreConfig.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_store_config(StoreConfig.t()) ::
          {:ok, StoreConfig.t()} | {:error, Ecto.Changeset.t()}
  def delete_store_config(config), do: Repo.delete(config)

  @spec get_store_config!(integer()) :: StoreConfig.t()
  def get_store_config!(id), do: Repo.get!(StoreConfig, id)

  @spec scrape_all() :: :ok
  def scrape_all do
    StoreConfig
    |> Repo.all()
    |> Enum.filter(& &1.scrape_enabled)
    |> Enum.each(&scrape_store/1)

    :ok
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

  @spec parse_pdf(binary()) :: {:ok, integer()} | {:error, term()}
  def parse_pdf(pdf_binary) do
    {system, user} = Tore.LLM.Prompts.parse_deals_pdf()

    with {:ok, data, _usage} <-
           Tore.LLM.vision([{:pdf, pdf_binary}], system, user, []) do
      raw_deals =
        cond do
          is_list(data) -> data
          is_map(data) -> data["deals"] || []
          true -> []
        end

      deals = Enum.map(raw_deals, &deal_from_raw/1)

      case deals do
        [] ->
          Logger.warning("PDF parse returned 0 deals")
          {:ok, 0}

        _ ->
          upsert_deals(deals)
      end
    end
  end

  defp deal_from_raw(d) do
    %{
      chain: d["chain"] || "other",
      store: d["store"] || d["chain"] || "other",
      product_name: d["product_name"],
      brand: d["brand"],
      size: d["size"],
      price: deals_decimal(d["price"]),
      price_unit: d["price_unit"],
      offer_condition: d["offer_condition"],
      regular_price: d["regular_price"],
      comparison_price: d["comparison_price"],
      valid_from: deals_date(d["valid_from"]),
      valid_until: deals_date(d["valid_until"]),
      source: :vision
    }
  end

  defp deals_decimal(nil), do: nil
  defp deals_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp deals_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp deals_date(nil), do: nil

  defp deals_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp scrape_store(store_config) do
    case scrape_url(store_config.url, store_config.name) do
      {:ok, count} ->
        Logger.info("scraped #{count} deals", store: store_config.name, url: store_config.url)

      {:error, reason} ->
        Logger.error("scrape failed",
          store: store_config.name,
          url: store_config.url,
          reason: inspect(reason)
        )
    end
  end
end
