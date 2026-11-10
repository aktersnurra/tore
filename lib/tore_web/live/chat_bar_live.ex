defmodule ToreWeb.ChatBarLive do
  @moduledoc """
  The bar at the bottom of every screen: the quick swaps, the chat box and the ≡ menu.

  It is a sticky LiveView in `Layouts.app`, so it and its swaps survive live navigation. It
  isn't routed, so it can't see the page's URL: a hook reports `location.pathname` after every
  navigation, which keeps the menu's current page marked, leaves out the swap that opens the
  page already shown, and sends Capture back here when it closes.

  The swaps are the stored pick's (`Tore.Home.current/1`), until a Capture turn suggests its own
  (`{:quick_swaps, swaps}` on `Tore.Home.swaps_topic/1`), which last until the next pick.
  """

  use ToreWeb, :live_view

  alias Tore.Home
  alias Tore.Harness.{KitchenRun, Runs}

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    case Tore.Accounts.get_session(user_id) do
      {user, scope} ->
        Gettext.put_locale(ToreWeb.Gettext, user.locale)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tore.PubSub, Runs.topic(scope))
          Phoenix.PubSub.subscribe(Tore.PubSub, Home.swaps_topic(user.id))
        end

        {:ok,
         socket
         |> assign(current_scope: scope, path: "/", menu_open: false, suggested?: false)
         |> load(), layout: false}

      nil ->
        {:ok, assign(socket, current_scope: nil), layout: false}
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    reviews = length(Runs.list_reviews(scope))

    if socket.assigns.suggested?,
      do: assign(socket, reviews: reviews),
      else: assign(socket, reviews: reviews, swaps: Home.current(scope).swaps)
  end

  @impl true
  def handle_event("here", %{"path" => path}, socket) when is_binary(path),
    do: {:noreply, assign(socket, path: path, menu_open: false)}

  def handle_event("toggle_menu", _params, socket),
    do: {:noreply, update(socket, :menu_open, &(not &1))}

  def handle_event("swap", %{"index" => index}, socket) do
    case socket.assigns |> shown_swaps() |> Enum.at(String.to_integer(index)) do
      %{action: {:open, screen}} -> {:noreply, push_navigate(socket, to: Home.path(screen))}
      %{action: {:prompt, text}} -> {:noreply, push_navigate(socket, to: capture(socket, text))}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("send", %{"message" => text}, socket) do
    case String.trim(text) do
      "" -> {:noreply, socket}
      text -> {:noreply, push_navigate(socket, to: capture(socket, text))}
    end
  end

  @impl true
  # A new pick replaces the swaps a Capture turn suggested; any other run may change which
  # swaps make sense and how many reviews wait.
  def handle_info({:run_changed, %KitchenRun{kind: "home_pick_run", status: :applied}}, socket),
    do: {:noreply, socket |> assign(suggested?: false) |> load()}

  def handle_info({:run_changed, _run}, socket), do: {:noreply, load(socket)}

  def handle_info({:quick_swaps, swaps}, socket),
    do: {:noreply, assign(socket, swaps: swaps, suggested?: true)}

  defp capture(socket, text), do: ~p"/capture?#{[q: text, return_to: socket.assigns.path]}"

  defp shown_swaps(%{swaps: swaps, path: path}), do: Enum.reject(swaps, &here?(&1, path))

  defp here?(%{action: {:open, screen}}, path), do: Home.path(screen) == path
  defp here?(_swap, _path), do: false

  defp menu_items(reviews) do
    [
      {~p"/today", gettext("Today")},
      {~p"/plan", gettext("Plan")},
      {~p"/shop", gettext("Shop")},
      {~p"/recipes", gettext("Recipes")},
      {~p"/prep", gettext("Prep")},
      {~p"/cooking", gettext("Cooking")},
      {~p"/review", ngettext("Review (%{count})", "Review (%{count})", reviews, count: reviews)},
      {~p"/settings/costs", gettext("Costs")},
      {~p"/settings/pantry", gettext("Pantry")},
      {~p"/settings", gettext("Settings")}
    ]
  end

  @impl true
  def render(%{current_scope: nil} = assigns), do: ~H""

  def render(assigns) do
    assigns = assign(assigns, shown: shown_swaps(assigns), items: menu_items(assigns.reviews))

    ~H"""
    <div id="chat-bar-here" phx-hook=".Here">
      <div
        :if={@menu_open}
        id="menu"
        data-role="menu"
        class="fixed inset-0 z-50 flex flex-col justify-end bg-black/30"
        phx-window-keydown="toggle_menu"
        phx-key="Escape"
      >
        <nav
          phx-click-away="toggle_menu"
          class="mx-auto w-full max-w-2xl rounded-t-[var(--r-xl)] bg-[var(--surface)] px-2 pt-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] shadow-[var(--shadow-pop)]"
          aria-label={gettext("Menu")}
        >
          <%= for {path, label} <- @items do %>
            <a
              :if={path == ~p"/review"}
              href={path}
              data-role="menu-item"
              class={item_class(path, @path)}
            >
              {label}
            </a>
            <.link
              :if={path != ~p"/review"}
              navigate={path}
              data-role="menu-item"
              aria-current={if path == @path, do: "page"}
              class={item_class(path, @path)}
            >
              {label}
            </.link>
          <% end %>
        </nav>
      </div>

      <div
        data-role="chat-bar"
        class="fixed inset-x-0 bottom-0 z-40 border-t border-[color:var(--border)] bg-[var(--bg)]/95 backdrop-blur"
      >
        <div class="mx-auto max-w-2xl px-4 pt-2 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
          <div :if={@shown != []} data-role="swaps" class="flex gap-2 overflow-x-auto pb-2">
            <button
              :for={{swap, index} <- Enum.with_index(@shown)}
              type="button"
              phx-click="swap"
              phx-value-index={index}
              data-role="swap"
              class="shrink-0 rounded-full border border-[color:var(--border)] bg-[var(--surface)] px-3 py-1.5 text-sm text-[color:var(--text)]"
            >
              {swap.label}
            </button>
          </div>
          <form phx-submit="send" class="flex items-center gap-2">
            <button
              type="button"
              phx-click="toggle_menu"
              aria-label={gettext("Menu")}
              aria-expanded={to_string(@menu_open)}
              data-role="menu-button"
              class="flex size-[var(--tap-min)] shrink-0 items-center justify-center rounded-full text-[color:var(--text)]"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>
            <input
              type="text"
              name="message"
              autocomplete="off"
              placeholder={gettext("Ask Tore…")}
              aria-label={gettext("Ask Tore…")}
              class="min-w-0 flex-1 rounded-full border border-[color:var(--border)] bg-[var(--surface)] px-4 py-2.5 text-sm text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none"
            />
            <button
              type="submit"
              aria-label={gettext("Send")}
              class="flex size-[var(--tap-min)] shrink-0 items-center justify-center rounded-full bg-[var(--accent)] text-white"
            >
              <.icon name="hero-arrow-up" class="size-5" />
            </button>
          </form>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Here">
      export default {
        mounted() {
          this.report = () => this.pushEvent("here", {path: window.location.pathname})
          this.report()
          window.addEventListener("phx:page-loading-stop", this.report)
        },
        destroyed() {
          window.removeEventListener("phx:page-loading-stop", this.report)
        }
      }
    </script>
    """
  end

  defp item_class(path, current) do
    [
      "block rounded-[var(--r-md)] px-4 py-3 text-base",
      if(path == current,
        do: "bg-[var(--bg)] font-semibold text-[color:var(--text)]",
        else: "text-[color:var(--text)]"
      )
    ]
  end
end
