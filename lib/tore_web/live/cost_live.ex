defmodule ToreWeb.CostLive do
  use ToreWeb, :live_view

  alias Tore.Costs

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()
    {:ok, summary} = Costs.monthly_summary(today.year, today.month)
    recent = Costs.recent_receipts(3)
    weekly_bars = Costs.weekly_spend_this_month(today)
    last_month = Date.beginning_of_month(today) |> Date.add(-1)
    last_month_total = Costs.monthly_total(last_month.year, last_month.month)

    socket =
      socket
      |> assign(
        view: :overview,
        summary: summary,
        last_month_total: last_month_total,
        receipts: [],
        stores_this_month: [],
        dining_entries: [],
        dining_by_place: [],
        scanning: false,
        receipt_preview: nil,
        scan_error: nil,
        recent_receipts: recent,
        weekly_bars: weekly_bars,
        dot_coords: []
      )
      |> allow_upload(:receipt_photo,
        accept: ~w(.jpg .jpeg .png .webp .heic),
        max_entries: 1,
        max_file_size: 10_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)
    socket = load_tab(socket, tab)
    {:noreply, assign(socket, view: tab)}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)
    socket = load_tab(socket, tab)
    {:noreply, assign(socket, view: tab)}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("discard_receipt", _params, socket) do
    {:noreply, assign(socket, receipt_preview: nil, scan_error: nil)}
  end

  @impl true
  def handle_event("update_receipt_field", %{"field" => field, "value" => value}, socket) do
    preview = socket.assigns.receipt_preview

    updated =
      case field do
        "store_name" -> %{preview | store_name: nilify(value)}
        "total" -> %{preview | total: parse_decimal(value)}
        "date" -> %{preview | date: parse_date(value)}
        _ -> preview
      end

    {:noreply, assign(socket, receipt_preview: updated)}
  end

  @impl true
  def handle_event(
        "update_receipt_item",
        %{"key" => key, "field" => field, "value" => value},
        socket
      ) do
    key = String.to_integer(key)
    preview = socket.assigns.receipt_preview

    items =
      Enum.map(preview.items, fn item ->
        if item.key == key do
          case field do
            "name" -> %{item | name: value}
            "quantity" -> %{item | quantity: parse_decimal(value)}
            "unit" -> %{item | unit: nilify(value)}
            "category" -> %{item | category: nilify(value)}
            _ -> item
          end
        else
          item
        end
      end)

    {:noreply, assign(socket, receipt_preview: %{preview | items: items})}
  end

  @impl true
  def handle_event("remove_receipt_item", %{"key" => key}, socket) do
    key = String.to_integer(key)
    preview = socket.assigns.receipt_preview
    items = Enum.reject(preview.items, &(&1.key == key))
    {:noreply, assign(socket, receipt_preview: %{preview | items: items})}
  end

  @impl true
  def handle_event("confirm_receipt", _params, socket) do
    preview = socket.assigns.receipt_preview
    user_id = socket.assigns.current_user.id

    case Costs.confirm_receipt(preview, user_id) do
      {:ok, _} ->
        today = Date.utc_today()
        {:ok, summary} = Costs.monthly_summary(today.year, today.month)

        {:noreply,
         socket
         |> assign(receipt_preview: nil, summary: summary)
         |> put_flash(:info, gettext("Receipt saved"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save receipt"))}
    end
  end

  @impl true
  def handle_event("log_dining_out", params, socket) do
    user_id = socket.assigns.current_user.id

    attrs = %{
      date: Date.from_iso8601!(params["date"]),
      description: params["description"],
      total_amount: Decimal.new(params["total_amount"]),
      num_people: String.to_integer(params["num_people"] || "1"),
      user_id: user_id
    }

    case Costs.log_dining_out(attrs) do
      {:ok, _} ->
        today = Date.utc_today()
        {:ok, summary} = Costs.monthly_summary(today.year, today.month)

        {:noreply,
         socket
         |> assign(
           summary: summary,
           dining_entries: Costs.list_dining_out(),
           dining_by_place: Costs.dining_by_place()
         )
         |> put_flash(:info, gettext("Logged"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to log"))}
    end
  end

  @impl true
  def handle_event("save_manual_receipt", params, socket) do
    user_id = socket.assigns.current_user.id

    attrs = %{
      date: Date.from_iso8601!(params["date"]),
      store_name: params["store_name"],
      total_amount: Decimal.new(params["total_amount"]),
      user_id: user_id,
      line_items: []
    }

    case Costs.log_receipt(attrs) do
      {:ok, _} ->
        today = Date.utc_today()
        {:ok, summary} = Costs.monthly_summary(today.year, today.month)

        {:noreply,
         socket |> assign(summary: summary) |> put_flash(:info, gettext("Receipt saved"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save"))}
    end
  end

  def handle_progress(:receipt_photo, entry, socket) do
    if entry.done? do
      [{binary, _}] =
        consume_uploaded_entries(socket, :receipt_photo, fn %{path: path}, e ->
          {:ok, {File.read!(path), e}}
        end)

      pid = self()

      Task.start(fn ->
        send(pid, {:receipt_scan_result, Costs.parse_receipt_image(binary)})
      end)

      {:noreply, assign(socket, scanning: true, scan_error: nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:receipt_scan_result, {:ok, result, _usage}}, socket) do
    items =
      Enum.with_index(result.items, fn item, i -> Map.put(item, :key, i) end)

    preview = %{
      total: result.total,
      store_name: result.store_name,
      date: Date.utc_today(),
      items: items
    }

    {:noreply, assign(socket, scanning: false, receipt_preview: preview)}
  end

  @impl true
  def handle_info({:receipt_scan_result, {:error, reason}}, socket) do
    require Logger
    Logger.error("receipt_scan_result error: #{inspect(reason)}")

    {:noreply,
     assign(socket,
       scanning: false,
       scan_error: gettext("Could not read receipt. Try a clearer photo.")
     )}
  end

  defp load_tab(socket, :overview) do
    today = Date.utc_today()
    {:ok, summary} = Costs.monthly_summary(today.year, today.month)
    recent = Costs.recent_receipts(3)
    weekly_bars = Costs.weekly_spend_this_month(today)
    last_month = Date.beginning_of_month(today) |> Date.add(-1)
    last_month_total = Costs.monthly_total(last_month.year, last_month.month)

    assign(socket,
      summary: summary,
      recent_receipts: recent,
      weekly_bars: weekly_bars,
      last_month_total: last_month_total
    )
  end

  defp load_tab(socket, :receipts) do
    today = Date.utc_today()
    stores = Costs.receipts_by_store(today.year, today.month)
    assign(socket, receipts: Costs.list_receipts(), stores_this_month: stores)
  end

  defp load_tab(socket, :dining) do
    assign(socket,
      dining_entries: Costs.list_dining_out(),
      dining_by_place: Costs.dining_by_place()
    )
  end

  defp load_tab(socket, _), do: socket

  @impl true
  def render(assigns) do
    tabs = [
      %{id: "overview", label: gettext("Summary")},
      %{id: "receipts", label: gettext("Groceries")},
      %{id: "dining", label: gettext("Eating out")}
    ]

    grocery_amt = decimal_to_int(assigns.summary.grocery_total)
    dining_amt = decimal_to_int(assigns.summary.dining_total)
    total_amt = decimal_to_int(assigns.summary.total)
    grocery_pct = if total_amt > 0, do: round(grocery_amt * 100 / total_amt), else: 0
    dining_pct = if total_amt > 0, do: max(100 - grocery_pct, 0), else: 0

    avg_receipt =
      if assigns.summary.receipt_count > 0,
        do: div(grocery_amt, assigns.summary.receipt_count),
        else: 0

    last_month_amt = decimal_to_int(assigns.last_month_total)

    month_change_pct =
      if last_month_amt > 0,
        do: round((total_amt - last_month_amt) * 100 / last_month_amt),
        else: nil

    assigns =
      assign(assigns,
        tabs: tabs,
        view_id: to_string(assigns.view),
        grocery_amt: grocery_amt,
        dining_amt: dining_amt,
        total_amt: total_amt,
        grocery_pct: grocery_pct,
        dining_pct: dining_pct,
        avg_receipt: avg_receipt,
        month_change_pct: month_change_pct
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={assigns[:current_scope]}
      current_path={assigns[:current_path] || "/costs"}
    >
      <.page max_width={:md}>
        <div
          id="cost-page"
          class="overflow-hidden rounded-[28px] border border-[color:var(--border)] bg-[var(--surface)] shadow-[0_18px_70px_rgba(31,41,51,0.08)]"
        >
          <header class="px-6 py-6 md:px-8">
            <h1
              class="font-semibold tracking-[-0.025em] text-[color:var(--text)]"
              style="font-size: clamp(22px, 4.5vw, 28px); line-height: 1.15;"
            >
              {gettext("Food costs")}
            </h1>
          </header>

          <div class="border-t border-b border-[color:var(--hairline)] px-6 md:px-8">
            <.cost_tabs tabs={@tabs} active={@view_id} />
          </div>

          <%= if @receipt_preview do %>
            <section class="mx-6 mb-5 rounded-3xl border border-[color:var(--border)] bg-white/70 shadow-sm md:mx-8">
              <header class="flex items-center justify-between px-5 pt-5 pb-3">
                <h2 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
                  {gettext("Review receipt")}
                </h2>
                <span class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {length(@receipt_preview.items)} {gettext("items")}
                </span>
              </header>
              <div class="space-y-3 border-t border-[color:var(--hairline)] px-5 pt-4 pb-4">
                <div class="grid grid-cols-2 gap-3">
                  <input
                    type="text"
                    value={@receipt_preview.store_name}
                    placeholder={gettext("Store")}
                    phx-blur="update_receipt_field"
                    phx-value-field="store_name"
                    class="w-full rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-[var(--text)] focus:border-[color:var(--accent)] focus:outline-none"
                    style="font-size: var(--t-meta);"
                  />
                  <input
                    type="date"
                    value={Date.to_iso8601(@receipt_preview.date)}
                    phx-blur="update_receipt_field"
                    phx-value-field="date"
                    class="w-full rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-[var(--text)] focus:border-[color:var(--accent)] focus:outline-none"
                    style="font-size: var(--t-meta);"
                  />
                </div>
                <div class="flex items-center gap-2">
                  <input
                    type="number"
                    value={@receipt_preview.total && decimal_display(@receipt_preview.total)}
                    placeholder={gettext("Total (kr)")}
                    phx-blur="update_receipt_field"
                    phx-value-field="total"
                    class="flex-1 rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-[var(--text)] focus:border-[color:var(--accent)] focus:outline-none"
                    style="font-size: var(--t-meta);"
                  />
                  <span class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">kr</span>
                </div>
              </div>
              <p
                class="px-5 pb-2 font-medium text-[color:var(--muted)]"
                style="font-size: var(--t-meta);"
              >
                {gettext("Items")}
              </p>
              <ul class="divide-y divide-[color:var(--hairline)] border-t border-[color:var(--hairline)]">
                <li :for={item <- @receipt_preview.items} class="flex items-start gap-3 px-5 py-3">
                  <div class="grid flex-1 grid-cols-2 gap-2">
                    <input
                      type="text"
                      value={item.name}
                      placeholder={gettext("Name")}
                      phx-blur="update_receipt_item"
                      phx-value-key={item.key}
                      phx-value-field="name"
                      class="col-span-2 w-full rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-[var(--text)] focus:border-[color:var(--accent)] focus:outline-none"
                      style="font-size: var(--t-meta);"
                    />
                    <input
                      type="text"
                      value={item.quantity && decimal_display(item.quantity)}
                      placeholder={gettext("Qty")}
                      phx-blur="update_receipt_item"
                      phx-value-key={item.key}
                      phx-value-field="quantity"
                      class="w-full rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-[var(--text)] focus:border-[color:var(--accent)] focus:outline-none"
                      style="font-size: var(--t-meta);"
                    />
                    <input
                      type="text"
                      value={item.unit}
                      placeholder={gettext("Unit")}
                      phx-blur="update_receipt_item"
                      phx-value-key={item.key}
                      phx-value-field="unit"
                      class="w-full rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-[var(--text)] focus:border-[color:var(--accent)] focus:outline-none"
                      style="font-size: var(--t-meta);"
                    />
                  </div>
                  <button
                    phx-click="remove_receipt_item"
                    phx-value-key={item.key}
                    class="mt-1 inline-flex size-8 items-center justify-center text-[color:var(--subtle)] hover:text-[color:var(--danger)]"
                    aria-label={gettext("Remove")}
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </li>
              </ul>
              <div class="flex gap-3 border-t border-[color:var(--hairline)] px-5 py-4">
                <.button phx-click="confirm_receipt" variant={:primary} size={:lg} full>
                  {gettext("Save receipt")}
                </.button>
                <.button phx-click="discard_receipt" variant={:ghost} size={:lg}>
                  {gettext("Discard")}
                </.button>
              </div>
            </section>
          <% end %>

          <%= cond do %>
            <% @view == :overview -> %>
              <section class="border-t border-[color:var(--hairline)] px-6 py-7 md:px-8">
                <div>
                  <p class="mb-4 font-medium text-[color:var(--muted)]" style="font-size: 15px;">
                    {gettext("Total this month")}
                  </p>
                  <p
                    class="font-semibold tracking-[-0.035em] tabular-nums text-[color:var(--text)]"
                    style="font-size: clamp(38px, 9vw, 48px); line-height: 1;"
                  >
                    {format_money(@total_amt)} kr
                  </p>
                  <p
                    :if={@month_change_pct}
                    class={["mt-3", delta_color(@month_change_pct)]}
                    style="font-size: 14px;"
                  >
                    <span class="font-semibold">{signed_percent(@month_change_pct)}</span> {gettext(
                      "compared with last month"
                    )}
                  </p>
                </div>

                <div class="mt-7 divide-y divide-[color:var(--hairline)] border-y border-[color:var(--hairline)]">
                  <.category_summary
                    label={gettext("Groceries")}
                    sublabel={gettext("Store purchases")}
                    amount={@grocery_amt}
                    pct={@grocery_pct}
                    color="var(--accent)"
                  />
                  <.category_summary
                    label={gettext("Eating out")}
                    sublabel={gettext("Restaurants & cafés")}
                    amount={@dining_amt}
                    pct={@dining_pct}
                    color="var(--warn)"
                  />
                </div>

                <div class="mt-5 grid grid-cols-2 gap-3 rounded-3xl bg-[#f7f5ef] px-4 py-4">
                  <.compact_stat
                    label={gettext("Receipts this month")}
                    value={to_string(@summary.receipt_count)}
                  />
                  <.compact_stat
                    label={gettext("Average receipt")}
                    value={"#{format_money(max(@avg_receipt, 0))} kr"}
                  />
                </div>
              </section>

              <section class="px-6 pb-7 md:px-8">
                <div class="mb-4 flex items-center justify-between">
                  <h2 class="font-medium text-[color:var(--text)]" style="font-size: 15px;">
                    {gettext("Recent purchases")}
                  </h2>
                  <button
                    type="button"
                    phx-click="set_tab"
                    phx-value-tab="receipts"
                    class="text-[color:var(--muted)] transition hover:text-[color:var(--accent)]"
                    style="font-size: 15px;"
                  >
                    {gettext("View all receipts")}
                  </button>
                </div>
                <.purchase_list receipts={@recent_receipts} empty={gettext("No receipts yet")} />
              </section>
            <% @view == :receipts -> %>
              <section class="px-6 py-7 md:px-8">
                <div class="relative overflow-hidden rounded-3xl bg-gradient-to-br from-[#f6f2eb] to-[#fbfaf6] px-5 py-6">
                  <div class="relative z-10">
                    <p
                      class="font-medium text-[color:var(--text)]"
                      style="font-size: 14px;"
                    >
                      {gettext("Groceries — this month")}
                    </p>
                    <p
                      class="mt-4 font-semibold tracking-[-0.025em] tabular-nums text-[color:var(--text)]"
                      style="font-size: 30px;"
                    >
                      {format_money(@grocery_amt)} kr
                    </p>
                    <p class="mt-2 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                      {@grocery_pct}% {gettext("of total food costs")}
                    </p>
                  </div>
                  <img
                    src="/images/cost-grocery-art.png"
                    alt=""
                    class="absolute -right-2 top-2 h-32 w-32 object-contain opacity-90 md:right-6 md:h-36 md:w-36"
                  />
                </div>
              </section>

              <section class="px-6 pb-7 md:px-8">
                <h2
                  class="mb-5 font-medium text-[color:var(--text)]"
                  style="font-size: 15px;"
                >
                  {gettext("Store breakdown")}
                </h2>
                <div class="grid items-center gap-6 md:grid-cols-[190px_1fr]">
                  <.donut total={@grocery_amt} />
                  <.store_list stores={@stores_this_month} empty={gettext("No stores yet")} />
                </div>
              </section>

              <section class="px-6 pb-7 md:px-8">
                <div class="mb-4 flex items-center justify-between">
                  <h2 class="font-medium text-[color:var(--text)]" style="font-size: 15px;">
                    {gettext("Recent purchases")}
                  </h2>
                  <span class="text-[color:var(--muted)]" style="font-size: 13px;">
                    {gettext("View all")}
                  </span>
                </div>
                <.purchase_list receipts={Enum.take(@receipts, 1)} empty={gettext("No receipts yet")} />
              </section>

              <.receipt_entry_panel
                current_user={@current_user}
                receipt_preview={@receipt_preview}
                scanning={@scanning}
                scan_error={@scan_error}
                uploads={@uploads}
              />
            <% @view == :dining -> %>
              <section class="px-6 py-7 md:px-8">
                <div class="relative overflow-hidden rounded-3xl bg-gradient-to-br from-[#f6f2eb] to-[#fbfaf6] px-5 py-6">
                  <div class="relative z-10">
                    <p
                      class="font-medium text-[color:var(--text)]"
                      style="font-size: 14px;"
                    >
                      {gettext("Eating out — this month")}
                    </p>
                    <p
                      class="mt-4 font-semibold tracking-[-0.025em] tabular-nums text-[color:var(--text)]"
                      style="font-size: 30px;"
                    >
                      {format_money(@dining_amt)} kr
                    </p>
                    <p class="mt-2 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                      {@dining_pct}% {gettext("of total food costs")}
                    </p>
                  </div>
                  <img
                    src="/images/cost-dining-art.png"
                    alt=""
                    class="absolute -right-4 top-8 h-28 w-40 object-contain opacity-90 md:right-4 md:h-32 md:w-44"
                  />
                </div>
              </section>

              <section class="px-6 pb-7 md:px-8">
                <%= if @dining_entries == [] do %>
                  <div class="rounded-3xl bg-gradient-to-br from-[#f7f3ed] to-[#fbfaf6] px-6 py-7">
                    <div class="flex items-start gap-5">
                      <.icon name="hero-light-bulb" class="size-8 shrink-0 text-[#9a825c]" />
                      <div>
                        <p
                          class="font-medium text-[color:var(--text)]"
                          style="font-size: 15px;"
                        >
                          {gettext("No dining entries yet")}
                        </p>
                        <p
                          class="mt-2 text-[color:var(--text)]"
                          style="font-size: 13px; line-height: 1.55;"
                        >
                          {gettext("Add a purchase to see statistics here.")}
                        </p>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <h2
                    class="mb-4 font-semibold text-[color:var(--text)]"
                    style="font-size: var(--t-body);"
                  >
                    {gettext("Favourite restaurants")}
                  </h2>
                  <.restaurant_list places={@dining_by_place} />
                <% end %>
              </section>

              <section class="px-6 pb-7 md:px-8">
                <h2
                  class="mb-2 font-semibold text-[color:var(--text)]"
                  style="font-size: var(--t-body);"
                >
                  {gettext("Monthly history")}
                </h2>
                <p
                  class="font-semibold tabular-nums text-[color:var(--text)]"
                  style="font-size: var(--t-h2);"
                >
                  {format_money(@dining_amt)} kr
                </p>
                <p class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("average per month")}
                </p>
                <div
                  class="mt-5 rounded-3xl border border-[color:var(--border)] bg-white/35 px-5 py-6 text-[color:var(--muted)]"
                  style="font-size: var(--t-meta);"
                >
                  {gettext("Monthly dining history is not available yet.")}
                </div>
              </section>

              <.dining_entry_panel current_user={@current_user} />

              <section class="px-6 pb-8 md:px-8">
                <h2
                  class="mb-4 font-semibold text-[color:var(--text)]"
                  style="font-size: var(--t-body);"
                >
                  {gettext("Favourite restaurants")}
                </h2>
                <%= if @dining_entries == [] do %>
                  <div class="rounded-3xl bg-gradient-to-br from-[#f7f3ed] to-[#fbfaf6] px-6 py-8 text-center">
                    <.icon
                      name="hero-building-storefront"
                      class="mx-auto mb-4 size-10 text-[#9a825c]"
                    />
                    <p
                      class="font-semibold text-[color:var(--text)]"
                      style="font-size: var(--t-meta);"
                    >
                      {gettext("No restaurants yet")}
                    </p>
                    <p class="mt-2 text-[color:var(--text)]" style="font-size: var(--t-meta);">
                      {gettext(
                        "Your most visited restaurants will appear here after you log dining purchases."
                      )}
                    </p>
                  </div>
                <% else %>
                  <.restaurant_list places={@dining_by_place} />
                <% end %>
              </section>
          <% end %>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  attr :tabs, :list, required: true
  attr :active, :string, required: true

  defp cost_tabs(assigns) do
    ~H"""
    <nav id="cost-tabs" class="grid grid-cols-3" aria-label={gettext("Cost views")}>
      <button
        :for={tab <- @tabs}
        type="button"
        phx-click="set_tab"
        phx-value-tab={tab.id}
        class={[
          "relative py-4 text-center font-medium transition",
          @active == tab.id && "text-[color:var(--accent)]",
          @active != tab.id && "text-[color:var(--muted)] hover:text-[color:var(--text)]"
        ]}
        style="font-size: 14px;"
      >
        {tab.label}
        <span
          :if={@active == tab.id}
          class="absolute inset-x-2 bottom-0 h-0.5 rounded-full bg-[color:var(--accent)]"
        >
        </span>
      </button>
    </nav>
    """
  end

  attr :label, :string, required: true
  attr :sublabel, :string, required: true
  attr :amount, :integer, required: true
  attr :pct, :integer, required: true
  attr :color, :string, required: true

  defp category_summary(assigns) do
    ~H"""
    <div class="flex items-center gap-4 border-b border-[color:var(--hairline)] py-4.5 last:border-b-0">
      <span class="size-3 rounded-full" style={"background: #{@color};"}></span>
      <div class="min-w-0 flex-1">
        <p class="font-medium text-[color:var(--text)]" style="font-size: 15px;">
          {@label}
        </p>
        <p class="mt-1 text-[color:var(--muted)]" style="font-size: 13px;">{@sublabel}</p>
      </div>
      <p class="font-medium tabular-nums text-[color:var(--text)]" style="font-size: 15px;">
        {format_money(@amount)} kr
      </p>
      <p
        class="w-12 text-right tabular-nums text-[color:var(--muted)]"
        style="font-size: 15px;"
      >
        {@pct}%
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp compact_stat(assigns) do
    ~H"""
    <div class="text-center">
      <p class="text-[color:var(--muted)]" style="font-size: 12px; line-height: 1.25;">{@label}</p>
      <p
        class="mt-2 font-semibold tracking-[-0.02em] tabular-nums text-[color:var(--text)]"
        style="font-size: clamp(18px, 4vw, 22px); line-height: 1;"
      >
        {@value}
      </p>
    </div>
    """
  end

  attr :receipts, :list, required: true
  attr :empty, :string, required: true

  defp purchase_list(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-2xl border border-[color:var(--border)] bg-white/35">
      <%= if @receipts == [] do %>
        <div class="px-5 py-5 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
          {@empty}
        </div>
      <% else %>
        <div
          :for={r <- @receipts}
          class="flex items-center gap-4 border-b border-[color:var(--hairline)] px-4 py-4 last:border-b-0"
        >
          <span
            class="flex size-12 shrink-0 items-center justify-center rounded-full border border-[color:var(--hairline)] bg-white font-bold uppercase"
            style={store_badge_style(r.store_name)}
          >
            {store_initials(r.store_name)}
          </span>
          <span class="min-w-0 flex-1">
            <span
              class="block truncate font-semibold text-[color:var(--text)]"
              style="font-size: var(--t-body);"
            >
              {r.store_name || gettext("Unknown store")}
            </span>
            <span class="mt-1 block text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {Calendar.strftime(r.date, "%d %b")}
            </span>
          </span>
          <span
            class="font-semibold tabular-nums text-[color:var(--text)]"
            style="font-size: var(--t-body);"
          >
            {r.total_amount && "#{format_money(decimal_to_int(r.total_amount))} kr"}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :stores, :list, required: true
  attr :empty, :string, required: true

  defp store_list(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-2xl border border-[color:var(--border)] bg-white/35">
      <%= if @stores == [] do %>
        <div class="px-5 py-5 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
          {@empty}
        </div>
      <% else %>
        <div
          :for={s <- @stores}
          class="grid grid-cols-[auto_1fr_auto_auto] items-center gap-4 border-b border-[color:var(--hairline)] px-4 py-4 last:border-b-0"
        >
          <span
            class="flex size-12 items-center justify-center rounded-full border border-[color:var(--hairline)] bg-white font-bold uppercase"
            style={store_badge_style(s.store)}
          >
            {store_initials(s.store)}
          </span>
          <span class="min-w-0">
            <span
              class="block truncate font-semibold text-[color:var(--text)]"
              style="font-size: var(--t-body);"
            >
              {s.store || gettext("Unknown store")}
            </span>
            <span class="mt-1 block text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {s.count} {gettext("receipts")}
            </span>
          </span>
          <span
            class="font-semibold tabular-nums text-[color:var(--text)]"
            style="font-size: var(--t-body);"
          >
            {format_money(decimal_to_int(s.total))} kr
          </span>
          <span class="w-10 text-right text-[color:var(--muted)]" style="font-size: var(--t-meta);">
            {store_pct(s, @stores)}%
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :current_user, :any, required: true
  attr :receipt_preview, :any, required: true
  attr :scanning, :boolean, required: true
  attr :scan_error, :string, default: nil
  attr :uploads, :map, required: true

  defp receipt_entry_panel(assigns) do
    ~H"""
    <section
      :if={@current_user && @current_user.role in [:member, :admin] && !@receipt_preview}
      class="px-6 pb-8 md:px-8"
    >
      <div class="rounded-3xl bg-gradient-to-br from-[#f7f3ed] to-[#fbfaf6] p-5">
        <%= if @scanning do %>
          <div
            class="flex items-center justify-center gap-2 py-4 text-[color:var(--muted)]"
            style="font-size: var(--t-meta);"
          >
            <.icon name="hero-arrow-path" class="size-4 animate-spin" /> {gettext("Scanning receipt…")}
          </div>
        <% else %>
          <form phx-change="validate_upload" class="mb-4">
            <.live_file_input upload={@uploads.receipt_photo} class="hidden" />
            <label
              for={@uploads.receipt_photo.ref}
              class="flex cursor-pointer items-center justify-center gap-2 rounded-2xl border border-dashed border-[color:var(--border)] bg-white/45 py-3 text-[color:var(--muted)] transition hover:border-[color:var(--accent)] hover:text-[var(--text)]"
              style="font-size: var(--t-meta);"
            >
              <.icon name="hero-camera" class="size-4" /> {gettext("Scan receipt photo")}
            </label>
          </form>
          <p
            :if={@scan_error}
            class="mb-3 rounded-2xl bg-red-50 px-3 py-2 text-[color:var(--danger)]"
            style="font-size: var(--t-meta);"
          >
            {@scan_error}
          </p>
          <form phx-submit="save_manual_receipt" class="space-y-3">
            <p class="font-medium text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {gettext("Or enter manually")}
            </p>
            <div class="flex gap-3">
              <div class="flex-1">
                <.field
                  name="date"
                  type="date"
                  label={gettext("Date")}
                  value={Date.to_iso8601(Date.utc_today())}
                  required
                />
              </div>
              <div class="flex-1">
                <.field name="store_name" label={gettext("Store")} placeholder="ICA Maxi" />
              </div>
            </div>
            <.field
              name="total_amount"
              type="number"
              label={gettext("Total (kr)")}
              placeholder="0.00"
              required
            />
            <.button type="submit" variant={:secondary} size={:md} full>
              {gettext("Save receipt")}
            </.button>
          </form>
        <% end %>
      </div>
    </section>
    """
  end

  attr :current_user, :any, required: true

  defp dining_entry_panel(assigns) do
    ~H"""
    <section
      :if={@current_user && @current_user.role in [:member, :admin]}
      id="dining-entry-form"
      class="px-6 pb-8 md:px-8"
    >
      <div class="rounded-3xl bg-gradient-to-br from-[#f7f3ed] to-[#fbfaf6] p-5">
        <form phx-submit="log_dining_out" class="space-y-3">
          <p class="font-semibold text-[color:var(--text)]" style="font-size: var(--t-body);">
            {gettext("Add dining purchase")}
          </p>
          <div class="flex gap-3">
            <div class="flex-1">
              <.field
                name="date"
                type="date"
                label={gettext("Date")}
                value={Date.to_iso8601(Date.utc_today())}
                required
              />
            </div>
            <div class="flex-1">
              <.field name="num_people" type="number" label={gettext("People")} value="1" />
            </div>
          </div>
          <.field
            name="description"
            label={gettext("Restaurant / occasion")}
            placeholder={gettext("Sushi night")}
          />
          <.field
            name="total_amount"
            type="number"
            label={gettext("Total (kr)")}
            placeholder="0.00"
            required
          />
          <.button type="submit" variant={:primary} size={:lg} full>{gettext("Log dining")}</.button>
        </form>
      </div>
    </section>
    """
  end

  attr :total, :integer, required: true

  defp donut(assigns) do
    ~H"""
    <div
      class="relative mx-auto size-44 rounded-full"
      style="background: conic-gradient(#1f5f34 0 41%, #4f8457 41% 61%, #77a277 61% 76%, #8caf87 76% 90%, #adc5a6 90% 95%, #d8e3d3 95% 100%);"
    >
      <div
        class="absolute inset-10 flex items-center justify-center rounded-full bg-[var(--surface)] text-center font-bold tabular-nums text-[color:var(--text)]"
        style="font-size: var(--t-body);"
      >
        {format_money(@total)} kr
      </div>
    </div>
    """
  end

  attr :places, :list, required: true

  defp restaurant_list(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-2xl border border-[color:var(--border)] bg-white/35">
      <div
        :for={p <- @places}
        class="flex items-center gap-4 border-b border-[color:var(--hairline)] px-4 py-4 last:border-b-0"
      >
        <span class="flex size-11 items-center justify-center rounded-full bg-[#f4eee4] font-bold uppercase text-[#9a6a3c]">
          {store_initials(p.place)}
        </span>
        <span class="min-w-0 flex-1">
          <span
            class="block truncate font-semibold text-[color:var(--text)]"
            style="font-size: var(--t-body);"
          >
            {p.place || gettext("Unknown place")}
          </span>
          <span class="mt-1 block text-[color:var(--muted)]" style="font-size: var(--t-meta);">
            {p.count} {gettext("visits")}
          </span>
        </span>
        <span
          class="font-semibold tabular-nums text-[color:var(--text)]"
          style="font-size: var(--t-body);"
        >
          {format_money(decimal_to_int(p.total))} kr
        </span>
      </div>
    </div>
    """
  end

  defp delta_color(n) when n > 0, do: "text-[color:var(--warn)]"
  defp delta_color(_), do: "text-[color:var(--accent)]"

  defp signed_percent(n) when n > 0, do: "+#{n}%"
  defp signed_percent(n), do: "#{n}%"

  defp store_initials(nil), do: "?"

  defp store_initials(name) do
    name
    |> String.split(" ", trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join("")
  end

  defp store_badge_style(nil), do: "color: var(--accent);"

  defp store_badge_style(name) do
    cond do
      String.match?(String.downcase(name), ~r/ica/) -> "color: #e1261c;"
      String.match?(String.downcase(name), ~r/coop/) -> "color: #00a443;"
      String.match?(String.downcase(name), ~r/willy/) -> "color: #1f2933;"
      true -> "color: var(--accent);"
    end
  end

  defp store_pct(store, stores) do
    total = Enum.reduce(stores, 0, fn s, acc -> acc + decimal_to_int(s.total) end)

    if total > 0,
      do: round(decimal_to_int(store.total) * 100 / total),
      else: 0
  end

  defp decimal_to_int(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d, 0))
  defp decimal_to_int(n) when is_integer(n), do: n
  defp decimal_to_int(n) when is_float(n), do: trunc(n)
  defp decimal_to_int(_), do: 0

  defp format_money(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(" ", &Enum.join/1)
    |> String.reverse()
  end

  defp decimal_display(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_display(n) when is_float(n), do: to_string(n)
  defp decimal_display(n) when is_integer(n), do: to_string(n)
  defp decimal_display(_), do: ""

  defp parse_decimal(""), do: nil
  defp parse_decimal(nil), do: nil

  defp parse_decimal(s) do
    case Decimal.parse(s) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_date(""), do: Date.utc_today()
  defp parse_date(nil), do: Date.utc_today()

  defp parse_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> Date.utc_today()
    end
  end

  defp nilify(""), do: nil
  defp nilify(v), do: v
end
