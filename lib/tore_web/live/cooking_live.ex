defmodule ToreWeb.CookingLive do
  @moduledoc """
  The household's dietary rules and allergies, which every plan is checked against. Tastes and
  cuisines aren't set here: Tore keeps them in household memory.
  """

  use ToreWeb, :live_view

  alias Tore.Household

  @dietary_restrictions ~w(vegetarian vegan gluten_free lactose_free low_carb high_protein nut_free)
  @allergies ~w(nuts shellfish gluten lactose eggs)

  def mount(_params, _session, socket) do
    prefs = Household.get_preferences(socket.assigns.current_scope)

    {:ok, assign(socket, prefs: prefs)}
  end

  def handle_event("toggle_restriction", %{"item" => value}, socket) do
    prefs = socket.assigns.prefs
    current = prefs.dietary_restrictions || []
    updated = toggle_list(current, value)
    save_and_assign(socket, %{dietary_restrictions: updated})
  end

  def handle_event("toggle_allergy", %{"item" => value}, socket) do
    prefs = socket.assigns.prefs
    current = prefs.allergies || []
    updated = toggle_list(current, value)
    save_and_assign(socket, %{allergies: updated})
  end

  defp save_and_assign(socket, attrs) do
    case Household.update_preferences(socket.assigns.current_scope, attrs) do
      {:ok, updated} -> {:noreply, assign(socket, prefs: updated)}
      {:error, _} -> {:noreply, socket}
    end
  end

  defp toggle_list(list, value) do
    if value in list, do: List.delete(list, value), else: list ++ [value]
  end

  defp active_chip?(list, value), do: value in (list || [])

  defp label_for("vegetarian"), do: gettext("Vegetarian")
  defp label_for("vegan"), do: gettext("Vegan")
  defp label_for("gluten_free"), do: gettext("Gluten-free")
  defp label_for("lactose_free"), do: gettext("Lactose-free")
  defp label_for("low_carb"), do: gettext("Low carb")
  defp label_for("high_protein"), do: gettext("High protein")
  defp label_for("nut_free"), do: gettext("Nut-free")
  defp label_for("nuts"), do: gettext("Nuts")
  defp label_for("shellfish"), do: gettext("Shellfish")
  defp label_for("gluten"), do: gettext("Gluten")
  defp label_for("lactose"), do: gettext("Lactose")
  defp label_for("eggs"), do: gettext("Eggs")
  defp label_for(v), do: v

  def render(assigns) do
    assigns =
      assign(assigns,
        dietary_restrictions: @dietary_restrictions,
        allergies: @allergies
      )

    ~H"""
    <Layouts.app flash={@flash} current_path={assigns[:current_path] || "/cooking"}>
      <.page max_width={:md}>
        <.card padded={false}>
          <header class="px-6 pt-6 pb-4">
            <h1 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h1);">
              {gettext("Household kitchen")}
            </h1>
            <p class="text-[color:var(--muted)] mt-1" style="font-size: var(--t-meta);">
              {gettext("Tore checks every plan against these.")}
            </p>
          </header>

          <%!-- We eat --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("We eat")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Tell us what we should cook around.")}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={r <- @dietary_restrictions}
                type="button"
                phx-click="toggle_restriction"
                phx-value-item={r}
                class={[
                  "px-3 py-1.5 rounded-full border text-sm font-medium transition-colors",
                  active_chip?(@prefs.dietary_restrictions, r) &&
                    "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
                  !active_chip?(@prefs.dietary_restrictions, r) &&
                    "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)]"
                ]}
              >
                {label_for(r)}
              </button>
            </div>
          </section>

          <%!-- Never include --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Never include")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Allergies and hard avoids — never suggested.")}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={a <- @allergies}
                type="button"
                phx-click="toggle_allergy"
                phx-value-item={a}
                class={[
                  "px-3 py-1.5 rounded-full border text-sm font-medium transition-colors",
                  active_chip?(@prefs.allergies, a) &&
                    "bg-[color:var(--warn)] border-[color:var(--warn)] text-white",
                  !active_chip?(@prefs.allergies, a) &&
                    "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--warn)] hover:text-[color:var(--warn)]"
                ]}
              >
                {label_for(a)}
              </button>
            </div>
          </section>

          <p
            class="px-6 py-5 border-t border-[color:var(--hairline)] text-[color:var(--muted)]"
            style="font-size: var(--t-meta);"
          >
            {gettext("Tastes and favourite cuisines are learned as you plan.")}
            <.link navigate={~p"/settings"} class="text-[color:var(--accent)] hover:underline">
              {gettext("See what Tore remembers")}
            </.link>
          </p>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
