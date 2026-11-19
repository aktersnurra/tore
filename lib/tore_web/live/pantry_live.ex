defmodule ToreWeb.PantryLive do
  @moduledoc """
  Hemma: what's at home, grouped by where it's kept. Ticking things off on Shop puts them here
  and Done in cook mode uses them up, so this page is for correcting it. Each row says when it
  goes off (as a guess when Tore estimated the date), and asks whether it's still there when
  Tore isn't sure; Finns and Slut answer in the same place.
  """

  use ToreWeb, :live_view

  alias Tore.Pantry
  alias Tore.Pantry.PantryItem

  # Where things are kept, in the order shown; what's used up is folded at the bottom.
  @groups [:fridge, :produce, :freezer, :cupboard, :gone]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(asking: nil) |> load()}
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

  def handle_event("ask", %{"id" => id}, socket),
    do: {:noreply, assign(socket, asking: String.to_integer(id))}

  def handle_event("still_there", %{"id" => id}, socket) do
    {:ok, _item} = Pantry.confirm_item(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, socket |> assign(asking: nil) |> load()}
  end

  def handle_event("gone", %{"id" => id}, socket) do
    {:ok, _item} = Pantry.mark_gone(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, socket |> assign(asking: nil) |> load()}
  end

  defp load(socket) do
    today = Tore.Clock.today()
    now = DateTime.utc_now()
    rows = socket.assigns.current_scope |> Pantry.list_kept() |> Enum.map(&row(&1, today, now))
    by_group = Enum.group_by(rows, & &1.group)
    kept = Enum.reject(rows, &(&1.group == :gone))

    assign(socket,
      groups: for(group <- @groups, rows = by_group[group], do: {group, rows}),
      kept: length(kept),
      soon: Enum.count(kept, &match?(%{status: {:soon, _}}, &1))
    )
  end

  # One row: where it belongs, its picture, a line under the name, and what to say about it.
  defp row(%PantryItem{} = item, today, now) do
    belief = PantryItem.effective_belief(item, now, today)
    category = (item.ingredient && item.ingredient.category) || item.category

    %{
      item: item,
      group: if(belief == :missing, do: :gone, else: group(category)),
      icon: kept_icon(category),
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

  defp kept_icon("dairy"), do: "ph-cheese-duotone"
  defp kept_icon("deli"), do: "ph-cheese-duotone"
  defp kept_icon("meat"), do: "ph-cow-duotone"
  defp kept_icon("fish"), do: "ph-fish-duotone"
  defp kept_icon("produce"), do: "ph-carrot-duotone"
  defp kept_icon("frozen"), do: "ph-ice-cream-duotone"
  defp kept_icon("dry_goods"), do: "ph-grains-duotone"
  defp kept_icon("bread"), do: "ph-bread-duotone"
  defp kept_icon("beverages"), do: "ph-coffee-duotone"
  defp kept_icon("herbs_spices"), do: "ph-leaf-duotone"
  defp kept_icon(category) when category in ~w(canned condiments), do: "ph-jar-label-duotone"
  defp kept_icon(_category), do: "ph-bowl-food-duotone"

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

  defp sub_line(%PantryItem{quantity: %Decimal{} = quantity, unit: unit}) do
    [quantity |> Decimal.normalize() |> Decimal.to_string(:normal), unit]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp sub_line(%PantryItem{added_at: %Date{} = added}),
    do: gettext("bought %{day}", day: ToreWeb.Dates.day(added))

  defp sub_line(_item), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:md}>
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
            class="flex items-center gap-2 border-b border-[color:var(--hairline)]"
          >
            <button
              type="submit"
              aria-label={gettext("Put away")}
              class="press -ml-1 flex size-8 shrink-0 items-center justify-center text-[color:var(--muted)]"
            >
              <.icon name="ph-plus" class="size-5" />
            </button>
            <input
              type="text"
              name="name"
              placeholder={gettext("Add, e.g. 1 l milk")}
              aria-label={gettext("Put away")}
              autocomplete="off"
              required
              class="h-12 min-w-0 flex-1 border-0 bg-transparent text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none"
              style="font-size: 16px;"
            />
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
              class="flex min-h-[52px] items-center gap-3 py-1.5"
            >
              <span class={[
                "flex size-9 shrink-0 items-center justify-center rounded-[var(--r-md)]",
                "tint-#{tint(row.group)}",
                row.group == :gone && "opacity-60"
              ]}>
                <span class={[row.icon, "size-5"]}></span>
              </span>
              <span class="min-w-0 flex-1">
                <span class={[
                  "block truncate",
                  row.group == :gone && "text-[color:var(--muted)]"
                ]}>
                  {row.item.name}
                </span>
                <span
                  :if={sub_line(row.item)}
                  class="num block truncate text-[12.5px] text-[color:var(--muted)]"
                >
                  {sub_line(row.item)}
                </span>
              </span>
              <.status row={row} asking={@asking == row.item.id} />
            </li>
          </ul>
        </section>
      </.page>
    </Layouts.app>
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
