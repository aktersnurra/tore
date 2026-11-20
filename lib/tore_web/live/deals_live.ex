defmodule ToreWeb.DealsLive do
  @moduledoc """
  Erbjudanden: this week's offers on things the household buys anyway, first what the meals
  call for, then what it usually buys, the rest folded away (ui.md, "Erbjudanden"). Everything is
  read from `Tore.Deals.page/3`; + puts a deal on this week's list.
  """
  use ToreWeb, :live_view

  alias Tore.{Deals, Money, Shop, Streams}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(store_url: "", store_error: nil, adding_store: false) |> load()}

  defp load(socket) do
    today = Tore.Clock.today()
    week = Streams.monday(today)
    page = Deals.page(socket.assigns.current_scope, week, today)
    logos = Map.new(page.stores, &{&1.store.store.name, &1.store.store.logo})
    assign(socket, week: week, page: page, logos: logos)
  end

  # The name comes from the page, not the click, so only a deal shown can be added.
  @impl true
  def handle_event("add", %{"id" => id}, socket) do
    %{page: page, week: week, current_scope: scope} = socket.assigns
    id = String.to_integer(id)

    case Enum.find(page.meals ++ page.usual ++ page.others, &(&1.deal.id == id)) do
      nil ->
        {:noreply, socket}

      entry ->
        user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

        {:ok, _} =
          Shop.add_item(scope, Streams.shop_list(scope, week), entry.name, nil, nil, user_id)

        {:noreply, load(socket)}
    end
  end

  # A store just added is read at once, in the background, and a toast says what came of it.
  def handle_event("add_store", %{"url" => url}, socket) do
    scope = socket.assigns.current_scope

    case Deals.add_store(scope, url) do
      {:ok, household_store} ->
        {:noreply,
         socket
         |> assign(store_url: "", store_error: nil, adding_store: false)
         |> load()
         |> start_async({:read_store, household_store.store.name}, fn ->
           Deals.read_store_now(scope, household_store)
         end)}

      {:error, :unsupported_store} ->
        {:noreply,
         assign(socket, store_url: url, store_error: gettext("Tore can't read that store yet"))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket, store_url: url, store_error: gettext("That store is already added"))}
    end
  end

  def handle_event("open_store_form", _, socket),
    do: {:noreply, assign(socket, adding_store: true)}

  def handle_event("close_store_form", _, socket),
    do: {:noreply, assign(socket, adding_store: false, store_error: nil)}

  def handle_event("toggle_store", %{"id" => id}, socket) do
    _ = Deals.toggle_scraping(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, load(socket)}
  end

  def handle_event("remove_store", %{"id" => id}, socket) do
    _ = Deals.remove_store(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, load(socket)}
  end

  @impl true
  def handle_async({:read_store, store}, result, socket) do
    socket =
      case result do
        {:ok, {:ok, 0}} ->
          put_flash(
            socket,
            :error,
            gettext("Tore read %{store} but found no offers this week.", store: store)
          )

        {:ok, {:ok, count}} ->
          put_flash(
            socket,
            :info,
            ngettext(
              "Found %{count} offer at %{store}.",
              "Found %{count} offers at %{store}.",
              count,
              store: store
            )
          )

        _failed ->
          put_flash(
            socket,
            :error,
            gettext("Tore couldn't read %{store} just now. It tries again every morning.",
              store: store
            )
          )
      end

    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:xl}>
        <.top_bar title={gettext("Offers")} />

        <header class="pt-2">
          <p class="t-eyebrow">{week_line(@week)}</p>
          <h1 data-role="headline" class="t-title mt-1">{headline(@page)}</h1>
          <p
            :if={sub = sub_line(@page)}
            class="mt-1 text-[color:var(--muted)]"
            style="font-size: 14px;"
          >
            {sub}
          </p>
        </header>

        <div class="mt-5">
          <.group
            :if={@page.meals != []}
            role="meals"
            label={gettext("For this week's meals")}
            tint="orange"
            entries={@page.meals}
            logos={@logos}
            open
          />
          <.group
            :if={@page.usual != []}
            role="usual"
            label={gettext("Things you usually buy")}
            tint="green"
            entries={@page.usual}
            logos={@logos}
            open
          />
          <.group
            :if={@page.maybe != []}
            role="maybe"
            label={gettext("Might be for you")}
            tint="blue"
            entries={@page.maybe}
            logos={@logos}
            open
          />
          <.group
            :if={@page.others != []}
            role="others"
            label={gettext("Other offers")}
            tint="grey"
            entries={@page.others}
            logos={@logos}
            open={false}
          />
          <.group
            :if={@page.not_for_us != []}
            role="not-for-us"
            label={gettext("Not for you")}
            tint="grey"
            entries={@page.not_for_us}
            logos={@logos}
            open={false}
          />
        </div>

        <.stores
          stores={@page.stores}
          url={@store_url}
          error={@store_error}
          adding={@adding_store}
        />
      </.page>
    </Layouts.app>
    """
  end

  attr :stores, :list, required: true
  attr :url, :string, required: true
  attr :error, :string, default: nil
  attr :adding, :boolean, default: false

  # The stores Tore reads offers from, at the foot: they're set once and rarely touched.
  defp stores(assigns) do
    ~H"""
    <section data-role="stores" class="mt-10 max-w-[520px]">
      <h2 class="t-head">{gettext("Stores")}</h2>
      <p class="text-[color:var(--muted)]" style="font-size: 13px;">
        {gettext("Tore reads their offers every morning.")}
      </p>
      <div class="mt-2">
        <div
          :for={%{store: hs, deals: count} <- @stores}
          data-role="store"
          class="flex min-h-11 items-center gap-2.5 border-b border-[color:var(--hairline)]"
          style="font-size: 14.5px;"
        >
          <.store_mark name={hs.store.name} logo={hs.store.logo} />
          <span class="min-w-0 flex-1 truncate">{hs.store.name}</span>
          <span
            :if={hs.scrape_enabled}
            class="num shrink-0 text-[color:var(--muted)]"
            style="font-size: 12.5px;"
          >
            {ngettext("%{count} offer", "%{count} offers", count)}
          </span>
          <button
            type="button"
            role="switch"
            aria-checked={to_string(hs.scrape_enabled)}
            aria-label={gettext("Read offers from %{store}", store: hs.store.name)}
            phx-click="toggle_store"
            phx-value-id={hs.id}
            class="switch"
          >
          </button>
          <button
            type="button"
            phx-click="remove_store"
            phx-value-id={hs.id}
            aria-label={gettext("Remove %{store}", store: hs.store.name)}
            class="press grid size-11 -my-1.5 -mr-2 shrink-0 place-items-center rounded-[var(--r-pill)] text-[color:var(--muted)] hover:bg-[var(--danger-soft)] hover:text-[color:var(--danger)]"
          >
            <.icon name="ph-trash" class="size-4" />
          </button>
        </div>
        <button
          :if={@stores != [] and not @adding and is_nil(@error)}
          type="button"
          data-role="add-store"
          phx-click="open_store_form"
          class="row-hover press press-soft -mx-1.5 flex min-h-11 w-full items-center gap-2 rounded-[var(--r-sm)] px-1.5 text-[color:var(--muted)]"
          style="font-size: 14px;"
        >
          <.icon name="ph-plus" class="size-4" /> {gettext("Add a store")}
        </button>
        <form
          :if={@stores == [] or @adding or @error}
          id="store-form"
          phx-submit="add_store"
          class="settle mt-2"
        >
          <.field
            id="store-url"
            type="url"
            name="url"
            value={@url}
            placeholder="https://www.ica.se/erbjudanden/…"
            aria-label={gettext("Link to a store's offers")}
            errors={List.wrap(@error)}
            phx-mounted={@adding && JS.focus()}
            phx-keydown={@stores != [] && "close_store_form"}
            phx-key="Escape"
            required
            enterkeyhint="done"
          />
          <button type="submit" class="sr-only">{gettext("Add")}</button>
        </form>
      </div>
    </section>
    """
  end

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :tint, :string, required: true
  attr :entries, :list, required: true
  attr :logos, :map, required: true, doc: "each store's logo, by its name"
  attr :open, :boolean, default: true

  defp group(assigns) do
    ~H"""
    <details data-role={"group-#{@role}"} class="group mt-3" open={@open}>
      <summary class="press press-soft" style="font-size: 13px;">
        <.icon name="ph-caret-right" class="arrow size-3.5 text-[color:var(--muted)]" />
        <span class={"tag tag-#{@tint}"}>{@label}</span>
        <span class="num text-[color:var(--muted)]">{length(@entries)}</span>
      </summary>
      <div>
        <.deal :for={entry <- @entries} entry={entry} logo={@logos[entry.deal.store]} />
      </div>
    </details>
    """
  end

  attr :entry, :map, required: true
  attr :logo, :string, default: nil

  defp deal(assigns) do
    ~H"""
    <div data-role="deal" class="deal">
      <div class="min-w-0">
        <p class="truncate" style="font-size: 14.5px;">
          <span data-role="deal-name">{@entry.deal.product_name}</span>
          <span :if={@entry.deal.size} class="text-[color:var(--muted)]" style="font-size: 13px;">
            {@entry.deal.size}
          </span>
        </p>
        <p
          class="flex min-w-0 items-center gap-1.5 truncate text-[color:var(--muted)] lg:hidden"
          style="font-size: 12.5px;"
        >
          <.store_mark name={@entry.deal.store} logo={@logo} />
          <span class="truncate">
            {Enum.join(
              Enum.reject(
                [@entry.deal.store, until(@entry.deal.valid_until, :short), @entry.meal],
                &is_nil/1
              ),
              " · "
            )}
          </span>
        </p>
        <p
          :if={@entry.meal}
          class="hidden truncate text-[color:var(--muted)] lg:block"
          style="font-size: 12px;"
        >
          {gettext("for %{meal}", meal: @entry.meal)}
        </p>
      </div>
      <span class="hidden min-w-0 items-center gap-1.5 lg:flex" style="font-size: 14px;">
        <.store_mark name={@entry.deal.store} logo={@logo} />
        <span class="truncate">{@entry.deal.store}</span>
      </span>
      <span
        class="hidden whitespace-nowrap text-[color:var(--muted)] lg:block"
        style="font-size: 13px;"
      >
        {until(@entry.deal.valid_until, :long)}
      </span>
      <span class="num text-right leading-tight">
        <span class="block font-semibold" style="font-size: 14.5px;">{price(@entry.deal)}</span>
        <span :if={was = was(@entry.deal)} class="was">{was}</span>
      </span>
      <span class="num hidden text-right text-[color:var(--muted)] lg:block" style="font-size: 13px;">
        {@entry.saving && "−#{Money.format(@entry.saving)} kr"}
      </span>
      <span class="justify-self-end">
        <%!-- A phone keeps the + button's square, so the column doesn't shift. --%>
        <span
          :if={@entry.on_list?}
          id={"on-list-#{@entry.deal.id}"}
          data-role="on-list"
          class="settle"
        >
          <span class="tag tag-grey hidden lg:inline-flex" style="font-size: 11.5px;">
            {gettext("On the list")}
          </span>
          <span
            class="grid size-7 place-items-center rounded-[var(--r-sm)] bg-[var(--tag-grey)] text-[color:var(--tag-grey-ink)] lg:hidden"
            title={gettext("On the list")}
          >
            <.icon name="ph-check" class="size-3.5" />
            <span class="sr-only">{gettext("On the list")}</span>
          </span>
        </span>
        <button
          :if={!@entry.on_list?}
          type="button"
          phx-click="add"
          phx-value-id={@entry.deal.id}
          data-role="add-deal"
          aria-label={gettext("Put %{name} on the list", name: @entry.name)}
          class="deal-add row-hover press phx-click-loading:opacity-60"
        >
          <.icon name="ph-plus" class="size-4" />
        </button>
      </span>
    </div>
    """
  end

  defp headline(%{stores: []}), do: gettext("Offers from the stores you shop at")

  defp headline(%{meals: [], usual: [], maybe: [], others: [], not_for_us: []}),
    do: gettext("No offers in yet")

  defp headline(%{saving: saving}) do
    if Decimal.gt?(saving, 0),
      do:
        gettext("Save around %{amount} kr on things you buy anyway", amount: Money.format(saving)),
      else: gettext("Nothing you usually buy is on offer this week")
  end

  defp sub_line(%{stores: []}),
    do: gettext("Add a link to a store or its offers below, and Tore reads them every morning.")

  defp sub_line(%{meals: [], usual: [], maybe: [], others: [], not_for_us: []}),
    do: gettext("Tore reads the stores' offers every morning.")

  defp sub_line(_page), do: nil

  # "2 för 30", "89 kr/kg", "49,90", "89 kr".
  defp price(%{price: nil}), do: "–"

  defp price(%{price: price, quantity: q}) when q > 1,
    do: gettext("%{n} for %{price}", n: q, price: kronor(price))

  defp price(%{price: price, price_unit: unit}) when unit in ["kg", "l"],
    do: "#{kronor(price)} kr/#{unit}"

  defp price(%{price: price}), do: with_kr(price)

  # The regular price, per item when the offer is for several.
  defp was(%{regular_price: nil}), do: nil
  defp was(%{regular_price: regular, quantity: q}) when q > 1, do: "#{kronor(regular)}/st"

  defp was(%{regular_price: regular, price_unit: unit}) when unit in ["kg", "l"],
    do: "#{kronor(regular)} kr/#{unit}"

  defp was(%{regular_price: regular}), do: with_kr(regular)

  defp with_kr(amount) do
    if whole?(amount), do: "#{kronor(amount)} kr", else: kronor(amount)
  end

  # Whole kronor without decimals, else with öre and a decimal comma: "30", "49,90".
  defp kronor(amount) do
    if whole?(amount),
      do: Money.format(amount),
      else: amount |> Decimal.round(2) |> Decimal.to_string(:normal) |> String.replace(".", ",")
  end

  defp whole?(amount), do: Decimal.eq?(amount, Decimal.round(amount, 0))

  defp until(nil, _), do: nil

  defp until(date, :short),
    do: gettext("until %{day}", day: weekday(date))

  defp until(date, :long),
    do: gettext("until %{day}", day: "#{weekday(date)} #{date.day}/#{date.month}")

  defp weekday(date),
    do: date |> ToreWeb.Dates.weekday() |> String.slice(0, 3) |> String.downcase()

  defp week_line(week_start) do
    gettext("Week %{n} · %{range}",
      n: Streams.week_number(week_start),
      range: ToreWeb.Dates.range(week_start, Date.add(week_start, 6))
    )
  end

  attr :name, :string, required: true
  attr :logo, :string, default: nil

  # A store's logo, from its own site; its first letter until Tore has read the page.
  defp store_mark(assigns) do
    ~H"""
    <img :if={@logo} src={@logo} alt="" class="store-i" loading="lazy" referrerpolicy="no-referrer" />
    <span :if={!@logo} class="store-i" aria-hidden="true">{initial(@name)}</span>
    """
  end

  defp initial(nil), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()
end
