defmodule ToreWeb.TabBarLive do
  @moduledoc """
  The tab bar at the bottom of every screen: Today, Plan, Tore, Shop and Recipes. Tore, in the
  middle, opens the chat (`ToreWeb.CaptureLive`) over the screen it was opened from.

  It is a sticky LiveView in `Layouts.app`, so it survives live navigation. It isn't routed, so
  it can't see the page's URL: a hook reports `location.pathname` after every navigation, which
  marks the current tab and tells the chat where to go back to.
  """

  use ToreWeb, :live_view

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    case Tore.Accounts.get_session(user_id) do
      {user, _scope} -> Gettext.put_locale(ToreWeb.Gettext, user.locale)
      nil -> :ok
    end

    {:ok, assign(socket, path: "/", return_to: "/"), layout: false}
  end

  @impl true
  def handle_event("here", %{"path" => path} = here, socket) when is_binary(path),
    do: {:noreply, assign(socket, path: path, return_to: path <> (here["search"] || ""))}

  defp tabs do
    [
      {~p"/today", "hero-home", gettext("Today")},
      {~p"/plan", "hero-calendar-days", gettext("Plan")},
      :tore,
      {~p"/shop", "hero-shopping-cart", gettext("Shop")},
      {~p"/recipes", "hero-book-open", gettext("Recipes")}
    ]
  end

  # Prep belongs to the week's plan, and a recipe's pages to Recipes.
  defp current?("/plan", path), do: path in ["/plan", "/prep"]
  defp current?("/recipes", path), do: String.starts_with?(path, "/recipes")
  defp current?(tab, path), do: tab == path

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tabs: tabs())

    ~H"""
    <nav
      id="tab-bar"
      phx-hook=".Here"
      data-role="tab-bar"
      aria-label={gettext("Tabs")}
      class="fixed inset-x-0 bottom-0 z-40 bg-gradient-to-t from-[var(--bg)] from-60% to-transparent"
    >
      <div class="mx-auto flex max-w-md items-center justify-between px-5 pt-4 pb-[calc(env(safe-area-inset-bottom)+0.5rem)]">
        <%= for tab <- @tabs do %>
          <.link
            :if={tab == :tore}
            navigate={~p"/capture?#{[return_to: @return_to]}"}
            aria-label={gettext("Ask Tore")}
            data-role="tab-tore"
            class="flex size-12 items-center justify-center rounded-full bg-[var(--text)] text-[color:var(--bg)] transition-transform active:scale-95 motion-reduce:transition-none"
          >
            <.icon name="hero-sparkles-solid" class="size-5" />
          </.link>
          <.link
            :if={tab != :tore}
            navigate={elem(tab, 0)}
            aria-label={elem(tab, 2)}
            aria-current={if current?(elem(tab, 0), @path), do: "page"}
            data-role="tab"
            class={[
              "flex size-12 items-center justify-center rounded-full transition-colors active:bg-[var(--surface)]",
              current?(elem(tab, 0), @path) && "text-[color:var(--text)]",
              !current?(elem(tab, 0), @path) &&
                "text-[color:var(--muted)] hover:text-[color:var(--text)]"
            ]}
          >
            <.icon name={elem(tab, 1)} class="size-6" />
          </.link>
        <% end %>
      </div>
    </nav>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Here">
      export default {
        mounted() {
          this.report = () =>
            this.pushEvent("here", {path: window.location.pathname, search: window.location.search})
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
end
