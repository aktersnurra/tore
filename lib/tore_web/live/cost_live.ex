defmodule ToreWeb.CostLive do
  use ToreWeb, :live_view

  alias Tore.Capture.Dispatch
  alias Tore.{Costs, Household}

  @recent_receipts 5

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(scanning: false)
      |> load_costs()
      |> allow_upload(:receipt_photo,
        accept: ~w(.jpg .jpeg .png .webp .heic),
        max_entries: 1,
        max_file_size: 10_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  defp load_costs(socket) do
    today = Date.utc_today()
    last_month = today |> Date.beginning_of_month() |> Date.add(-1)

    assign(socket,
      month_total: Costs.monthly_total(today.year, today.month),
      last_month_total: Costs.monthly_total(last_month.year, last_month.month),
      receipts: Costs.recent_receipts(@recent_receipts),
      dining: Costs.dining_out_in_month(today.year, today.month)
    )
  end

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("save_receipt", %{"total_amount" => ""}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Enter the total."))}
  end

  def handle_event("save_receipt", params, socket) do
    attrs = %{
      date: params["date"],
      store_name: params["store_name"],
      total_amount: params["total_amount"],
      user_id: socket.assigns.current_user.id
    }

    case Costs.log_receipt(attrs) do
      {:ok, _receipt} ->
        {:noreply, socket |> load_costs() |> put_flash(:info, gettext("Receipt saved"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save receipt"))}
    end
  end

  def handle_progress(:receipt_photo, entry, socket) do
    if entry.done? do
      image =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      ctx = %{
        household_id: Household.get_household!().id,
        user_id: socket.assigns.current_user.id
      }

      pid = self()
      locale = Gettext.get_locale(ToreWeb.Gettext)

      Task.start(fn ->
        # Gettext's locale is per process, so the replies need it set here too.
        Gettext.put_locale(ToreWeb.Gettext, locale)
        send(pid, {:receipt_read, Dispatch.ingest_receipt(image, ctx)})
      end)

      {:noreply, assign(socket, scanning: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:receipt_read, %{stream_id: stream_id}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/runs/#{stream_id}?from=/settings/costs")}
  end

  # A duplicate photo or a failure: the reply says which.
  def handle_info({:receipt_read, %{text: text}}, socket) do
    {:noreply, socket |> assign(scanning: false) |> put_flash(:error, text)}
  end

  # Every signed-in page hears about runs, for the review count.
  def handle_info({:run_event, _stream_id, _event}, socket), do: {:noreply, socket}
  def handle_info({:run_state_changed, _stream_id, _state}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, month_change: month_change(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={assigns[:current_scope]}
      current_path={assigns[:current_path] || "/settings/costs"}
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

          <section class="border-t border-[color:var(--hairline)] px-6 py-7 md:px-8">
            <p class="mb-4 font-medium text-[color:var(--muted)]" style="font-size: 15px;">
              {gettext("Total this month")}
            </p>
            <p
              id="month-total"
              class="font-semibold tracking-[-0.035em] tabular-nums text-[color:var(--text)]"
              style="font-size: clamp(38px, 9vw, 48px); line-height: 1;"
            >
              {format_money(@month_total)} kr
            </p>
            <p
              :if={@month_change}
              class={["mt-3", delta_color(@month_change)]}
              style="font-size: 14px;"
            >
              <span class="font-semibold">{signed_percent(@month_change)}</span> {gettext(
                "compared with last month"
              )}
            </p>
          </section>

          <.cost_section id="recent-receipts" title={gettext("Recent receipts")}>
            <.cost_row
              :for={r <- @receipts}
              title={r.store_name || gettext("Unknown store")}
              date={r.date}
              amount={r.total_amount}
            />
            <.empty_row :if={@receipts == []} text={gettext("No receipts yet")} />
          </.cost_section>

          <.cost_section id="eating-out" title={gettext("Eating out this month")}>
            <.cost_row
              :for={d <- @dining}
              title={d.description || gettext("Eating out")}
              date={d.date}
              amount={d.total_amount}
            />
            <.empty_row
              :if={@dining == []}
              text={gettext("Nothing yet. Mark a day as eating out in the plan.")}
            />
          </.cost_section>

          <.add_receipt
            scanning={@scanning}
            uploads={@uploads}
          />
        </div>
      </.page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp cost_section(assigns) do
    ~H"""
    <section id={@id} class="px-6 pb-7 md:px-8">
      <h2 class="mb-4 font-medium text-[color:var(--text)]" style="font-size: 15px;">{@title}</h2>
      <div class="overflow-hidden rounded-2xl border border-[color:var(--border)] bg-white/35">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :date, Date, required: true
  attr :amount, :any, required: true

  defp cost_row(assigns) do
    ~H"""
    <div class="flex items-center gap-4 border-b border-[color:var(--hairline)] px-4 py-3 last:border-b-0">
      <span class="min-w-0 flex-1">
        <span
          class="block truncate font-medium text-[color:var(--text)]"
          style="font-size: var(--t-body);"
        >
          {@title}
        </span>
        <span class="mt-0.5 block text-[color:var(--muted)]" style="font-size: var(--t-meta);">
          {Calendar.strftime(@date, "%-d/%-m")}
        </span>
      </span>
      <span
        :if={@amount}
        class="font-medium tabular-nums text-[color:var(--text)]"
        style="font-size: var(--t-body);"
      >
        {format_money(@amount)} kr
      </span>
    </div>
    """
  end

  attr :text, :string, required: true

  defp empty_row(assigns) do
    ~H"""
    <div class="px-5 py-5 text-[color:var(--muted)]" style="font-size: var(--t-meta);">{@text}</div>
    """
  end

  attr :scanning, :boolean, required: true
  attr :uploads, :map, required: true

  defp add_receipt(assigns) do
    ~H"""
    <section id="add-receipt" class="px-6 pb-8 md:px-8">
      <div class="rounded-3xl bg-gradient-to-br from-[#f7f3ed] to-[#fbfaf6] p-5">
        <%= if @scanning do %>
          <div
            class="flex items-center justify-center gap-2 py-4 text-[color:var(--muted)]"
            style="font-size: var(--t-meta);"
          >
            <.icon name="hero-arrow-path" class="size-4 animate-spin" /> {gettext("Scanning receipt…")}
          </div>
        <% else %>
          <form id="receipt-photo-form" phx-change="validate_upload" class="mb-4">
            <.live_file_input upload={@uploads.receipt_photo} class="hidden" />
            <label
              for={@uploads.receipt_photo.ref}
              class="flex cursor-pointer items-center justify-center gap-2 rounded-2xl border border-dashed border-[color:var(--border)] bg-white/45 py-3 text-[color:var(--muted)] transition hover:border-[color:var(--accent)] hover:text-[var(--text)]"
              style="font-size: var(--t-meta);"
            >
              <.icon name="hero-camera" class="size-4" /> {gettext("Scan receipt photo")}
            </label>
          </form>
          <form id="receipt-form" phx-submit="save_receipt" class="space-y-3">
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
              step="0.01"
              min="0"
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

  defp month_change(%{month_total: total, last_month_total: last}) do
    if Decimal.gt?(last, 0) do
      total
      |> Decimal.sub(last)
      |> Decimal.mult(100)
      |> Decimal.div(last)
      |> Decimal.round(0)
      |> Decimal.to_integer()
    end
  end

  defp delta_color(n) when n > 0, do: "text-[color:var(--warn)]"
  defp delta_color(_), do: "text-[color:var(--accent)]"

  defp signed_percent(n) when n > 0, do: "+#{n}%"
  defp signed_percent(n), do: "#{n}%"

  defp format_money(%Decimal{} = amount) do
    amount
    |> Decimal.round(0)
    |> Decimal.to_integer()
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(" ", &Enum.join/1)
    |> String.reverse()
  end
end
