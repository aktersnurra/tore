defmodule ToreWeb.WelcomeLive do
  @moduledoc """
  Where a new household picks its language, once. Every other page sends its members here until it has
  one (`ToreWeb.Live.Auth`, `:require_language`).
  """
  use ToreWeb, :live_view

  alias Tore.Household

  def mount(_params, _session, socket) do
    if Household.locale(socket.assigns.current_scope) do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok, assign(socket, locales: ~w(sv en))}
    end
  end

  def handle_event("pick", %{"locale" => locale}, socket) do
    # Picked now, or by another member a moment ago: either way the household has a language.
    _ = Household.set_locale(socket.assigns.current_scope, locale)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/welcome">
      <.page max_width={:md}>
        <.card>
          <h1 class="font-semibold text-[var(--text)] mb-2" style="font-size: var(--t-h1);">
            {gettext("Welcome to Tore")}
          </h1>
          <p class="text-[color:var(--muted)] mb-5" style="font-size: var(--t-body);">
            {gettext(
              "Pick the language your household keeps its recipes, lists and receipts in. It can't be changed later."
            )}
          </p>
          <div class="flex flex-col gap-3">
            <button
              :for={locale <- @locales}
              type="button"
              phx-click="pick"
              phx-value-locale={locale}
              class="w-full rounded-xl border border-[color:var(--hairline)] px-4 py-3 text-left font-medium text-[var(--text)] hover:border-[color:var(--accent)]"
              style="font-size: var(--t-body);"
            >
              {Household.locale_label(locale)}
            </button>
          </div>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
