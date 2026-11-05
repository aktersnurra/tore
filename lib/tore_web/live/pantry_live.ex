defmodule ToreWeb.PantryLive do
  use ToreWeb, :live_view

  alias Tore.Pantry

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, groups: Pantry.list_inventory_by_belief())}
  end

  @impl true
  def handle_event("remove_item", %{"id" => id}, socket) do
    Pantry.remove_item(String.to_integer(id))
    {:noreply, assign(socket, groups: Pantry.list_inventory_by_belief())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={assigns[:current_scope]}
      current_path={assigns[:current_path] || "/settings/pantry"}
    >
      <div class="max-w-2xl mx-auto p-4">
        <header class="mb-4">
          <h1 class="text-2xl font-semibold">{gettext("Approximate inventory")}</h1>
          <p class="text-sm text-stone-500">
            {gettext("What Tore thinks you have. Remove anything that's wrong.")}
          </p>
        </header>

        <div :for={{belief, items} <- @groups} class="mb-6">
          <h2 class="text-xs font-semibold uppercase tracking-widest text-stone-500 mb-2">
            {belief_label(belief)}
          </h2>
          <ul class="divide-y divide-stone-200 rounded-lg border border-stone-200 bg-white">
            <li :for={item <- items} class={["flex items-center justify-between p-3", belief == :missing && "opacity-50"]}>
              <div>
                <p class="text-stone-900">{String.capitalize(item.name)}</p>
                <p :if={item.quantity} class="text-xs text-stone-500">
                  {format_quantity(item.quantity, item.unit)}
                </p>
              </div>
              <button
                type="button"
                phx-click="remove_item"
                phx-value-id={item.id}
                class="text-xs text-stone-400 hover:text-red-600"
                aria-label={gettext("Remove")}
              >
                {gettext("Remove")}
              </button>
            </li>
          </ul>
        </div>

        <div
          :if={@groups == []}
          class="rounded-lg border border-stone-200 bg-white p-6 text-center text-sm text-stone-500"
        >
          {gettext(
            "Nothing in the pantry yet. Items appear here when you check off groceries or send a photo of your shelves."
          )}
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp belief_label(:confirmed), do: gettext("Confirmed at home")
  defp belief_label(:probable), do: gettext("Probably at home")
  defp belief_label(:uncertain), do: gettext("Unknown")
  defp belief_label(:missing), do: gettext("Probably missing")

  defp format_quantity(q, unit) when is_binary(unit) and unit != "" do
    "#{q} #{unit}"
  end

  defp format_quantity(q, _), do: "#{q}"
end
