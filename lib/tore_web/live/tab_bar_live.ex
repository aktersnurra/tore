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

  # Icon names written out in full, outline and filled, so Tailwind builds both.
  defp tabs do
    [
      {~p"/today", {"ph-house-simple", "ph-house-simple-fill"}, gettext("Today")},
      {~p"/plan", {"ph-calendar-blank", "ph-calendar-blank-fill"}, gettext("Plan")},
      :tore,
      {~p"/shop", {"ph-shopping-cart", "ph-shopping-cart-fill"}, gettext("Shop")},
      {~p"/recipes", {"ph-book-open", "ph-book-open-fill"}, gettext("Recipes")}
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
      <div class="mx-auto flex max-w-md items-end justify-between px-3 pt-4 pb-[calc(env(safe-area-inset-bottom)+0.25rem)]">
        <%= for tab <- @tabs do %>
          <%!-- Tore is asked, not visited: a dark button in the middle, named like the rest. --%>
          <.link
            :if={tab == :tore}
            navigate={~p"/capture?#{[return_to: @return_to]}"}
            aria-label={gettext("Ask Tore")}
            data-role="tab-tore"
            class="press group flex w-16 flex-col items-center gap-1"
          >
            <%!-- Raised above the bar, ringed in the page colour, so it reads as the one way to ask. --%>
            <span class="-mt-5 flex size-14 items-center justify-center rounded-full bg-[var(--accent)] text-[color:var(--on-accent)] shadow-[0_0_0_5px_var(--bg),var(--shadow-pop)]">
              <.icon name="ph-chat-circle-fill" class="size-6" />
            </span>
            <span class="tab-label text-[color:var(--muted)]">Tore</span>
          </.link>
          <.link
            :if={tab != :tore}
            navigate={elem(tab, 0)}
            aria-current={if current?(elem(tab, 0), @path), do: "page"}
            data-role="tab"
            class={[
              "press flex w-16 flex-col items-center gap-1 pt-1.5 transition-colors",
              current?(elem(tab, 0), @path) && "text-[color:var(--text)]",
              !current?(elem(tab, 0), @path) &&
                "text-[color:var(--muted)] hover:text-[color:var(--text)]"
            ]}
          >
            <.icon
              name={elem(elem(tab, 1), if(current?(elem(tab, 0), @path), do: 1, else: 0))}
              class="size-6"
            />
            <span class="tab-label">{elem(tab, 2)}</span>
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
