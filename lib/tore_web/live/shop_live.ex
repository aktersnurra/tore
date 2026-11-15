defmodule ToreWeb.ShopLive do
  use ToreWeb, :live_view

  on_mount {ToreWeb.Live.Auth, :hears_runs}

  alias Tore.Shop
  alias Phoenix.PubSub

  def mount(_params, session, socket) do
    week_start = Tore.Streams.monday(Tore.Clock.today())
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
       week_number: Tore.Streams.week_number(week_start),
       list_id: list_id,
       grocery_state: grocery_state,
       user_id: user_id,
       export_text: nil,
       item_sheet: nil,
       item_command_loading: false,
       spending: ToreWeb.Spending.load(scope),
       scanning: false
     )
     |> allow_upload(:receipt_photo,
       accept: ~w(.jpg .jpeg .png .webp .heic),
       max_entries: 1,
       max_file_size: 10_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  def handle_progress(:receipt_photo, %{done?: true} = entry, socket) do
    image = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)
    scope = socket.assigns.current_scope

    ToreWeb.Background.run(
      fn -> Tore.Capture.Dispatch.read_receipt(scope, image) end,
      &{:receipt_read, &1}
    )

    {:noreply, assign(socket, scanning: true)}
  end

  def handle_progress(:receipt_photo, _entry, socket), do: {:noreply, socket}

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

    {:noreply, assign(socket, item_sheet: nil)}
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

    ctx = %{
      scope: socket.assigns.current_scope,
      locale: socket.assigns.current_user && socket.assigns.current_user.locale
    }

    prefixed =
      "[The user is referring to the grocery item \"#{item.name}\" on the shopping list.] " <>
        command

    ToreWeb.Background.run(
      fn -> Tore.Capture.Router.route(prefixed, [], ctx, []) end,
      &{:item_command_complete, &1}
    )

    {:noreply, assign(socket, item_sheet: nil, item_command_loading: true)}
  end

  def handle_event("item_command", _params, socket), do: {:noreply, socket}

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

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

  # A receipt saved or undone anywhere changes the month's spending.
  def handle_info({:run_changed, _run}, socket), do: {:noreply, reload_spending(socket)}

  def handle_info({:receipt_read, {:saved, _run_id, text}}, socket),
    do:
      {:noreply, socket |> reload_spending() |> assign(scanning: false) |> put_flash(:info, text)}

  # A duplicate photo or a failure: the reply says which.
  def handle_info({:receipt_read, {tag, text}}, socket) when tag in [:duplicate, :failed],
    do: {:noreply, socket |> assign(scanning: false) |> put_flash(:error, text)}

  def handle_info({:receipt_read, {:error, :crashed}}, socket) do
    {:noreply,
     socket
     |> assign(scanning: false)
     |> put_flash(:error, gettext("Tore couldn't finish that. Try again in a moment."))}
  end

  defp reload_spending(socket),
    do: assign(socket, spending: ToreWeb.Spending.load(socket.assigns.current_scope))

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
    >
      <.page max_width={:md}>
        <header class="flex items-start justify-between gap-4 pt-6">
          <div class="min-w-0">
            <h1 class="t-display">{gettext("Shop")}</h1>
            <p class="num mt-1.5 text-[color:var(--muted)]" style="font-size: 15px;">
              {ngettext(
                "%{count} item left, week %{week}",
                "%{count} items left, week %{week}",
                @unchecked_count,
                week: @week_number
              )}
            </p>
          </div>
          <button
            :if={@total > 0}
            type="button"
            phx-click="export_list"
            aria-label={gettext("Show as text")}
            class="press mt-1 flex size-11 shrink-0 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] hover:bg-[var(--border)]"
          >
            <.icon name="hero-document-text" class="size-5" />
          </button>
        </header>

        <%!-- How far along the shop is: dill fills as things go in the basket --%>
        <div
          :if={@total > 0}
          class="mt-5 h-1.5 overflow-hidden rounded-full bg-[var(--sunken)]"
          role="progressbar"
          aria-valuemin="0"
          aria-valuemax={@total}
          aria-valuenow={@total - @unchecked_count}
          aria-label={gettext("In the basket")}
        >
          <div
            class="h-full rounded-full bg-[color:var(--done)] transition-[width] duration-[var(--dur-slow)] ease-[var(--ease-out)]"
            style={"width: #{round((@total - @unchecked_count) / @total * 100)}%"}
          >
          </div>
        </div>

        <div
          :if={@export_text}
          class="rise-in mt-4 rounded-[var(--r-xl)] bg-[var(--surface)] p-4"
        >
          <div class="mb-2 flex items-center justify-between">
            <span class="section-label">{gettext("The list as text")}</span>
            <.icon_button icon="hero-x-mark" label={gettext("Close")} phx-click="clear_export" />
          </div>
          <textarea
            readonly
            aria-label={gettext("The list as text")}
            class="w-full resize-none bg-transparent text-[var(--text)] focus:outline-none"
            style="font-size: var(--t-meta);"
            rows="6"
          ><%= @export_text %></textarea>
        </div>

        <div :if={@total == 0} class="pt-8 pb-2">
          <p class="t-head">{gettext("Nothing to buy")}</p>
          <p class="mt-1.5 text-[color:var(--muted)]" style="font-size: 15px;">
            {gettext("Add an item here, or ask Tore to make the list from the plan.")}
          </p>
        </div>

        <%= for {section, section_items} <- @groups do %>
          <h2 class="t-eyebrow mt-7 mb-2">{section_label(section)}</h2>
          <ul class="menu-lines">
            <.item_row :for={item <- section_items} item={item} />
          </ul>
        <% end %>

        <%= if @checked != [] do %>
          <h2 class="t-eyebrow mt-7 mb-2">
            {gettext("In the basket, %{n}", n: length(@checked))}
          </h2>
          <ul class="menu-lines">
            <.item_row :for={item <- @checked} item={item} />
          </ul>
        <% end %>

        <form
          phx-submit="add_item"
          class="mt-7 flex items-center gap-2 rounded-full bg-[var(--sunken)] pl-4 pr-3 focus-within:outline-2 focus-within:outline-[color:var(--accent)]"
        >
          <.icon name="hero-plus" class="size-5 shrink-0 text-[color:var(--muted)]" />
          <input
            type="text"
            name="name"
            placeholder={gettext("Add item…")}
            aria-label={gettext("Add item…")}
            required
            class="h-12 min-w-0 flex-1 border-0 bg-transparent text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none"
            style="font-size: 16px;"
          />
          <input
            type="text"
            name="quantity"
            placeholder={gettext("Qty")}
            aria-label={gettext("Qty")}
            inputmode="decimal"
            class="num h-12 w-14 border-0 bg-transparent text-right text-[color:var(--muted)] placeholder:text-[color:var(--subtle)] focus:outline-none"
            style="font-size: var(--t-meta);"
          />
          <input
            type="text"
            name="unit"
            placeholder={gettext("Unit")}
            aria-label={gettext("Unit")}
            class="h-12 w-12 border-0 bg-transparent text-[color:var(--muted)] placeholder:text-[color:var(--subtle)] focus:outline-none"
            style="font-size: var(--t-meta);"
          />
        </form>

        <ToreWeb.Spending.spending
          spending={@spending}
          scanning={@scanning}
          upload={@uploads.receipt_photo}
        />
      </.page>

      <%!-- Grocery item object sheet (long-press) --%>
      <div
        :if={@item_sheet}
        id="item-sheet"
        class="fixed inset-0 z-50 flex items-end justify-center"
        phx-window-keydown="close_item_sheet"
        phx-key="Escape"
      >
        <div class="scrim absolute inset-0 bg-black/50" phx-click="close_item_sheet"></div>
        <div class="sheet relative flex w-full max-w-md flex-col rounded-t-[28px] bg-[var(--surface)] pb-[calc(env(safe-area-inset-bottom)+1rem)]">
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

          <div class="flex items-baseline gap-2 px-5 pb-1">
            <span class="t-head">{@item_sheet.name}</span>
            <span :if={qty_label(@item_sheet) != ""} class="num text-[15px] text-[color:var(--muted)]">
              {qty_label(@item_sheet)}
            </span>
          </div>

          <div class="px-5 pt-3">
            <form phx-submit="item_command">
              <input
                type="text"
                name="command"
                autocomplete="off"
                autofocus
                placeholder={gettext("Anything about this item…")}
                class="h-12 w-full rounded-full bg-[var(--sunken)] px-5 text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus-visible:outline-2 focus-visible:outline-[color:var(--accent)]"
                style="font-size: 16px;"
              />
            </form>
            <button
              type="button"
              phx-click="remove_item"
              phx-value-item_id={@item_sheet.id}
              class="press mt-4 flex h-11 items-center gap-2 text-[15px] font-semibold text-[color:var(--danger)]"
            >
              <.icon name="hero-trash" class="size-4" />
              {gettext("Remove from the list")}
            </button>
          </div>
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
        "flex min-h-[56px] items-center gap-4 py-2.5 transition-opacity duration-[var(--dur-base)]",
        @item.checked && "opacity-50"
      ]}
    >
      <.checkbox checked={@item.checked} phx-click="toggle_item" phx-value-item_id={@item.id} />
      <button
        type="button"
        phx-click="toggle_item"
        phx-value-item_id={@item.id}
        class="press press-soft flex-1 min-w-0 text-left"
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
