defmodule ToreWeb.BudgetLive do
  @moduledoc """
  Veckobudget: where this week lands against the budget, the eight weeks up to it, where the
  money went, and the receipts (ui.md, "Veckobudget"). Everything is read from
  `Tore.Budget.page/2`; the budget is changed where it's shown.
  """
  use ToreWeb, :live_view

  alias Tore.{Budget, Costs, Money, Streams}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(editing: false, budget_error: nil, budget_text: "", receipt: nil, picking: nil)
     |> load()}
  end

  # A receipt opens over the page: beside it on a laptop, over all of it on a phone.
  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Costs.get_receipt(socket.assigns.current_scope, String.to_integer(id)) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/budget")}
      receipt -> {:noreply, assign(socket, receipt: receipt, picking: nil)}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, receipt: nil, picking: nil)}

  defp load(socket) do
    week = Streams.monday(Tore.Clock.today())
    assign(socket, page: Budget.page(socket.assigns.current_scope, week))
  end

  @impl true
  def handle_event("edit_budget", _, socket) do
    budget = socket.assigns.page.status.budget

    {:noreply,
     assign(socket, editing: true, budget_error: nil, budget_text: budget && Money.format(budget))}
  end

  def handle_event("close_receipt", _, socket),
    do: {:noreply, push_patch(socket, to: ~p"/budget")}

  # Tapping a line opens where it can move; tapping it again closes that.
  def handle_event("pick_line", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, picking: if(socket.assigns.picking == id, do: nil, else: id))}
  end

  def handle_event("move_line", %{"id" => id, "section" => section}, socket) do
    {:ok, _} =
      Costs.set_line_section(socket.assigns.current_scope, String.to_integer(id), section)

    {:noreply, socket |> assign(picking: nil) |> reload_receipt() |> load()}
  end

  def handle_event("move_week", _, socket) do
    {:ok, _} = Costs.move_receipt_week(socket.assigns.current_scope, socket.assigns.receipt.id)
    {:noreply, socket |> reload_receipt() |> load()}
  end

  def handle_event("cancel_budget", _, socket),
    do: {:noreply, assign(socket, editing: false, budget_error: nil)}

  # The number shown is the number typed: it becomes the household's budget, and a week's own
  # budget, set by asking Tore, gives way to it. Blank means no budget.
  def handle_event("set_budget", %{"amount" => text}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, amount} <- parse_amount(text),
         :ok <- Budget.set_default(scope, amount),
         :ok <- Budget.set_week(scope, socket.assigns.page.week_start, nil) do
      {:noreply, socket |> assign(editing: false, budget_error: nil) |> load()}
    else
      _ ->
        {:noreply,
         assign(socket, budget_error: gettext("Enter an amount in kronor."), budget_text: text)}
    end
  end

  defp reload_receipt(socket),
    do:
      assign(socket,
        receipt: Costs.get_receipt(socket.assigns.current_scope, socket.assigns.receipt.id)
      )

  # Spaces and a decimal comma are fine ("2 000", "1999,50").
  defp parse_amount(text) do
    case text |> String.replace(~r/\s/u, "") |> String.replace(",", ".") do
      "" ->
        {:ok, nil}

      clean ->
        case Decimal.parse(clean) do
          {amount, ""} -> if Decimal.gt?(amount, 0), do: {:ok, amount}, else: :error
          _ -> :error
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:lg}>
        <.top_bar title={gettext("Weekly budget")} />

        <header class="pt-2">
          <p class="t-eyebrow">{week_line(@page.week_start)}</p>
          <h1
            id={"lands-#{@page.status.expected}"}
            data-role="lands"
            class="t-title settle mt-1"
          >
            {gettext("The week lands around %{amount} kr",
              amount: Money.format(@page.status.expected)
            )}
          </h1>
          <.budget_tag status={@page.status} />
        </header>

        <div class="mt-6 grid grid-cols-2 gap-x-6 gap-y-5 lg:grid-cols-4">
          <div data-role="kpi-budget">
            <p class="t-eyebrow">{gettext("Budget")}</p>
            <form
              :if={@editing}
              data-role="budget-form"
              phx-submit="set_budget"
              phx-window-keydown="cancel_budget"
              phx-key="Escape"
              class="mt-0.5 flex items-center gap-1.5"
            >
              <input
                id="budget-input"
                type="text"
                name="amount"
                inputmode="decimal"
                value={@budget_text}
                placeholder={gettext("No budget")}
                aria-label={gettext("Weekly budget in kronor")}
                aria-invalid={@budget_error && "true"}
                phx-mounted={JS.focus()}
                class={[
                  "num h-9 w-24 min-w-0 rounded-[var(--r-sm)] border bg-[var(--surface)] px-2 font-semibold",
                  @budget_error && "border-[color:var(--warn)]",
                  !@budget_error && "border-[color:var(--hairline)]"
                ]}
                style="font-size: 18px;"
              />
              <button type="submit" phx-disable-with="…" class="press text-[13px] font-semibold">
                {gettext("Save")}
              </button>
            </form>
            <button
              :if={!@editing}
              type="button"
              id={"budget-#{@page.status.budget}"}
              phx-click="edit_budget"
              aria-label={gettext("Change the weekly budget")}
              class="press settle num group mt-0.5 flex items-center gap-1.5 rounded-[var(--r-sm)] font-semibold"
              style="font-size: 22px; line-height: 36px;"
            >
              {if @page.status.budget,
                do: "#{Money.format(@page.status.budget)} kr",
                else: gettext("None")}
              <.icon
                name="ph-pencil-simple"
                class="size-4 text-[color:var(--muted)] transition-colors group-hover:text-[color:var(--text)]"
              />
            </button>
            <p
              :if={@budget_error}
              class="settle mt-1 text-[color:var(--warn)]"
              style="font-size: 12.5px;"
              role="alert"
            >
              {@budget_error}
            </p>
            <p
              :if={!@budget_error}
              class="mt-0.5 text-[color:var(--muted)]"
              style="font-size: 12.5px;"
            >
              {gettext("a week")}
            </p>
          </div>
          <.kpi
            role="kpi-paid"
            label={gettext("Paid so far")}
            value={"#{Money.format(@page.paid)} kr"}
          >
            {ngettext("%{count} receipt", "%{count} receipts", this_week_receipts(@page))}
          </.kpi>
          <.kpi
            role="kpi-left"
            label={gettext("Left by the plan")}
            value={"#{Money.format(@page.left)} kr"}
          >
            {open_line(@page.status)}
          </.kpi>
          <.kpi
            role="kpi-average"
            label={gettext("Average a week")}
            value={if @page.average, do: "#{Money.format(@page.average)} kr", else: "–"}
          >
            {average_line(@page)}
          </.kpi>
        </div>

        <%!-- On a laptop the chart sits beside where the money went, at about a phone's scale. --%>
        <div class="mt-9 grid gap-9 lg:grid-cols-2 lg:gap-x-12">
          <section>
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h2 class="t-head">{gettext("Eight weeks")}</h2>
              <div class="key" aria-hidden="true">
                <span><i class="past"></i>{gettext("Earlier")}</span>
                <span><i class="now"></i>{gettext("This week")}</span>
                <span><i class="exp"></i>{gettext("Expected")}</span>
              </div>
            </div>
            <.chart page={@page} />
          </section>

          <section class="sections">
            <h2 class="t-head">{gettext("Where the money went")}</h2>
            <p
              :if={@page.sections != []}
              class="mt-0.5 mb-2 text-[color:var(--muted)]"
              style="font-size: 13px;"
            >
              {sections_line(@page)}
            </p>
            <p
              :if={@page.sections == []}
              class="mt-1.5 text-[color:var(--muted)]"
              style="font-size: 15px;"
            >
              {gettext("No receipt lines to split up in these weeks yet.")}
            </p>
            <.section_row
              :for={section <- @page.sections}
              section={section}
              total={sections_total(@page.sections)}
              top={hd(@page.sections).total}
            />
          </section>

          <section :if={@page.receipts != []}>
            <h2 class="t-head">{gettext("Receipts")}</h2>
            <div class="mt-2">
              <.link
                :for={receipt <- @page.receipts}
                patch={~p"/budget/receipts/#{receipt.id}"}
                data-role="receipt"
                class="row-hover press press-soft -mx-1.5 flex min-h-11 items-center gap-2.5 rounded-[var(--r-sm)] border-b border-[color:var(--hairline)] px-1.5"
                style="font-size: 14.5px;"
              >
                <span class="w-20 shrink-0 text-[color:var(--muted)]" style="font-size: 13px;">
                  {short_date(receipt.date)}
                </span>
                <span class="store-i" aria-hidden="true">{initial(receipt.store_name)}</span>
                <span class="min-w-0 flex-1 truncate">
                  {receipt.store_name || gettext("Receipt")}
                </span>
                <span class="num font-medium">
                  {Money.format(receipt.total_amount || Decimal.new(0))} kr
                </span>
              </.link>
            </div>
          </section>
        </div>
      </.page>
      <.receipt_sheet :if={@receipt} receipt={@receipt} picking={@picking} />
    </Layouts.app>
    """
  end

  attr :receipt, :map, required: true
  attr :picking, :integer, default: nil

  defp receipt_sheet(assigns) do
    assigns = assign(assigns, groups: receipt_groups(assigns.receipt.line_items))

    ~H"""
    <div
      class="scrim fixed inset-0 z-40 hidden bg-[rgb(15_15_15/0.18)] lg:block"
      phx-click="close_receipt"
      phx-remove={JS.hide(time: 150)}
      aria-hidden="true"
    >
    </div>
    <aside
      data-role="receipt-sheet"
      aria-label={gettext("Receipt")}
      phx-window-keydown="close_receipt"
      phx-key="Escape"
      phx-remove={
        JS.hide(
          transition:
            {"transition-transform ease-in duration-150", "translate-x-0", "translate-x-full"},
          time: 150
        )
      }
      class="peek fixed inset-0 z-50 overflow-y-auto bg-[var(--bg)] lg:left-auto lg:w-[470px] lg:shadow-[var(--shadow-pop)]"
    >
      <div class="flex h-14 items-center px-4">
        <button
          type="button"
          phx-click="close_receipt"
          data-role="close-receipt"
          aria-label={gettext("Close")}
          class="icon-btn press -ml-2"
        >
          <.icon name="ph-caret-left" class="size-5 lg:hidden" />
          <.icon name="ph-x" class="hidden size-5 lg:block" />
        </button>
        <span class="ml-1 font-medium" style="font-size: 15px;">{gettext("Receipt")}</span>
      </div>
      <div class="px-5 pb-10 lg:px-7">
        <h2 class="t-title">{@receipt.store_name || gettext("Receipt")}</h2>
        <dl class="mt-4 grid grid-cols-[7rem_1fr] gap-y-2" style="font-size: 14.5px;">
          <dt class="flex items-center gap-2 text-[color:var(--muted)]">
            <.icon name="ph-storefront" class="size-4" />{gettext("Store")}
          </dt>
          <dd class="flex items-center gap-2">
            <span class="store-i" aria-hidden="true">{initial(@receipt.store_name)}</span>
            {@receipt.store_name || "–"}
          </dd>
          <dt class="flex items-center gap-2 text-[color:var(--muted)]">
            <.icon name="ph-calendar-blank" class="size-4" />{gettext("Date")}
          </dt>
          <dd>{ToreWeb.Dates.long(@receipt.date)}</dd>
          <dt class="flex items-center gap-2 text-[color:var(--muted)]">
            <.icon name="ph-tag" class="size-4" />{gettext("Week")}
          </dt>
          <dd>
            <button
              type="button"
              id={"receipt-week-#{@receipt.week_start}"}
              phx-click="move_week"
              data-role="receipt-week"
              aria-label={gettext("Count it towards the other week")}
              class="tag tag-grey press settle phx-click-loading:opacity-60"
            >
              {gettext("Week %{n}", n: Streams.week_number(@receipt.week_start))}
              <.icon name="ph-arrows-left-right" />
            </button>
          </dd>
          <dt class="flex items-center gap-2 text-[color:var(--muted)]">
            <.icon name="ph-shopping-cart" class="size-4" />{gettext("Total")}
          </dt>
          <dd class="num font-semibold">
            {Money.format(@receipt.total_amount || Decimal.new(0))} kr
          </dd>
        </dl>

        <p :if={@groups == []} class="mt-6 text-[color:var(--muted)]" style="font-size: 15px;">
          {gettext("This receipt has no lines.")}
        </p>
        <section :for={{section, lines, subtotal} <- @groups} data-role="receipt-group" class="mt-6">
          <div class="flex items-center justify-between">
            <span class={"tag tag-#{ToreWeb.Look.section_tint(section)}"}>
              {ToreWeb.Look.section_label(section)}
            </span>
            <span class="num text-[color:var(--muted)]" style="font-size: 13px;">
              {ore(subtotal)}
            </span>
          </div>
          <div :for={line <- lines} class="relative border-b border-[color:var(--hairline)]">
            <button
              type="button"
              phx-click="pick_line"
              phx-value-id={line.id}
              data-role="receipt-line"
              aria-expanded={to_string(@picking == line.id)}
              class="row-hover press press-soft flex min-h-11 w-full items-center gap-3 rounded-[var(--r-sm)] text-left"
              style="font-size: 14.5px;"
            >
              <span class="min-w-0 flex-1 truncate">
                {line.product_name}
                <span
                  :if={amount(line) != ""}
                  class="ml-1 text-[color:var(--muted)]"
                  style="font-size: 13px;"
                >
                  {amount(line)}
                </span>
              </span>
              <span class="num">{line.total_price && ore(line.total_price)}</span>
            </button>
            <div
              :if={@picking == line.id}
              role="listbox"
              aria-label={gettext("Section for %{name}", name: line.product_name)}
              class="settle mb-2 max-h-72 overflow-y-auto rounded-[var(--r-lg)] bg-[var(--surface)] p-1.5 shadow-[var(--shadow-card)]"
            >
              <p class="px-2 py-1 font-semibold" style="font-size: 12px;">
                {gettext("Move to")}
              </p>
              <button
                :for={option <- Tore.Recipes.Ingredient.sections()}
                type="button"
                role="option"
                aria-selected={to_string(option == (line.category || "other"))}
                phx-click="move_line"
                phx-value-id={line.id}
                phx-value-section={option}
                data-role="move-to"
                class="row-hover press press-soft flex h-9 w-full items-center justify-between rounded-[var(--r-sm)] px-2 phx-click-loading:opacity-60"
              >
                <span class={"tag tag-#{ToreWeb.Look.section_tint(option)}"}>
                  {ToreWeb.Look.section_label(option)}
                </span>
                <.icon :if={option == (line.category || "other")} name="ph-check" class="size-4" />
              </button>
            </div>
          </div>
        </section>
      </div>
    </aside>
    """
  end

  # A receipt's lines by section, the costliest section first.
  defp receipt_groups(lines) do
    lines
    |> Enum.group_by(&(&1.category || "other"))
    |> Enum.map(fn {section, lines} ->
      {section, lines, Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.total_price || 0, &2))}
    end)
    |> Enum.sort_by(&elem(&1, 2), {:desc, Decimal})
  end

  # "109,00": a receipt's own amounts, öre and all.
  defp ore(amount),
    do: amount |> Decimal.round(2) |> Decimal.to_string(:normal) |> String.replace(".", ",")

  defp amount(%{quantity: nil, unit: nil}), do: ""
  defp amount(%{quantity: nil, unit: unit}), do: unit

  defp amount(%{quantity: qty, unit: unit}) do
    qty = qty |> Decimal.normalize() |> Decimal.to_string(:normal) |> String.replace(".", ",")
    String.trim("#{qty} #{unit}")
  end

  attr :status, :map, required: true

  defp budget_tag(%{status: %{budget: nil}} = assigns), do: ~H""

  defp budget_tag(assigns) do
    under = Decimal.sub(assigns.status.budget, assigns.status.expected)
    assigns = assign(assigns, under: under, over?: Decimal.lt?(under, 0))

    ~H"""
    <p class="mt-2.5">
      <span
        id={"budget-tag-#{@under}"}
        data-role="budget-tag"
        class={["tag settle", if(@over?, do: "tag-red", else: "tag-green")]}
      >
        <.icon name={if @over?, do: "ph-warning-circle", else: "ph-check"} />
        {if @over?,
          do: gettext("%{amount} kr over budget", amount: Money.format(Decimal.abs(@under))),
          else: gettext("%{amount} kr under budget", amount: Money.format(@under))}
      </span>
    </p>
    """
  end

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  slot :inner_block, required: true

  defp kpi(assigns) do
    ~H"""
    <div data-role={@role}>
      <p class="t-eyebrow">{@label}</p>
      <p class="num mt-0.5 font-semibold" style="font-size: 22px; line-height: 36px;">{@value}</p>
      <p class="mt-0.5 text-[color:var(--muted)]" style="font-size: 12.5px;">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :total, :any, required: true
  attr :top, :any, required: true

  # A section's row opens to what was bought most in it.
  defp section_row(assigns) do
    ~H"""
    <details data-role="section" class="border-b border-[color:var(--hairline)]">
      <summary class="rk row-hover press press-soft" style="font-size: 14.5px;">
        <.icon name="ph-caret-right" class="arrow size-3.5 text-[color:var(--muted)]" />
        <span data-role="section-name" class="truncate">
          {ToreWeb.Look.section_label(@section.section)}
        </span>
        <span>
          <span
            class="tr"
            style={"width: #{share(@section.total, @top)}%; background: var(--tag-#{ToreWeb.Look.section_tint(@section.section)}-ink);"}
          >
          </span>
        </span>
        <span class="num font-medium">{Money.format(@section.total)} kr</span>
        <span class="num text-right text-[color:var(--muted)]" style="font-size: 13px;">
          {share(@section.total, @total)} %
        </span>
      </summary>
      <div class="pb-2">
        <div :for={item <- @section.items} data-role="section-item" class="rki">
          <span class="truncate">{item.name}</span>
          <span class="text-[color:var(--muted)]" style="font-size: 13px;">
            {ngettext("%{count} time", "%{count} times", item.times)}
          </span>
          <span class="num text-right">{Money.format(item.total)} kr</span>
        </div>
      </div>
    </details>
    """
  end

  attr :page, :map, required: true

  # Eight weeks of what was paid, in one sage hue. This week is the strong bar, with what the plan
  # still expects paler above it; a week over its budget shows only as its red number.
  defp chart(assigns) do
    %{page: page} = assigns
    expected = page.status.expected
    budget = page.status.budget

    top =
      [expected, budget | Enum.map(page.weeks, & &1.paid)]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(Decimal, fn -> Decimal.new(0) end)
      |> ceiling()

    y = fn amount -> 128 - 110 * Decimal.to_float(amount) / top end
    last = length(page.weeks) - 1

    bars =
      for {week, i} <- Enum.with_index(page.weeks) do
        x = 42 + i * 34.75
        now? = i == last

        %{
          i: i,
          x: x,
          mid: x + 17.4,
          week: week,
          now?: now?,
          paid_y: week.paid && y.(week.paid),
          exp_y: now? && Decimal.gt?(expected, page.paid) && y.(expected),
          title: bar_title(week, now?, expected)
        }
      end

    assigns =
      assign(assigns,
        bars: bars,
        ticks: for(n <- 0..2, do: {top * n / 2, y.(Decimal.from_float(top * n / 2))}),
        budget_y: budget && y.(budget),
        budget: budget,
        expected: expected
      )

    ~H"""
    <div class="chart mt-3" data-role="chart">
      <svg viewBox="0 0 324 152" class="w-full" role="img" aria-label={chart_label(@page)}>
        <g :for={{value, ty} <- @ticks}>
          <line class="grid" x1="42" x2="320" y1={ty} y2={ty} />
          <text class="ax num" x="36" y={ty + 3.5} text-anchor="end">
            {Money.format(Decimal.from_float(value))}
          </text>
        </g>
        <g :for={bar <- @bars} data-role="chart-week" style={"--i: #{bar.i}"}>
          <title>{bar.title}</title>
          <rect class="hit" x={bar.x} y="18" width="34.75" height="110" />
          <rect
            :if={bar.exp_y}
            class="fc"
            x={bar.mid - 8.2}
            y={bar.exp_y}
            width="16.4"
            height={128 - bar.exp_y}
            rx="4"
          />
          <path
            :if={bar.paid_y}
            class={["b", bar.now? && "now", bar.week.over? && "over"]}
            d={bar_path(bar.mid, bar.paid_y)}
          />
          <text
            :if={bar.week.over? and !bar.now?}
            class="lab over num"
            x={bar.mid}
            y={bar.paid_y - 5}
            text-anchor="middle"
          >
            {Money.format(bar.week.paid)}
          </text>
          <text
            :if={bar.now?}
            class="lab now num"
            x={bar.mid}
            y={(bar.exp_y || bar.paid_y || 128) - 5}
            text-anchor="middle"
          >
            ≈{Money.format(@expected)}
          </text>
          <text class={["ax", bar.now? && "now"]} x={bar.mid} y="146" text-anchor="middle">
            v{Streams.week_number(bar.week.week_start)}
          </text>
        </g>
        <g :if={@budget_y}>
          <line class="bud" x1="42" x2="320" y1={@budget_y} y2={@budget_y} />
          <text class="bud-l num" x="44" y={@budget_y - 5} text-anchor="start">
            {gettext("Budget %{amount}", amount: Money.format(@budget))}
          </text>
        </g>
      </svg>
      <%!-- The pale bars are quiet on purpose; their numbers are here for a screen reader. --%>
      <table class="sr-only">
        <caption>{chart_label(@page)}</caption>
        <tr :for={bar <- @bars}>
          <th scope="row">{gettext("Week %{n}", n: Streams.week_number(bar.week.week_start))}</th>
          <td>{bar.title}</td>
        </tr>
      </table>
    </div>
    """
  end

  # The chart's top: the largest amount rounded up to a step that gives at most three gridlines.
  defp ceiling(max) do
    max = Decimal.to_float(max)
    step = Enum.find([100, 250, 500, 1000, 2500, 5000, 10_000], 20_000, &(max / &1 <= 2))
    if max == 0, do: 1000.0, else: Float.ceil(max / step) * step * 1.0
  end

  # A bar 17.9 wide, its top corners rounded, standing on the baseline.
  defp bar_path(mid, top) do
    l = mid - 8.95
    r = mid + 8.95
    top = min(top, 124)

    "M#{f(l)},128 V#{f(top + 4)} Q#{f(l)},#{f(top)} #{f(l + 4)},#{f(top)} H#{f(r - 4)} Q#{f(r)},#{f(top)} #{f(r)},#{f(top + 4)} V128 Z"
  end

  defp f(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)

  defp bar_title(week, true, expected),
    do:
      gettext("Week %{n}: %{paid} kr paid, expected to land around %{expected} kr",
        n: Streams.week_number(week.week_start),
        paid: Money.format(week.paid || Decimal.new(0)),
        expected: Money.format(expected)
      )

  defp bar_title(%{paid: nil} = week, false, _),
    do: gettext("Week %{n}: nothing paid", n: Streams.week_number(week.week_start))

  defp bar_title(week, false, _) do
    line =
      gettext("Week %{n}: %{paid} kr",
        n: Streams.week_number(week.week_start),
        paid: Money.format(week.paid)
      )

    if week.over?, do: line <> ", " <> gettext("over budget"), else: line
  end

  defp chart_label(page) do
    first = hd(page.weeks).week_start

    gettext("What weeks %{first} to %{last} cost",
      first: Streams.week_number(first),
      last: Streams.week_number(page.week_start)
    )
  end

  defp week_line(week_start) do
    gettext("Week %{n} · %{range}",
      n: Streams.week_number(week_start),
      range: ToreWeb.Dates.range(week_start, Date.add(week_start, 6))
    )
  end

  defp this_week_receipts(page),
    do: Enum.count(page.receipts, &(&1.week_start == page.week_start))

  defp open_line(%{open_days: 0}), do: gettext("every dinner planned")

  defp open_line(%{open_days: days}),
    do: ngettext("%{count} open day counted", "%{count} open days counted", days)

  defp average_line(%{average: nil}), do: gettext("no weeks yet")

  defp average_line(page) do
    paid =
      for week <- page.weeks, week.paid, week.week_start != page.week_start, do: week.week_start

    case Enum.map([List.first(paid), List.last(paid)], &Streams.week_number/1) do
      [one, one] -> gettext("week %{n}", n: one)
      [first, last] -> gettext("weeks %{first}–%{last}", first: first, last: last)
    end
  end

  defp sections_line(page) do
    first = Date.add(page.week_start, -21)

    gettext("Weeks %{first}–%{last} · %{amount} kr",
      first: Streams.week_number(first),
      last: Streams.week_number(page.week_start),
      amount: Money.format(sections_total(page.sections))
    )
  end

  defp sections_total(sections),
    do: Enum.reduce(sections, Decimal.new(0), &Decimal.add(&1.total, &2))

  defp share(amount, total) do
    if Decimal.eq?(total, 0),
      do: 0,
      else:
        amount
        |> Decimal.mult(100)
        |> Decimal.div(total)
        |> Decimal.round(0)
        |> Decimal.to_integer()
  end

  # "Mån 16 nov": a receipt's day, short enough for its column.
  defp short_date(date) do
    [day, month] = String.split(ToreWeb.Dates.day(date), " ", parts: 2)
    "#{String.slice(ToreWeb.Dates.weekday(date), 0, 3)} #{day} #{String.slice(month, 0, 3)}"
  end

  defp initial(nil), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()
end
