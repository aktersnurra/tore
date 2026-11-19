defmodule ToreWeb.TabBarLive do
  @moduledoc """
  The tab bar at the bottom of every screen: Today, Plan, Tore, Shop and Recipes. Tore, in the
  middle, opens the chat (`ToreWeb.CaptureLive`) over the screen it was opened from.

  It also holds the menu, the drawer from the left that a tab's top bar (`<.top_bar>`) opens: the
  rest of this week, starred recipes, the collections, the household's settings and Ask Tore.
  What's in it is read when it opens.

  On a wide screen (1024 px and up) the tab bar gives way to a sidebar that stays open: the
  tabs, then the menu's sections, then Ask Tore. Its sections are read on every navigation, and
  only when the screen is wide.

  It is a sticky LiveView in `Layouts.app`, so it survives live navigation. It isn't routed, so
  it can't see the page's URL: a hook reports `location.pathname` after every navigation, which
  marks the current tab and tells the chat where to go back to. It also says whether the screen
  is wide.
  """

  use ToreWeb, :live_view

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    scope =
      case Tore.Accounts.get_session(user_id) do
        {user, scope} ->
          Gettext.put_locale(ToreWeb.Gettext, user.locale)
          scope

        nil ->
          nil
      end

    {:ok, assign(socket, path: "/", return_to: "/", scope: scope, menu: nil, side: nil),
     layout: false}
  end

  # Every navigation reports where it landed, and closes the menu if it led there. On a wide
  # screen the sidebar's sections are read again, so they show what just changed.
  @impl true
  def handle_event("here", %{"path" => path} = here, socket) when is_binary(path) do
    side =
      case {here["wide"], socket.assigns.scope} do
        {true, %Tore.Scope{} = scope} -> menu(scope, Tore.Clock.today())
        _narrow -> nil
      end

    {:noreply,
     assign(socket, path: path, return_to: path <> (here["search"] || ""), menu: nil, side: side)}
  end

  def handle_event("open_menu", _, %{assigns: %{scope: %Tore.Scope{} = scope}} = socket),
    do: {:noreply, assign(socket, menu: menu(scope, Tore.Clock.today()))}

  def handle_event("close_menu", _, socket), do: {:noreply, assign(socket, menu: nil)}

  defp menu(scope, today) do
    {:ok, plan} =
      Tore.Planning.load_plan(scope, Tore.Streams.plan(scope, Tore.Streams.monday(today)))

    recipes = Tore.Recipes.list(scope)
    by_id = Map.new(recipes, &{&1.id, &1})
    counts = Enum.frequencies_by(recipes, & &1.recipe_type)
    sunday = Date.add(Tore.Streams.monday(today), 6)

    %{
      household: Tore.Household.get!(scope).name,
      week:
        for date <- Date.range(today, sunday) do
          slot = Map.get(plan.slots, Tore.Streams.slot_key(date))
          recipe = slot && !slot[:skipped] && slot[:recipe_id] && by_id[slot.recipe_id]

          %{
            date: date,
            today?: date == today,
            recipe: recipe || nil,
            out?: Tore.Planning.State.eating_out?(slot)
          }
        end,
      favorites: Tore.Recipes.list_favorites(scope),
      at_home: length(Tore.Pantry.list_usable(scope)),
      collections: for(type <- ToreWeb.Look.collections(), do: {type, Map.get(counts, type, 0)})
    }
  end

  defp collection_label(:meal), do: gettext("Dinner")
  defp collection_label(:baking), do: gettext("Baking")
  defp collection_label(:component), do: gettext("Sauces & sides")
  defp collection_label(:assembly), do: gettext("Assemblies")

  defp day_line(%{recipe: %{title: title}}), do: title
  defp day_line(%{out?: true}), do: gettext("Eating out")
  defp day_line(%{today?: true}), do: gettext("Tonight is open")
  defp day_line(%{date: date}), do: gettext("%{day} is open", day: ToreWeb.Dates.weekday(date))

  defp day_mark(%{today?: true}), do: gettext("tonight")

  defp day_mark(%{date: date}),
    do: date |> ToreWeb.Dates.weekday() |> String.slice(0, 3) |> String.downcase()

  defp day_href(%{recipe: %{id: id}}), do: ~p"/recipes?#{[id: id]}"
  defp day_href(%{today?: true}), do: ~p"/today"
  defp day_href(_day), do: ~p"/plan"

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
      class="fixed inset-x-0 bottom-0 z-40 bg-gradient-to-t from-[var(--bg)] from-60% to-transparent lg:hidden"
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
    <.sidebar side={@side} path={@path} return_to={@return_to} />
    <.menu :if={@menu} menu={@menu} path={@path} return_to={@return_to} />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Here">
      export default {
        mounted() {
          // The same width as Tailwind's lg, where the sidebar shows.
          this.wide = window.matchMedia("(min-width: 1024px)")
          this.report = () =>
            this.pushEvent("here", {
              path: window.location.pathname,
              search: window.location.search,
              wide: this.wide.matches
            })
          this.report()
          window.addEventListener("phx:page-loading-stop", this.report)
          this.wide.addEventListener("change", this.report)
          // A tab's top bar asks for the menu (<.top_bar>).
          this.el.addEventListener("tore:menu", () => this.pushEvent("open_menu", {}))
        },
        destroyed() {
          window.removeEventListener("phx:page-loading-stop", this.report)
          this.wide.removeEventListener("change", this.report)
        }
      }
    </script>
    """
  end

  attr :menu, :map, required: true
  attr :path, :string, required: true
  attr :return_to, :string, required: true

  defp menu(assigns) do
    ~H"""
    <div id="menu" class="fixed inset-0 z-50" phx-window-keydown="close_menu" phx-key="Escape">
      <div
        class="scrim absolute inset-0 bg-[rgb(15_15_15/0.32)]"
        phx-click="close_menu"
        aria-hidden="true"
      >
      </div>
      <nav
        aria-label={gettext("Menu")}
        data-role="menu"
        class="drawer absolute inset-y-0 left-0 flex w-[min(320px,85vw)] flex-col bg-[var(--surface)] shadow-[var(--shadow-pop)]"
      >
        <div class="flex-1 overflow-y-auto px-2.5 pt-[calc(env(safe-area-inset-top)+0.5rem)] pb-4">
          <.household name={@menu.household} />
          <.ask_tore return_to={@return_to} />
          <.sections menu={@menu} />
        </div>

        <div class="px-2.5 pt-2 pb-[calc(env(safe-area-inset-bottom)+1rem)]">
          <.settings_row />
        </div>
      </nav>
    </div>
    """
  end

  attr :side, :map, default: nil
  attr :path, :string, required: true
  attr :return_to, :string, required: true

  # The sidebar on a wide screen. The tabs, Tore among them, and Settings are there from the
  # first paint; the sections come once the hook has said the screen is wide.
  defp sidebar(assigns) do
    tore =
      {~p"/capture?#{[return_to: assigns.return_to]}", {"ph-chat-circle", "ph-chat-circle-fill"},
       "Tore"}

    assigns = assign(assigns, tabs: Enum.map(tabs(), &if(&1 == :tore, do: tore, else: &1)))

    ~H"""
    <aside
      id="sidebar"
      data-role="sidebar"
      aria-label={gettext("Menu")}
      class="fixed inset-y-0 left-0 z-30 hidden w-[248px] flex-col border-r border-[color:var(--hairline)] bg-[var(--surface)] lg:flex"
    >
      <div class="flex-1 overflow-y-auto px-2.5 pt-2 pb-4">
        <.household :if={@side} name={@side.household} />
        <div :if={!@side} class="h-11"></div>
        <.link
          :for={{href, {icon, icon_on}, label} <- @tabs}
          navigate={href}
          aria-current={if current?(href, @path), do: "page"}
          data-role="side-tab"
          class={["menu-row row-hover", current?(href, @path) && "is-current"]}
        >
          <.icon name={if current?(href, @path), do: icon_on, else: icon} class="size-5 shrink-0" />
          {label}
        </.link>
        <div :if={@side} data-role="menu-sections">
          <.sections menu={@side} tonight_lit={false} />
        </div>
      </div>
      <div class="px-2.5 pt-2 pb-4" data-role="side-foot">
        <.settings_row />
      </div>
    </aside>
    """
  end

  attr :name, :string, required: true

  defp household(assigns) do
    ~H"""
    <div class="flex h-11 items-center gap-2.5 px-1.5">
      <.page_icon
        icon="ph-house-simple-duotone"
        tint="orange"
        class="size-7 rounded-[var(--r-sm)]"
      />
      <span class="truncate font-semibold text-[color:var(--text)]" style="font-size: 15px;">
        {@name}
      </span>
    </div>
    """
  end

  attr :menu, :map, required: true

  attr :tonight_lit, :boolean,
    default: true,
    doc: "the drawer lights tonight's row; the sidebar lights only where you are"

  # What the menu holds, in the drawer and in the sidebar alike.
  defp sections(assigns) do
    ~H"""
    <p class="menu-sec">{gettext("This week")}</p>
    <.link
      :for={day <- @menu.week}
      navigate={day_href(day)}
      data-role="menu-day"
      class={["menu-row row-hover", @tonight_lit && day.today? && "is-current"]}
    >
      <span
        class="mx-1.5 size-2.5 shrink-0 rounded-[3px]"
        style={"background: var(#{cond do
          day.today? and day.recipe != nil -> "--tag-red-ink"
          day.recipe != nil -> "--tag-blue-ink"
          true -> "--subtle"
        end})"}
      >
      </span>
      <span class={["truncate", !day.recipe && "text-[color:var(--muted)]"]}>
        {day_line(day)}
      </span>
      <span class="menu-count">{day_mark(day)}</span>
    </.link>

    <%= if @menu.favorites != [] do %>
      <p class="menu-sec">{gettext("Favourites")}</p>
      <.link
        :for={recipe <- @menu.favorites}
        navigate={~p"/recipes?#{[id: recipe.id]}"}
        data-role="menu-favorite"
        class="menu-row row-hover"
      >
        <span class={[
          "size-5 shrink-0",
          ToreWeb.Look.icon(recipe),
          "ink-#{ToreWeb.Look.tint(recipe.recipe_type)}"
        ]}>
        </span>
        <span class="truncate">{recipe.title}</span>
      </.link>
    <% end %>

    <p class="menu-sec">{gettext("Collections")}</p>
    <.link
      :for={{type, count} <- @menu.collections}
      navigate={~p"/recipes?#{[type: type]}"}
      data-role="menu-collection"
      class="menu-row row-hover"
    >
      <span class={[
        "size-5 shrink-0",
        ToreWeb.Look.collection_icon(type),
        "ink-#{ToreWeb.Look.tint(type)}"
      ]}>
      </span>
      <span class="truncate">{collection_label(type)}</span>
      <span class="menu-count num">{count}</span>
    </.link>

    <p class="menu-sec">{gettext("Household")}</p>
    <.link navigate={~p"/pantry"} data-role="menu-pantry" class="menu-row row-hover">
      <span class="ph-house-simple-duotone size-5 shrink-0 text-[color:var(--tag-orange-ink)]"></span>
      <span class="truncate">{gettext("At home")}</span>
      <span class="menu-count num">{@menu.at_home}</span>
    </.link>
    <.link navigate={~p"/settings#budget"} class="menu-row row-hover">
      <span class="ph-piggy-bank-duotone size-5 shrink-0 text-[color:var(--tag-yellow-ink)]"></span>
      {gettext("Weekly budget")}
    </.link>
    """
  end

  # Settings sits apart at the foot: configuration, not a page you use every week.
  defp settings_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/settings"}
      data-role="menu-settings"
      class="menu-row row-hover text-[color:var(--muted)]"
    >
      <span class="ph-gear-six-duotone size-5 shrink-0"></span>
      {gettext("Settings")}
    </.link>
    """
  end

  attr :return_to, :string, required: true

  # First in the drawer, like search in Notion: a soft field, not a floating bar.
  defp ask_tore(assigns) do
    ~H"""
    <.link
      navigate={~p"/capture?#{[return_to: @return_to]}"}
      data-role="menu-ask"
      class="press mb-1.5 flex h-9 items-center gap-2 rounded-[var(--r-sm)] bg-[var(--sunken)] px-2.5 text-[color:var(--muted)]"
      style="font-size: 14px;"
    >
      <.icon name="ph-chat-circle" class="size-4" />
      {gettext("Ask Tore")}
    </.link>
    """
  end
end
