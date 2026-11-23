defmodule ToreWeb.PantryLive do
  @moduledoc """
  Hemma: what's at home, grouped by where it's kept. Ticking things off on Shop puts them here
  and Done in cook mode uses them up, so this page is for correcting it. Each row says when it
  goes off (as a guess when Tore estimated the date), and asks whether it's still there when
  Tore isn't sure; Finns and Slut answer in the same place.
  """

  use ToreWeb, :live_view

  alias Tore.Pantry
  alias Tore.Pantry.{Icons, PantryItem}

  # Where things are kept, in the order shown; what's used up is folded at the bottom.
  @groups [:fridge, :produce, :freezer, :cupboard, :gone]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      # What's learned in the background (a section, Jev's picture) moves and redraws the rows.
      Phoenix.PubSub.subscribe(Tore.PubSub, Pantry.topic(scope))
      # Anything Jev hasn't been asked about yet (kept from before it was asked, or left by a
      # failed call) is asked now; with nothing waiting there's no call.
      :ok = Pantry.Lasts.later(scope)
      # And what has no section yet is learned, so it moves out of the cupboard.
      with [_ | _] = names <- Pantry.without_section(scope),
           do: :ok = Pantry.Learn.later(scope, names)
    end

    {:ok,
     socket
     |> assign(asking: nil, sheet: nil, undo: nil)
     |> load()}
  end

  @impl true
  def handle_event("put_away", %{"name" => line}, socket) do
    case Tore.Shop.parse_line(line) do
      {"", _quantity, _unit} ->
        {:noreply, socket}

      {name, quantity, unit} ->
        {:ok, _item} = Pantry.put_away(socket.assigns.current_scope, name, quantity, unit)
        {:noreply, load(socket)}
    end
  end

  def handle_event("open_item", %{"id" => id}, socket),
    do: {:noreply, assign(socket, sheet: String.to_integer(id))}

  def handle_event("close_item", _params, socket), do: {:noreply, assign(socket, sheet: nil)}

  # What's left, as "400 g" or "2"; something that isn't an amount leaves it as it was.
  def handle_event("set_left", %{"id" => id, "left" => text}, socket) do
    with {:ok, quantity, unit} <- Tore.Shop.parse_amount(text) do
      {:ok, _item} =
        Pantry.set_left(socket.assigns.current_scope, String.to_integer(id), quantity, unit)
    end

    {:noreply, load(socket)}
  end

  # − and +: one pack, or one of what's counted, less or more; none left is gone.
  def handle_event("step", %{"id" => id, "by" => by}, socket) do
    item = find_item(socket, String.to_integer(id))
    step = item |> step() |> Decimal.mult(String.to_integer(by))
    left = item.quantity |> Decimal.add(step) |> Decimal.max(0)
    {:ok, _item} = Pantry.set_left(socket.assigns.current_scope, item.id, left, item.unit)
    {:noreply, load(socket)}
  end

  # The date picked is the household's; cleared, the row has none.
  def handle_event("set_expiry", %{"id" => id, "expires_at" => value}, socket) do
    date = if value == "", do: nil, else: Date.from_iso8601!(value)
    {:ok, _item} = Pantry.set_expiry(socket.assigns.current_scope, String.to_integer(id), date)
    {:noreply, load(socket)}
  end

  def handle_event("ask", %{"id" => id}, socket),
    do: {:noreply, assign(socket, asking: String.to_integer(id))}

  def handle_event("still_there", %{"id" => id}, socket) do
    {:ok, _item} = Pantry.confirm_item(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, socket |> assign(asking: nil) |> load()}
  end

  # Slut: from the row's question, its sheet or a swipe; Ångra puts it back as it was.
  def handle_event("gone", %{"id" => id}, socket) do
    item = find_item(socket, String.to_integer(id))
    {:ok, _item} = Pantry.mark_gone(socket.assigns.current_scope, item.id)
    {:noreply, socket |> undoable(item, gettext("%{name} is used up", name: item.name)) |> load()}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    item = find_item(socket, String.to_integer(id))
    :ok = Pantry.remove_item(socket.assigns.current_scope, item.id)
    {:noreply, socket |> undoable(item, gettext("%{name} removed", name: item.name)) |> load()}
  end

  def handle_event("undo", _params, %{assigns: %{undo: %{item: item}}} = socket) do
    :ok = Pantry.restore_item(socket.assigns.current_scope, item.id, Pantry.before_image(item))
    {:noreply, socket |> assign(undo: nil) |> load()}
  end

  def handle_event("undo", _params, socket), do: {:noreply, socket}
  def handle_event("dismiss_undo", _params, socket), do: {:noreply, assign(socket, undo: nil)}

  @impl true
  def handle_info(:pantry_changed, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    today = Tore.Clock.today()
    now = DateTime.utc_now()
    rows = socket.assigns.current_scope |> Pantry.list_kept() |> Enum.map(&row(&1, today, now))
    by_group = Enum.group_by(rows, & &1.group)
    kept = Enum.reject(rows, &(&1.group == :gone))

    assign(socket,
      rows: rows,
      groups: for(group <- @groups, rows = by_group[group], do: {group, rows}),
      kept: length(kept),
      soon: Enum.count(kept, &match?(%{status: {:soon, _}}, &1))
    )
  end

  defp find_item(socket, id),
    do: socket.assigns.rows |> Enum.find(&(&1.item.id == id)) |> Map.fetch!(:item)

  # The row as it was, for Ångra; the sheet it came from closes.
  defp undoable(socket, item, text),
    do: assign(socket, undo: %{item: item, text: text}, sheet: nil, asking: nil)

  # What − and + move by: a pack when the row knows one, one of what's counted, else nothing.
  defp step(%PantryItem{pack_size: %Decimal{} = size}), do: size
  defp step(%PantryItem{unit: unit}) when unit in ~w(st förp paket pkt burk), do: Decimal.new(1)
  defp step(_item), do: nil

  # One row: where it belongs, its picture (Jev's pick, otherwise its category's), a line under
  # the name, and what to say about it.
  defp row(%PantryItem{} = item, today, now) do
    belief = PantryItem.effective_belief(item, now, today)
    category = (item.ingredient && item.ingredient.category) || item.category

    %{
      item: item,
      group: if(belief == :missing, do: :gone, else: group(category)),
      icon: Icons.shown(item.ingredient && item.ingredient.icon, category),
      status: status(item, belief, today)
    }
  end

  # A date it has outlived, then one close at hand, then a doubt about whether it's there.
  defp status(_item, :missing, _today), do: :gone

  defp status(%PantryItem{expires_at: %Date{} = date} = item, _belief, today) do
    days = Date.diff(date, today)

    cond do
      days < 0 -> {:outlived, date}
      days <= 2 -> {:soon, item}
      true -> nil
    end
  end

  defp status(_item, :uncertain, _today), do: :unsure
  defp status(_item, _belief, _today), do: nil

  defp group(category) when category in ~w(dairy meat fish deli), do: :fridge
  defp group("produce"), do: :produce
  defp group("frozen"), do: :freezer
  defp group(_category), do: :cupboard

  defp group_label(:fridge), do: gettext("Fridge")
  defp group_label(:produce), do: gettext("Produce")
  defp group_label(:freezer), do: gettext("Freezer")
  defp group_label(:cupboard), do: gettext("Cupboard")
  defp group_label(:gone), do: gettext("Gone")

  defp tint(:fridge), do: "blue"
  defp tint(:produce), do: "green"
  defp tint(:freezer), do: "purple"
  defp tint(:cupboard), do: "yellow"
  defp tint(:gone), do: "grey"

  # "today", "tomorrow", "friday"; further off, the date.
  defp when_text(date) do
    case Date.diff(date, Tore.Clock.today()) do
      0 -> gettext("today")
      1 -> gettext("tomorrow")
      -1 -> gettext("yesterday")
      n when n in 2..6 -> ToreWeb.Dates.weekday_in_sentence(date)
      _ -> ToreWeb.Dates.day(date)
    end
  end

  defp count_line(kept, 0), do: ngettext("%{count} thing", "%{count} things", kept)

  defp count_line(kept, soon),
    do:
      count_line(kept, 0) <>
        " · " <> ngettext("%{count} going off soon", "%{count} going off soon", soon)

  defp sub_line(%PantryItem{quantity: %Decimal{}} = item), do: in_packs(item)

  defp sub_line(%PantryItem{added_at: %Date{} = added}),
    do: gettext("bought %{day}", day: ToreWeb.Dates.day(added))

  defp sub_line(_item), do: nil

  # Whole packs as packs ("2 × 820 g"), an opened one as packs and the rest ("1 förp + 220 g");
  # less than a pack, or one pack, is just the amount.
  defp in_packs(%PantryItem{quantity: quantity, pack_size: %Decimal{} = size, unit: unit} = item) do
    packs = quantity |> Decimal.div_int(size) |> Decimal.to_integer()
    rest = Decimal.sub(quantity, Decimal.mult(size, packs))

    cond do
      packs >= 2 and Decimal.eq?(rest, 0) -> "#{packs} × #{amount(size, unit)}"
      packs >= 1 and Decimal.gt?(rest, 0) -> packs_and(packs, amount(rest, unit))
      true -> amount(item)
    end
  end

  defp in_packs(item), do: amount(item)

  defp packs_and(packs, rest),
    do: ngettext("1 pack + %{rest}", "%{count} packs + %{rest}", packs, rest: rest)

  # "400 g", as the field takes it back.
  defp amount(%PantryItem{quantity: %Decimal{} = quantity, unit: unit}),
    do: amount(quantity, unit)

  defp amount(_item), do: ""

  defp amount(%Decimal{} = quantity, unit) do
    [quantity |> Decimal.normalize() |> Decimal.to_string(:normal), unit]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:lg}>
        <.top_bar />

        <header class="pt-1">
          <.page_icon icon="ph-house-simple-duotone" tint="orange" />
          <h1 class="t-display mt-3">{gettext("At home")}</h1>
          <p class="num mt-1 text-[color:var(--muted)]" style="font-size: 15px;">
            {count_line(@kept, @soon)}
          </p>
        </header>

        <%!-- One line, like Shop's: "2 l mjölk" is two litres of milk --%>
        <div class="sticky top-0 z-10 -mx-4 mt-3 bg-[var(--bg)] px-4">
          <form
            id="put-away"
            phx-submit="put_away"
            phx-hook=".ClearOnSubmit"
          >
            <.field
              id="put-away-name"
              name="name"
              placeholder={gettext("Add, e.g. 1 l milk")}
              aria-label={gettext("Put away")}
              autocomplete="off"
              required
            >
              <:leading>
                <button
                  type="submit"
                  aria-label={gettext("Put away")}
                  class="press -ml-1 flex size-8 shrink-0 items-center justify-center text-[color:var(--muted)]"
                >
                  <.icon name="ph-plus" class="size-5" />
                </button>
              </:leading>
            </.field>
          </form>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".ClearOnSubmit">
            export default {
              mounted() {
                this.el.addEventListener("submit", () => {
                  requestAnimationFrame(() => {
                    const input = this.el.querySelector("input[name=name]")
                    input.value = ""
                    input.focus()
                  })
                })
              }
            }
          </script>
        </div>

        <div :if={@groups == []} class="pt-8 pb-2">
          <p class="t-head">{gettext("Nothing here yet")}</p>
          <p class="mt-1.5 text-[color:var(--muted)]" style="font-size: 15px;">
            {gettext(
              "What you tick off in Shop comes here, and Done in cook mode uses it up. Add anything else above."
            )}
          </p>
        </div>

        <section :for={{group, rows} <- @groups} class="mt-4" data-group={group}>
          <.group_head
            id={"kept-#{group}"}
            label={group_label(group)}
            tint={tint(group)}
            count={length(rows)}
            open={group != :gone}
          />
          <ul id={"kept-#{group}"} class={["pl-6", group == :gone && "hidden"]}>
            <li
              :for={row <- rows}
              id={"item-#{row.item.id}"}
              data-item={row.item.id}
              phx-hook="Swipe"
              data-swipe-event={if row.group == :gone, do: "remove", else: "gone"}
              data-id={row.item.id}
              class="relative overflow-hidden"
            >
              <%!-- What a swipe left does, shown as the row slides over it --%>
              <span
                data-swipe-label
                aria-hidden="true"
                class="absolute inset-y-0 right-0 flex items-center gap-1.5 pr-4 font-semibold text-[color:var(--danger)] opacity-0"
                style="font-size: 15px;"
              >
                <.icon
                  name={if row.group == :gone, do: "ph-trash", else: "ph-check"}
                  class="size-5"
                />
                {if row.group == :gone, do: gettext("Remove"), else: gettext("Gone")}
              </span>
              <div
                data-swipe-body
                class="relative flex min-h-[52px] items-center gap-3 bg-[var(--bg)] py-1.5"
              >
                <%!-- The row opens its sheet: what's left, its date, Slut and Ta bort --%>
                <button
                  type="button"
                  phx-click="open_item"
                  phx-value-id={row.item.id}
                  data-role="open"
                  class="press press-soft flex min-w-0 flex-1 items-center gap-3 text-left"
                >
                  <img
                    src={~p"/images/food/#{Icons.file(row.icon)}"}
                    alt=""
                    class={["size-8 shrink-0", row.group == :gone && "opacity-50 grayscale"]}
                  />
                  <span class="min-w-0 flex-1">
                    <span class={[
                      "block truncate",
                      row.group == :gone && "text-[color:var(--muted)]"
                    ]}>
                      {row.item.name}
                    </span>
                    <span
                      :if={sub_line(row.item)}
                      data-role="left"
                      class="num block truncate text-[12.5px] text-[color:var(--muted)]"
                    >
                      {sub_line(row.item)}
                    </span>
                  </span>
                </button>
                <.status row={row} asking={@asking == row.item.id} />
              </div>
            </li>
          </ul>
        </section>
      </.page>

      <.item_sheet :if={item = sheet_item(@rows, @sheet)} item={item} />
      <.undo_bar :if={@undo} text={@undo.text} on_undo="undo" on_dismiss="dismiss_undo" />
    </Layouts.app>
    """
  end

  defp sheet_item(_rows, nil), do: nil

  defp sheet_item(rows, id) do
    case Enum.find(rows, &(&1.item.id == id)) do
      nil -> nil
      row -> row.item
    end
  end

  attr :item, PantryItem, required: true

  # A row opened: what's left (− and + by a pack), its best-before, and Slut or Ta bort.
  defp item_sheet(assigns) do
    assigns = assign(assigns, step: step(assigns.item))

    ~H"""
    <.bottom_sheet id="pantry-item" on_close="close_item">
      <div class="px-5 pt-1">
        <p class="t-head">{@item.name}</p>

        <div class="mt-4 flex items-center gap-2">
          <button
            :if={@step}
            type="button"
            phx-click="step"
            phx-value-id={@item.id}
            phx-value-by="-1"
            data-role="less"
            aria-label={gettext("One less")}
            class="press grid size-11 shrink-0 place-items-center rounded-[var(--r-pill)] bg-[var(--sunken)]"
          >
            <.icon name="ph-minus" class="size-5" />
          </button>
          <form id="item-left" phx-submit="set_left" phx-value-id={@item.id} class="min-w-0 flex-1">
            <.field
              id={"item-left-#{@item.id}"}
              name="left"
              value={amount(@item)}
              placeholder={gettext("How much is left?")}
              aria-label={gettext("How much is left?")}
              autocomplete="off"
              enterkeyhint="done"
              inputmode="decimal"
              class="num"
            />
          </form>
          <button
            :if={@step}
            type="button"
            phx-click="step"
            phx-value-id={@item.id}
            phx-value-by="1"
            data-role="more"
            aria-label={gettext("One more")}
            class="press grid size-11 shrink-0 place-items-center rounded-[var(--r-pill)] bg-[var(--sunken)]"
          >
            <.icon name="ph-plus" class="size-5" />
          </button>
        </div>
        <p
          :if={in_packs(@item) != amount(@item)}
          class="num mt-1.5 text-[13px] text-[color:var(--muted)]"
        >
          {in_packs(@item)}
        </p>

        <form id="item-expiry" phx-change="set_expiry" phx-value-id={@item.id} class="mt-4">
          <label class="flex min-h-11 items-center justify-between gap-3">
            <span>{gettext("Best before")}</span>
            <input
              type="date"
              name="expires_at"
              value={@item.expires_at && Date.to_iso8601(@item.expires_at)}
              class="inline-field num w-auto text-right"
            />
          </label>
        </form>

        <div class="mt-5 flex items-center justify-between gap-3">
          <button
            :if={@item.belief != "missing"}
            type="button"
            phx-click="gone"
            phx-value-id={@item.id}
            data-role="sheet-gone"
            class="pill press h-11 px-4"
          >
            <.icon name="ph-check" class="size-5" /> {gettext("Gone")}
          </button>
          <button
            type="button"
            phx-click="remove"
            phx-value-id={@item.id}
            data-role="remove"
            class="press ml-auto h-11 rounded-[var(--r-pill)] px-4 font-semibold text-[color:var(--danger)] hover:bg-[var(--danger-soft)]"
          >
            {gettext("Remove")}
          </button>
        </div>
      </div>
    </.bottom_sheet>
    """
  end

  attr :row, :map, required: true
  attr :asking, :boolean, required: true

  # What's said about a thing, at the row's end. Asking puts Finns and Slut in the same place.
  defp status(%{asking: true} = assigns) do
    ~H"""
    <span class="settle flex shrink-0 gap-1.5">
      <button
        type="button"
        phx-click="still_there"
        phx-value-id={@row.item.id}
        data-role="still-there"
        class="pill press h-8"
      >
        {gettext("Still there")}
      </button>
      <button
        type="button"
        phx-click="gone"
        phx-value-id={@row.item.id}
        data-role="gone"
        class="pill press h-8"
      >
        {gettext("Gone")}
      </button>
    </span>
    """
  end

  defp status(%{row: %{status: {:soon, item}}} = assigns) do
    assigns = assign(assigns, :item, item)

    ~H"""
    <span class="tag tag-red shrink-0">
      {if @item.expires_source == "estimate",
        do: gettext("Keeps till %{when}", when: when_text(@item.expires_at)),
        else: gettext("Goes off %{when}", when: when_text(@item.expires_at))}
    </span>
    """
  end

  defp status(%{row: %{status: :unsure}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="ask"
      phx-value-id={@row.item.id}
      data-role="ask"
      class="tag tag-grey press shrink-0"
    >
      {gettext("Still there?")}
    </button>
    """
  end

  # Under Gone, the one thing to say is that it's back.
  defp status(%{row: %{status: :gone}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="still_there"
      phx-value-id={@row.item.id}
      data-role="still-there"
      class="pill press h-8 shrink-0"
    >
      {gettext("Still there")}
    </button>
    """
  end

  defp status(%{row: %{status: {:outlived, date}}} = assigns) do
    assigns = assign(assigns, :date, date)

    ~H"""
    <button
      type="button"
      phx-click="ask"
      phx-value-id={@row.item.id}
      data-role="ask"
      class="tag tag-red press shrink-0"
    >
      {gettext("Went off %{when}", when: when_text(@date))}
    </button>
    """
  end

  defp status(assigns), do: ~H""
end
