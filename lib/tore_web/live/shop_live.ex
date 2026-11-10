defmodule ToreWeb.ShopLive do
  use ToreWeb, :live_view

  on_mount {ToreWeb.Live.Auth, :hears_runs}

  alias Tore.Shop
  alias Phoenix.PubSub

  def mount(_params, session, socket) do
    week_start = week_start(Date.utc_today())
    scope = socket.assigns.current_scope
    list_id = Tore.Streams.shop_list(scope, week_start)

    if connected?(socket) do
      PubSub.subscribe(Tore.PubSub, Shop.topic(scope))
    end

    {:ok, grocery_state} = Shop.load_list(scope, list_id)
    user_id = Map.get(session, "user_id")

    {:ok,
     assign(socket,
       week_start: week_start,
       week_number: week_number(week_start),
       list_id: list_id,
       grocery_state: grocery_state,
       user_id: user_id,
       export_text: nil,
       item_sheet: nil,
       item_command_loading: false
     )}
  end

  def handle_event("toggle_item", %{"item_id" => id}, socket) do
    item = Map.get(socket.assigns.grocery_state.items, id)

    if item && item.checked do
      Shop.uncheck_item(
        socket.assigns.current_scope,
        socket.assigns.list_id,
        id,
        socket.assigns.user_id
      )
    else
      Shop.check_item(
        socket.assigns.current_scope,
        socket.assigns.list_id,
        id,
        socket.assigns.user_id
      )
    end

    {:noreply, socket}
  end

  def handle_event("remove_item", %{"item_id" => id}, socket) do
    Shop.remove_item(
      socket.assigns.current_scope,
      socket.assigns.list_id,
      id,
      socket.assigns.user_id
    )

    {:noreply, socket}
  end

  def handle_event("export_list", _params, socket) do
    case Shop.export_list(socket.assigns.current_scope, socket.assigns.list_id) do
      {:ok, text} -> {:noreply, assign(socket, export_text: text)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_export", _params, socket) do
    {:noreply, assign(socket, export_text: nil)}
  end

  def handle_event("add_item", %{"name" => name} = params, socket) do
    name = String.trim(name)

    if name != "" do
      qty = Map.get(params, "quantity", "")
      unit = Map.get(params, "unit", "")
      quantity = if qty == "", do: nil, else: parse_qty(qty)
      unit = if unit == "", do: nil, else: unit

      Shop.add_item(
        socket.assigns.current_scope,
        socket.assigns.list_id,
        name,
        quantity,
        unit,
        socket.assigns.user_id
      )
    end

    {:noreply, socket}
  end

  def handle_event("open_item_sheet", %{"item_id" => id}, socket) do
    case Map.get(socket.assigns.grocery_state.items, id) do
      nil -> {:noreply, socket}
      item -> {:noreply, assign(socket, item_sheet: item)}
    end
  end

  def handle_event("close_item_sheet", _params, socket) do
    {:noreply, assign(socket, item_sheet: nil)}
  end

  def handle_event("item_command", %{"command" => command}, socket) when command != "" do
    item = socket.assigns.item_sheet
    pid = self()

    ctx = %{
      household_id: socket.assigns.current_scope.household_id,
      user_id: socket.assigns.current_user && socket.assigns.current_user.id,
      locale: socket.assigns.current_user && socket.assigns.current_user.locale
    }

    prefixed =
      "[The user is referring to the grocery item \"#{item.name}\" on the shopping list.] " <>
        command

    locale = Gettext.get_locale(ToreWeb.Gettext)

    Task.start(fn ->
      # Gettext's locale is per process, so the replies need it set here too.
      Gettext.put_locale(ToreWeb.Gettext, locale)
      result = Tore.Capture.Router.route(prefixed, [], ctx, [])
      send(pid, {:item_command_complete, result})
    end)

    {:noreply, assign(socket, item_sheet: nil, item_command_loading: true)}
  end

  def handle_event("item_command", _params, socket), do: {:noreply, socket}

  def handle_info({:item_command_complete, result}, socket) do
    flash =
      case result do
        {:ok, bubbles} ->
          {:info, bubble_text(bubbles)}

        {:error, reason} ->
          {:error,
           Tore.LLM.refusal_text(reason) ||
             gettext("Tore couldn't finish that. Try again in a moment.")}
      end

    {kind, text} = flash

    {:noreply,
     socket
     |> assign(item_command_loading: false)
     |> put_flash(kind, text)}
  end

  def handle_info({:events, _events}, socket) do
    {:ok, grocery_state} = Shop.load_list(socket.assigns.current_scope, socket.assigns.list_id)
    {:noreply, assign(socket, grocery_state: grocery_state)}
  end

  def handle_info({:run_changed, %{status: :reverted, surface: :shop}}, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Undone."))}

  def handle_info({:run_changed, _run}, socket), do: {:noreply, socket}

  def render(assigns) do
    items =
      assigns.grocery_state.items
      |> sorted_items()
      |> then(&Shop.annotate_with_pantry_belief(assigns.current_scope, &1))

    {unchecked, checked} = Enum.split_with(items, &(!&1.checked))
    groups = group_by_section(unchecked)

    assigns =
      assign(assigns,
        groups: groups,
        checked: checked,
        total: length(items),
        unchecked_count: length(unchecked)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      current_user={@current_user}
      current_path={assigns[:current_path] || "/shop"}
    >
      <.page max_width={:md}>
        <.card padded={false}>
          <header class="flex items-start justify-between gap-4 px-6 pt-6 pb-4">
            <div>
              <h1 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h1);">
                {gettext("Shop")}
              </h1>
              <p class="mt-0.5 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                {gettext("%{n} unchecked · Week %{week}", n: @unchecked_count, week: @week_number)}
              </p>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <button
                type="button"
                phx-click="export_list"
                aria-label={gettext("More")}
                class="size-9 inline-flex items-center justify-center rounded-[var(--r-lg)] border border-[color:var(--border)] text-[color:var(--muted)] hover:border-[color:var(--subtle)]"
              >
                <.icon name="hero-ellipsis-horizontal" class="size-4" />
              </button>
            </div>
          </header>

          <div
            :if={@export_text}
            class="mx-6 mb-4 border border-[color:var(--border)] rounded-[var(--r-lg)] p-3"
          >
            <div class="flex items-center justify-between mb-2">
              <span
                class="text-[color:var(--muted)]"
                style="font-size: var(--t-meta); font-weight: 500;"
              >
                {gettext("Export")}
              </span>
              <.icon_button icon="hero-x-mark" label="Close" phx-click="clear_export" />
            </div>
            <textarea
              readonly
              class="w-full bg-transparent text-[var(--text)] font-mono resize-none focus:outline-none"
              style="font-size: var(--t-meta);"
              rows="6"
            ><%= @export_text %></textarea>
          </div>

          <div class="px-6 pb-3">
            <%= if @total == 0 do %>
              <.empty message={gettext("No items yet")} />
            <% else %>
              <%= for {section, section_items} <- @groups do %>
                <h2
                  class="uppercase tracking-wider text-[color:var(--subtle)] mt-5 mb-1 first:mt-0"
                  style="font-size: var(--t-micro); font-weight: 600;"
                >
                  {section_label(section)}
                </h2>
                <ul class="divide-y divide-[color:var(--hairline)]">
                  <.item_row :for={item <- section_items} item={item} />
                </ul>
              <% end %>

              <%= if @checked != [] do %>
                <h2
                  class="uppercase tracking-wider text-[color:var(--subtle)] mt-6 mb-1"
                  style="font-size: var(--t-micro); font-weight: 600;"
                >
                  {gettext("Done · %{n}", n: length(@checked))}
                </h2>
                <ul class="divide-y divide-[color:var(--hairline)]">
                  <.item_row :for={item <- @checked} item={item} />
                </ul>
              <% end %>
            <% end %>

            <form
              phx-submit="add_item"
              class="mt-2 pt-3 border-t border-[color:var(--hairline)] flex items-center gap-3"
            >
              <.icon name="hero-plus" class="size-5 text-[color:var(--accent)] shrink-0" />
              <input
                type="text"
                name="name"
                placeholder={gettext("Add item…")}
                required
                class="flex-1 h-10 bg-transparent border-0 text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none"
                style="font-size: var(--t-body);"
              />
              <input
                type="text"
                name="quantity"
                placeholder={gettext("Qty")}
                inputmode="decimal"
                class="w-16 h-10 bg-transparent border-0 text-[color:var(--muted)] placeholder:text-[color:var(--subtle)] tabular-nums text-right focus:outline-none"
                style="font-size: var(--t-meta);"
              />
              <input
                type="text"
                name="unit"
                placeholder={gettext("Unit")}
                class="w-12 h-10 bg-transparent border-0 text-[color:var(--muted)] placeholder:text-[color:var(--subtle)] focus:outline-none"
                style="font-size: var(--t-meta);"
              />
            </form>
          </div>
        </.card>
      </.page>

      <%!-- Grocery item object sheet (long-press) --%>
      <div
        :if={@item_sheet}
        id="item-sheet"
        class="fixed inset-x-0 bottom-0 top-8 z-50 rounded-t-2xl bg-[var(--surface)] border-t border-[color:var(--border)] flex flex-col"
        phx-window-keydown="close_item_sheet"
        phx-key="Escape"
      >
        <div class="flex justify-center py-2">
          <button
            type="button"
            phx-click="close_item_sheet"
            aria-label={gettext("Close")}
            data-role="item-sheet-close"
          >
            <span class="w-10 h-1.5 rounded-full bg-[color:var(--border)] block"></span>
          </button>
        </div>

        <div class="flex items-baseline gap-2 px-4 py-3 border-b border-[color:var(--border)]">
          <span class="font-semibold text-[color:var(--text)]">{@item_sheet.name}</span>
          <span :if={qty_label(@item_sheet) != ""} class="text-[color:var(--muted)] text-sm">
            {qty_label(@item_sheet)}
          </span>
        </div>

        <div class="flex-1 overflow-y-auto px-4 py-4">
          <form phx-submit="item_command">
            <input
              type="text"
              name="command"
              autocomplete="off"
              placeholder={gettext("Anything about this item…")}
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true

  defp item_row(assigns) do
    ~H"""
    <li
      id={"item-#{@item.id}"}
      phx-hook="LongPress"
      data-long-press-event="open_item_sheet"
      data-item-id={@item.id}
      data-item-name={@item.name}
      class={[
        "flex items-center gap-4 py-3 transition-opacity",
        @item.checked && "opacity-50"
      ]}
    >
      <.checkbox checked={@item.checked} phx-click="toggle_item" phx-value-item_id={@item.id} />
      <button
        type="button"
        phx-click="toggle_item"
        phx-value-item_id={@item.id}
        class="flex-1 min-w-0 text-left"
      >
        <span
          class={[
            "text-[var(--text)] truncate",
            @item.checked && "line-through"
          ]}
          style="font-size: var(--t-body);"
        >
          <span :if={Map.get(@item, :pantry_belief)} class="text-[color:var(--muted)] mr-1">?</span>{@item.name}
        </span>
        <p
          :if={Map.get(@item, :pantry_belief)}
          class="text-[color:var(--subtle)] mt-0.5"
          style="font-size: var(--t-micro);"
        >
          {pantry_belief_hint(@item.pantry_belief, @item.pantry_last_seen_at)}
        </p>
      </button>
      <span
        :if={qty_label(@item) != ""}
        class="shrink-0 text-[color:var(--muted)] tabular-nums"
        style="font-size: var(--t-meta);"
      >
        {qty_label(@item)}
      </span>
      <button
        type="button"
        phx-click="remove_item"
        phx-value-item_id={@item.id}
        aria-label={gettext("Remove")}
        class="size-9 inline-flex items-center justify-center text-[color:var(--subtle)] hover:text-[color:var(--danger)]"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </li>
    """
  end

  defp bubble_text(bubbles) do
    bubbles
    |> Enum.map(&Map.get(&1, :text, ""))
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> gettext("Done.")
      text -> text
    end
  end

  defp sorted_items(items) do
    items
    |> Map.values()
    |> Enum.sort_by(fn i -> {i.checked, String.downcase(i.name || "")} end)
  end

  @section_order ~w(produce meat fish dairy deli frozen bread dry_goods canned beverages herbs_spices condiments household other)a

  defp group_by_section(items) do
    grouped = Enum.group_by(items, &(Map.get(&1, :section) || :other))

    @section_order
    |> Enum.filter(&Map.has_key?(grouped, &1))
    |> Enum.map(fn section ->
      {section, Enum.sort_by(grouped[section], &String.downcase(&1.name))}
    end)
  end

  defp section_label(:produce), do: gettext("Produce")
  defp section_label(:meat), do: gettext("Meat")
  defp section_label(:fish), do: gettext("Fish & Seafood")
  defp section_label(:dairy), do: gettext("Dairy & Eggs")
  defp section_label(:deli), do: gettext("Deli")
  defp section_label(:frozen), do: gettext("Frozen")
  defp section_label(:bread), do: gettext("Bread")
  defp section_label(:canned), do: gettext("Canned Goods")
  defp section_label(:beverages), do: gettext("Beverages")
  defp section_label(:herbs_spices), do: gettext("Herbs & Spices")
  defp section_label(:condiments), do: gettext("Condiments & Oils")
  defp section_label(:household), do: gettext("Household")
  defp section_label(:dry_goods), do: gettext("Dry Goods")
  defp section_label(:other), do: gettext("Other")

  defp qty_label(%{quantity: nil, unit: nil}), do: ""
  defp qty_label(%{quantity: nil, unit: unit}), do: unit
  defp qty_label(%{quantity: qty, unit: nil}), do: format_decimal(qty)
  defp qty_label(%{quantity: qty, unit: unit}), do: "#{format_decimal(qty)} #{unit}"

  defp format_decimal(%Decimal{} = d) do
    if Decimal.integer?(d),
      do: Decimal.to_string(Decimal.normalize(d)),
      else: Decimal.to_string(d)
  end

  defp format_decimal(other), do: to_string(other)

  defp parse_qty(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp week_start(date) do
    dow = Date.day_of_week(date)
    Date.add(date, -(dow - 1))
  end

  defp week_number(date) do
    {_y, w} = :calendar.iso_week_number({date.year, date.month, date.day})
    w
  end

  defp pantry_belief_hint(:confirmed, last_seen),
    do: gettext("confirmed at home%{when}", when: last_seen_suffix(last_seen))

  defp pantry_belief_hint(:probable, last_seen),
    do: gettext("probably at home%{when}", when: last_seen_suffix(last_seen))

  defp pantry_belief_hint(:uncertain, last_seen),
    do: gettext("unknown%{when}", when: last_seen_suffix(last_seen))

  defp pantry_belief_hint(_, _), do: ""

  defp last_seen_suffix(nil), do: ""

  defp last_seen_suffix(%DateTime{} = ts) do
    days = DateTime.diff(DateTime.utc_now(), ts, :day)

    cond do
      days < 1 -> gettext(", last confirmed today")
      days == 1 -> gettext(", last confirmed yesterday")
      true -> gettext(", last confirmed %{n} days ago", n: days)
    end
  end
end
