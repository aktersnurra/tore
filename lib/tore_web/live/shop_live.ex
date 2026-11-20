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
       spending: ToreWeb.Spending.load(scope),
       section_order: Shop.Walk.order(scope),
       scanning: false,
       scanner: nil,
       making_list: false
     )
     |> ToreWeb.PiReply.init()
     |> assign_dinners()
     |> allow_upload(:receipt_photo,
       # What the model reads; an iPhone's camera sends JPEG to a web page, not HEIC.
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 10_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  # pi reads the receipt in the person's chat and logs it (`log_receipt`); the spending updates when
  # it does, and what pi says shows in the note.
  def handle_progress(:receipt_photo, %{done?: true} = entry, socket) do
    image =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        # Some browsers leave the type empty; the name the upload accepted says it.
        {:ok, {MIME.from_path(entry.client_name), File.read!(path)}}
      end)

    socket =
      ToreWeb.PiReply.ask(
        socket,
        "From the Shop screen: a photo of a receipt. Log it.",
        gettext("Reading the receipt…"),
        images: [image]
      )

    {:noreply, assign(socket, scanning: socket.assigns.pi_working != nil)}
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

  # One field: "2 l mjölk" is read into an amount, a unit and the name.
  def handle_event("add_item", %{"name" => line}, socket) do
    {name, quantity, unit} = Shop.parse_line(line)

    if name != "" do
      Shop.add_item(
        socket.assigns.current_scope,
        socket.assigns.list_id,
        name,
        quantity,
        unit,
        socket.assigns.user_id
      )
    end

    {:noreply, push_event(socket, "reset_form", %{id: "add-item"})}
  end

  # The list from the week's dinners, without what's at home. No model is asked.
  def handle_event("make_list", _params, socket) do
    scope = socket.assigns.current_scope

    ToreWeb.Background.run(
      fn -> Tore.Capture.Dispatch.generate_shopping_list_from_plan(nil, %{scope: scope}) end,
      &{:list_made, &1}
    )

    {:noreply, assign(socket, making_list: true)}
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

    message =
      "From the Shop screen, about \"#{item.name}\" on this week's shopping list: #{command}"

    {:noreply,
     socket
     |> assign(item_sheet: nil)
     |> ToreWeb.PiReply.ask(message, gettext("Going through the list…"))}
  end

  def handle_event("item_command", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_pi_reply", _params, socket),
    do: {:noreply, ToreWeb.PiReply.dismiss(socket)}

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("move_receipt_week", %{"id" => id}, socket) do
    # The chip's id carries the week, so the moved receipt's chip settles in with its new one.
    _ = Tore.Costs.move_receipt_week(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, reload_spending(socket)}
  end

  # The barcode scanner: a line per pack scanned, newest first, each with Undo.
  def handle_event("open_scanner", _params, socket),
    do: {:noreply, assign(socket, scanner: %{lines: [], asking: nil, busy: false, camera: :ok})}

  def handle_event("close_scanner", _params, socket), do: {:noreply, assign(socket, scanner: nil)}

  def handle_event("scanned", _params, %{assigns: %{scanner: %{busy: true}}} = socket),
    do: {:noreply, socket}

  def handle_event("scanned", %{"code" => code}, socket), do: {:noreply, scan(socket, code, [])}

  def handle_event("name_product", %{"name" => name}, socket) do
    case {socket.assigns.scanner.asking, String.trim(name)} do
      {nil, _} -> {:noreply, socket}
      {_code, ""} -> {:noreply, socket}
      {code, name} -> {:noreply, scan(socket, code, name: name)}
    end
  end

  def handle_event("undo_scan", %{"id" => id}, socket) do
    %{scanner: scanner, current_scope: scope} = socket.assigns

    case Enum.find(scanner.lines, &(&1.id == id)) do
      %{undone: false} = line ->
        :ok = undo(scope, socket.assigns, line)
        lines = Enum.map(scanner.lines, &if(&1.id == id, do: %{&1 | undone: true}, else: &1))
        {:noreply, assign(socket, scanner: %{scanner | lines: lines})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("scanner_failed", _params, socket),
    do: {:noreply, update(socket, :scanner, &(&1 && %{&1 | camera: :failed}))}

  def handle_info({:pi, _session, event}, socket) do
    socket = ToreWeb.PiReply.event(socket, event)

    {:noreply,
     assign(socket, scanning: socket.assigns.scanning and socket.assigns.pi_working != nil)}
  end

  def handle_info({:list_made, %{error: true, text: text}}, socket),
    do: {:noreply, socket |> assign(making_list: false) |> put_flash(:error, text)}

  def handle_info({:list_made, _bubble}, socket),
    do: {:noreply, assign(socket, making_list: false)}

  def handle_info({:events, _events}, socket) do
    {:ok, grocery_state} = Shop.load_list(socket.assigns.current_scope, socket.assigns.list_id)
    {:noreply, assign(socket, grocery_state: grocery_state)}
  end

  def handle_info({:run_changed, %{status: :reverted, surface: :shop}}, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Undone."))}

  # A receipt saved or undone anywhere changes the month's spending.
  def handle_info({:run_changed, _run}, socket), do: {:noreply, reload_spending(socket)}

  def handle_info({:scanned, _code, _result}, %{assigns: %{scanner: nil}} = socket),
    do: {:noreply, socket}

  def handle_info({:scanned, code, result}, socket) do
    scanner = %{socket.assigns.scanner | busy: false, asking: nil}

    scanner =
      case result do
        {:ok, %{change: change, name: name} = done} ->
          line = %{id: Ecto.UUID.generate(), change: change, name: name, undone: false, ref: done}
          %{scanner | lines: [line | scanner.lines]}

        {:error, :unknown_product} ->
          %{scanner | asking: code}

        {:error, :not_a_barcode} ->
          scanner

        {:error, _} ->
          line = %{id: Ecto.UUID.generate(), change: :failed, name: nil, undone: false, ref: nil}
          %{scanner | lines: [line | scanner.lines]}
      end

    {:noreply, assign(socket, scanner: scanner)}
  end

  defp scan(socket, code, opts) do
    %{current_scope: scope, list_id: list_id, user_id: user_id} = socket.assigns

    ToreWeb.Background.run(
      fn -> Tore.Pantry.Scan.scan(scope, list_id, code, [user_id: user_id] ++ opts) end,
      &{:scanned, code, &1}
    )

    update(socket, :scanner, &%{&1 | busy: true})
  end

  # A pack put in the pantry is taken out again; a ticked item is unticked, as on the list.
  defp undo(scope, _assigns, %{change: :added, ref: %{run_id: run_id}}) do
    {:ok, _} = Tore.Harness.Runs.revert(scope, run_id)
    :ok
  end

  defp undo(scope, assigns, %{change: :ticked, ref: %{item_id: item_id}}) do
    {:ok, _} = Shop.uncheck_item(scope, assigns.list_id, item_id, assigns.user_id)
    :ok
  end

  # Which dinner each item is for, from the week's plan: "for Tuesday's tacos".
  defp assign_dinners(socket) do
    %{current_scope: scope, week_start: week_start} = socket.assigns
    assign(socket, dinners: Shop.meals_for(scope, week_start, Tore.Clock.today()))
  end

  defp reload_spending(socket),
    do: assign(socket, spending: ToreWeb.Spending.load(socket.assigns.current_scope))

  def render(assigns) do
    items =
      assigns.grocery_state.items
      |> sorted_items()
      |> then(&Shop.annotate_with_pantry_belief(assigns.current_scope, &1))

    {unchecked, checked} = Enum.split_with(items, &(!&1.checked))
    groups = group_by_section(unchecked, assigns.section_order)

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
        <.top_bar>
          <:actions :if={@total > 0}>
            <.page_menu id="shop-menu">
              <.menu_item menu="shop-menu" icon="ph-file-text" event="export_list">
                {gettext("Show as text")}
              </.menu_item>
            </.page_menu>
          </:actions>
        </.top_bar>

        <header class="pt-1">
          <.page_icon icon="ph-shopping-cart-duotone" tint="green" />
          <h1 class="t-display mt-3">{gettext("Shop")}</h1>
          <p class="num mt-1 text-[color:var(--muted)]" style="font-size: 15px;">
            {gettext("%{count} left · week %{week}", count: @unchecked_count, week: @week_number)}
          </p>
        </header>

        <%!-- A receipt being read shows by its button instead. --%>
        <ToreWeb.PiReply.pi_reply reply={@pi_reply} working={!@scanning && @pi_working} />

        <%!-- One line, where the thumb starts: "2 l mjölk" is read as two litres of milk. Enter
             (and the phone's Go key) adds; cleared after, focus kept. The scanner sits at its end. --%>
        <div class="sticky top-0 z-10 -mx-4 mt-3 bg-[var(--bg)] px-4">
          <form
            id="add-item"
            phx-submit="add_item"
            class="flex items-center gap-2 border-b border-[color:var(--hairline)]"
          >
            <button
              type="submit"
              aria-label={gettext("Add")}
              class="press -ml-1 flex size-8 shrink-0 items-center justify-center text-[color:var(--muted)]"
            >
              <.icon name="ph-plus" class="size-5" />
            </button>
            <input
              type="text"
              name="name"
              placeholder={gettext("Add, e.g. 2 l milk")}
              aria-label={gettext("Add to the list")}
              autocomplete="off"
              required
              class="h-12 min-w-0 flex-1 border-0 bg-transparent text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none"
              style="font-size: 16px;"
            />
            <button
              type="button"
              phx-click="open_scanner"
              aria-label={gettext("Scan what you bought")}
              class="icon-btn press -mr-2 shrink-0"
            >
              <.icon name="ph-barcode" class="size-5" />
            </button>
          </form>
        </div>

        <div
          :if={@export_text}
          class="rise-in mt-4 rounded-[var(--r-xl)] bg-[var(--surface)] p-4"
        >
          <div class="mb-2 flex items-center justify-between">
            <span class="section-label">{gettext("The list as text")}</span>
            <.icon_button icon="ph-x" label={gettext("Close")} phx-click="clear_export" />
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
          <p :if={@dinners == %{}} class="mt-1.5 text-[color:var(--muted)]" style="font-size: 15px;">
            {gettext("Add what you need above, or plan some dinners and the list makes itself.")}
          </p>
          <p :if={@dinners != %{}} class="mt-1.5 text-[color:var(--muted)]" style="font-size: 15px;">
            {gettext("The week's dinners are planned. The list leaves out what's at home.")}
          </p>
          <button
            :if={@dinners != %{}}
            type="button"
            phx-click="make_list"
            disabled={@making_list}
            data-role="make-list"
            class="pill pill-lamp press mt-5"
          >
            <.icon
              name={if @making_list, do: "ph-arrows-clockwise", else: "ph-list-bullets"}
              class={@making_list && "motion-safe:animate-spin"}
            />
            {if @making_list, do: gettext("Making the list…"), else: gettext("Make the list")}
          </button>
        </div>

        <%!-- The store's sections, each a tinted tag that folds its rows away --%>
        <section :for={{section, section_items} <- @groups} class="mt-4">
          <.group_head
            id={"items-#{section}"}
            label={ToreWeb.Look.section_label(section)}
            tint={ToreWeb.Look.section_tint(section)}
            count={length(section_items)}
          />
          <ul id={"items-#{section}"} class="pl-6" phx-hook=".Tick">
            <.item_row :for={item <- section_items} item={item} dinner={dinner_line(@dinners, item)} />
          </ul>
        </section>

        <%!-- The basket, folded shut at the bottom --%>
        <section :if={@checked != []} class="mt-4">
          <.group_head
            id="items-basket"
            label={gettext("In the basket")}
            tint="grey"
            count={length(@checked)}
            open={false}
          />
          <ul id="items-basket" class="hidden pl-6" phx-hook=".Tick">
            <.item_row :for={item <- @checked} item={item} />
          </ul>
        </section>

        <ToreWeb.Spending.spending
          spending={@spending}
          scanning={@scanning}
          upload={@uploads.receipt_photo}
        />
      </.page>

      <.scanner :if={@scanner} scanner={@scanner} />

      <%!-- Grocery item object sheet (long-press) --%>
      <.bottom_sheet :if={@item_sheet} id="item-sheet" on_close="close_item_sheet">
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
            <.icon name="ph-trash" class="size-4" />
            {gettext("Remove from the list")}
          </button>
        </div>
      </.bottom_sheet>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Tick">
        // Ticking an item draws its check, then folds the row away before the server moves it
        // to the basket. Unticking, or reduced motion, goes straight through.
        export default {
          mounted() {
            this.onClick = (e) => {
              const target = e.target.closest("[data-tick]")
              const row = target?.closest(".tick-row")
              if (!row || row.classList.contains("is-checked")) return
              if (matchMedia("(prefers-reduced-motion: reduce)").matches) return
              e.stopPropagation()
              e.preventDefault()
              if (row.classList.contains("is-ticking")) return
              row.classList.add("is-ticking")
              setTimeout(() => this.pushEvent("toggle_item", {item_id: target.dataset.tick}), 620)
            }
            this.el.addEventListener("click", this.onClick, true)
          },
          destroyed() { this.el.removeEventListener("click", this.onClick, true) }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :scanner, :map, required: true

  # The camera fills the top of the sheet; each pack scanned gets a line under it, with Undo.
  defp scanner(assigns) do
    ~H"""
    <.bottom_sheet id="scanner-sheet" on_close="close_scanner">
      <h2 class="t-head px-5 pb-3">{gettext("Scan what you unpack")}</h2>

      <div
        id="scanner"
        phx-hook="Scanner"
        phx-update="ignore"
        data-state="starting"
        class="scanner-view relative mx-5 aspect-[4/3] overflow-hidden rounded-[var(--r-xl)] bg-black"
      >
        <video class="size-full object-cover" playsinline muted autoplay></video>
        <div class="scanner-frame pointer-events-none absolute inset-x-[12%] top-1/2 h-[34%] -translate-y-1/2 rounded-[var(--r-lg)]">
        </div>
      </div>

      <p
        class="mx-5 mt-3 min-h-[1.5em] text-[15px] text-[color:var(--muted)]"
        role="status"
        aria-live="polite"
      >
        <%= cond do %>
          <% @scanner.camera == :failed -> %>
            <span class="text-[color:var(--danger)]">
              {gettext("Tore can't use the camera. Allow it for this site, or add items by name.")}
            </span>
          <% @scanner.busy -> %>
            <span class="inline-flex items-center gap-2">
              <.icon name="ph-arrows-clockwise" class="size-4 motion-safe:animate-spin" />
              {gettext("Looking it up…")}
            </span>
          <% true -> %>
            {gettext("Hold a barcode in the frame.")}
        <% end %>
      </p>

      <form
        :if={@scanner.asking}
        id="scanner-name"
        phx-submit="name_product"
        class="rise-in mx-5 mt-3"
      >
        <label for="scanner-name-input" class="block text-[15px] font-semibold">
          {gettext("Tore doesn't know this code. What is it?")}
        </label>
        <div class="mt-2 flex gap-2">
          <input
            id="scanner-name-input"
            type="text"
            name="name"
            autocomplete="off"
            required
            placeholder={gettext("Name")}
            class="h-12 min-w-0 flex-1 rounded-full bg-[var(--sunken)] px-5 text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus-visible:outline-2 focus-visible:outline-[color:var(--accent)]"
            style="font-size: 16px;"
          />
          <button type="submit" class="pill pill-lamp press">{gettext("Save")}</button>
        </div>
      </form>

      <ul id="scanner-lines" class="menu-lines mx-5 mt-2 overflow-y-auto">
        <li
          :for={line <- @scanner.lines}
          id={"scan-#{line.id}"}
          class={["rise-in flex min-h-[52px] items-center gap-3 py-2", line.undone && "opacity-50"]}
        >
          <.icon
            name={if line.change == :failed, do: "ph-warning-circle", else: "ph-check"}
            class={[
              "size-5 shrink-0",
              if(line.change == :failed,
                do: "text-[color:var(--danger)]",
                else: "text-[color:var(--done)]"
              )
            ]}
          />
          <span class="min-w-0 flex-1 text-[15px]">{scan_line(line)}</span>
          <button
            :if={line.change != :failed and not line.undone}
            type="button"
            phx-click="undo_scan"
            phx-value-id={line.id}
            class="press h-11 px-2 text-[15px] font-semibold text-[color:var(--accent-ink)]"
          >
            {gettext("Undo")}
          </button>
        </li>
      </ul>
    </.bottom_sheet>
    """
  end

  defp scan_line(%{undone: true}), do: gettext("Undone.")

  defp scan_line(%{change: :added, name: name}),
    do: gettext("%{name} is in the pantry", name: name)

  defp scan_line(%{change: :ticked, name: name}),
    do: gettext("%{name} ticked off the list", name: name)

  defp scan_line(%{change: :failed}), do: gettext("Couldn't look that code up. Try again.")

  attr :item, :map, required: true
  attr :dinner, :string, default: nil

  # Ticking draws the check, then the row folds away into the basket (the `.Tick` hook waits
  # for that before telling the server); with reduced motion it moves at once.
  defp item_row(assigns) do
    ~H"""
    <li
      id={"item-#{@item.id}"}
      phx-hook="LongPress"
      data-long-press-event="open_item_sheet"
      data-item-id={@item.id}
      data-item-name={@item.name}
      class={[
        "tick-row flex min-h-[44px] items-center gap-3 py-1.5",
        @item.checked && "is-checked"
      ]}
    >
      <button
        type="button"
        role="checkbox"
        aria-checked={to_string(@item.checked)}
        aria-label={@item.name}
        phx-click="toggle_item"
        phx-value-item_id={@item.id}
        data-tick={@item.id}
        class="press tick-box"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5.5 12.5l4.2 4.2L18.5 8" /></svg>
      </button>
      <button
        type="button"
        phx-click="toggle_item"
        phx-value-item_id={@item.id}
        data-tick={@item.id}
        class="press press-soft min-w-0 flex-1 text-left"
      >
        <span class="tick-name block truncate text-[var(--text)]" style="font-size: 15.5px;">
          <span :if={Map.get(@item, :pantry_belief)} class="mr-1 text-[color:var(--muted)]">?</span>{@item.name}
        </span>
        <span
          :if={Map.get(@item, :pantry_belief)}
          class="mt-0.5 block text-[color:var(--muted)]"
          style="font-size: var(--t-micro);"
        >
          {pantry_belief_hint(@item.pantry_belief, @item.pantry_last_seen_at)}
        </span>
        <span
          :if={@dinner && !Map.get(@item, :pantry_belief)}
          data-role="for-dinner"
          class="mt-0.5 block truncate text-[color:var(--muted)]"
          style="font-size: var(--t-micro);"
        >
          {@dinner}
        </span>
        <span
          :if={Map.get(@item, :basic) && !@dinner && !Map.get(@item, :pantry_belief)}
          data-role="basic"
          class="mt-0.5 block text-[color:var(--muted)]"
          style="font-size: var(--t-micro);"
        >
          {gettext("Basic")}
        </span>
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

  defp dinner_line(dinners, item) do
    case dinners[Tore.Recipes.Ingredient.to_key(item.name)] do
      nil ->
        nil

      %{date: date, title: title} ->
        dish = lowercase_first(title)

        if date == Tore.Clock.today(),
          do: gettext("for tonight's %{dish}", dish: dish),
          else:
            gettext("for %{day} %{dish}", day: ToreWeb.Dates.weekday_possessive(date), dish: dish)
    end
  end

  # A dish named inside a sentence: "Tacos" reads "tacos" there.
  defp lowercase_first(<<first::utf8, rest::binary>>),
    do: String.downcase(<<first::utf8>>) <> rest

  defp sorted_items(items) do
    items
    |> Map.values()
    |> Enum.sort_by(fn i -> {i.checked, String.downcase(i.name || "")} end)
  end

  # Sections in the order the household walks its store (`Tore.Shop.Walk`).
  defp group_by_section(items, order) do
    grouped = Enum.group_by(items, &(Map.get(&1, :section) || :other))

    order
    |> Enum.filter(&Map.has_key?(grouped, &1))
    |> Enum.map(fn section ->
      {section, Enum.sort_by(grouped[section], &String.downcase(&1.name))}
    end)
  end

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
