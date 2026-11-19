defmodule ToreWeb.DealsLive do
  @moduledoc """
  Erbjudanden: this week's offers on things the household buys anyway, first what the dinners
  call for, then what it usually buys, the rest folded away (ui.md, "Erbjudanden"). Everything is
  read from `Tore.Deals.page/3`; + puts a deal on this week's list.
  """
  use ToreWeb, :live_view

  alias Tore.{Deals, Money, Shop, Streams}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  defp load(socket) do
    today = Tore.Clock.today()
    week = Streams.monday(today)
    assign(socket, week: week, page: Deals.page(socket.assigns.current_scope, week, today))
  end

  # The name comes from the page, not the click, so only a deal shown can be added.
  @impl true
  def handle_event("add", %{"id" => id}, socket) do
    %{page: page, week: week, current_scope: scope} = socket.assigns
    id = String.to_integer(id)

    case Enum.find(page.dinners ++ page.usual ++ page.others, &(&1.deal.id == id)) do
      nil ->
        {:noreply, socket}

      entry ->
        user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

        {:ok, _} =
          Shop.add_item(scope, Streams.shop_list(scope, week), entry.name, nil, nil, user_id)

        {:noreply, load(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:lg}>
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
            :if={@page.dinners != []}
            role="dinners"
            label={gettext("For this week's dinners")}
            tint="orange"
            entries={@page.dinners}
            open
          />
          <.group
            :if={@page.usual != []}
            role="usual"
            label={gettext("Things you usually buy")}
            tint="green"
            entries={@page.usual}
            open
          />
          <.group
            :if={@page.others != []}
            role="others"
            label={gettext("Other offers")}
            tint="grey"
            entries={@page.others}
            open={false}
          />
        </div>
      </.page>
    </Layouts.app>
    """
  end

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :tint, :string, required: true
  attr :entries, :list, required: true
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
        <.deal :for={entry <- @entries} entry={entry} />
      </div>
    </details>
    """
  end

  attr :entry, :map, required: true

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
          <span class="store-i" aria-hidden="true">{initial(@entry.deal.store)}</span>
          <span class="truncate">
            {Enum.join(
              Enum.reject(
                [@entry.deal.store, until(@entry.deal.valid_until, :short), @entry.dinner],
                &is_nil/1
              ),
              " · "
            )}
          </span>
        </p>
        <p
          :if={@entry.dinner}
          class="hidden truncate text-[color:var(--muted)] lg:block"
          style="font-size: 12px;"
        >
          {gettext("for %{dinner}", dinner: @entry.dinner)}
        </p>
      </div>
      <span class="hidden min-w-0 items-center gap-1.5 lg:flex" style="font-size: 14px;">
        <span class="store-i" aria-hidden="true">{initial(@entry.deal.store)}</span>
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
        <span
          :if={@entry.on_list?}
          id={"on-list-#{@entry.deal.id}"}
          data-role="on-list"
          class="tag tag-grey settle"
          style="font-size: 11.5px;"
        >
          <span class="hidden lg:inline">{gettext("On the list")}</span>
          <.icon name="ph-check" class="lg:hidden" />
          <span class="sr-only lg:hidden">{gettext("On the list")}</span>
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

  defp headline(%{dinners: [], usual: [], others: []}), do: gettext("No offers in yet")

  defp headline(%{saving: saving}) do
    if Decimal.gt?(saving, 0),
      do:
        gettext("Save around %{amount} kr on things you buy anyway", amount: Money.format(saving)),
      else: gettext("Nothing you usually buy is on offer this week")
  end

  defp sub_line(%{stores: []}),
    do: gettext("Add a link to a store's offers below, and Tore reads them every Friday.")

  defp sub_line(%{dinners: [], usual: [], others: []}),
    do: gettext("Tore reads the stores' offers every Friday.")

  defp sub_line(_page), do: nil

  # "2 för 30", "89 kr/kg", "49,90", "89 kr".
  defp price(%{price: nil}), do: "–"

  defp price(%{price: price, quantity: q}) when q > 1,
    do: gettext("%{n} for %{price}", n: q, price: kronor(price))

  defp price(%{price: price, price_unit: unit}) when unit in ["kg", "l"],
    do: "#{kronor(price)}/#{unit}"

  defp price(%{price: price}), do: with_kr(price)

  # The regular price, per item when the offer is for several.
  defp was(%{regular_price: nil}), do: nil
  defp was(%{regular_price: regular, quantity: q}) when q > 1, do: "#{kronor(regular)}/st"
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

  defp initial(nil), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()
end
