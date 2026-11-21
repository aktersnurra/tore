defmodule ToreWeb.RecipeLive do
  use ToreWeb, :live_view
  alias Tore.Recipes

  @sorts [:recently_added, :last_used, :alphabetical]
  @time_filters [:any, 30, 45, 60]

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Tore.PubSub, Tore.Recipes.topic(socket.assigns.current_scope))

    {:ok,
     socket
     |> assign(
       recipes: Recipes.list(socket.assigns.current_scope),
       search: "",
       filter_tags: [],
       filter_type: :all,
       filter_max_min: :any,
       sort: :recently_added,
       selected: nil,
       opened: nil,
       form: nil,
       error: nil,
       adding: false,
       compose: nil,
       importing: false,
       import_error: nil,
       import_url: "",
       sorts: @sorts,
       view: recipes_view(socket.assigns.current_user),
       show_search: false,
       time_filters: @time_filters,
       show_more_filters: false,
       ingredient_rows: [],
       show_recipe_menu: false,
       before_cooking: false,
       servings: nil,
       week: nil,
       put: nil
     )
     |> ToreWeb.PiReply.init()}
  end

  # A recipe opens at its own address, so Back closes it and a link can open one.
  def handle_params(%{"id" => id} = params, _uri, socket) do
    {:noreply, socket |> select(String.to_integer(id)) |> then_do(params["then"])}
  end

  # A link shared to Tore, from the phone's share sheet or a Shortcut, is read in straight away.
  # Apps like Instagram put it in `text`, among other words. Once the import has started the
  # address drops the link, so reloading doesn't import it again.
  def handle_params(params, _uri, socket)
      when is_map_key(params, "url") or is_map_key(params, "text") do
    shared = Enum.find_value(["url", "text"], &shared_link(params[&1]))

    socket =
      assign(socket,
        adding: true,
        import_error: nil,
        import_url: shared || String.trim(params["url"] || params["text"] || ""),
        form: nil,
        selected: nil
      )

    cond do
      shared == nil ->
        {:noreply,
         assign(socket, import_error: gettext("Paste a link that starts with https://."))}

      connected?(socket) ->
        {:noreply, socket |> start_import(shared) |> push_patch(to: ~p"/recipes", replace: true)}

      true ->
        {:noreply, socket}
    end
  end

  # The sheet stays open when a shared link's address is cleaned up and pi couldn't take it.
  def handle_params(_params, _uri, %{assigns: %{adding: true}} = socket), do: {:noreply, socket}

  # A collection picked in the menu.
  def handle_params(%{"type" => type}, _uri, socket)
      when type in ~w(meal baking component assembly),
      do:
        {:noreply,
         socket |> closed() |> assign(filter_type: parse_type(type)) |> reload_recipes()}

  def handle_params(_params, _uri, socket), do: {:noreply, closed(socket)}

  # ── Events ─────────────────────────────────────────────────────────────────

  def handle_event("search", %{"query" => q}, socket) do
    recipes =
      if q == "", do: reload(socket), else: Recipes.search(socket.assigns.current_scope, q)

    {:noreply, assign(socket, search: q, recipes: recipes)}
  end

  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    tags =
      if tag in socket.assigns.filter_tags,
        do: List.delete(socket.assigns.filter_tags, tag),
        else: [tag | socket.assigns.filter_tags]

    {:noreply, socket |> assign(filter_tags: tags) |> reload_recipes()}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, socket |> assign(filter_type: parse_type(type)) |> reload_recipes()}
  end

  def handle_event("filter_time", %{"max" => max}, socket) do
    {:noreply, socket |> assign(filter_max_min: parse_time(max)) |> reload_recipes()}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    {:noreply, socket |> assign(sort: parse_sort(by)) |> reload_recipes()}
  end

  # Gallery or list; the choice is remembered for next time.
  def handle_event("set_view", %{"view" => view}, socket) when view in ~w(gallery list) do
    {:ok, user} = Tore.Accounts.put_preference(socket.assigns.current_user, "recipes_view", view)
    {:noreply, assign(socket, view: String.to_existing_atom(view), current_user: user)}
  end

  def handle_event("toggle_search", _, socket),
    do: {:noreply, assign(socket, show_search: !socket.assigns.show_search)}

  def handle_event("toggle_more_filters", _, socket) do
    {:noreply, assign(socket, show_more_filters: !socket.assigns.show_more_filters)}
  end

  # A new recipe starts from a link; writing it in by hand is the way out.
  def handle_event("new_recipe", _, socket) do
    {:noreply,
     assign(socket,
       adding: true,
       import_error: nil,
       import_url: "",
       form: nil,
       selected: nil
     )}
  end

  # Writing it in by hand. What was typed comes along: a link as the recipe's source, anything
  # else as its title.
  def handle_event("import_link", %{"write" => _} = params, socket) do
    typed = String.trim(params["url"] || "")
    field = if web_link(typed), do: :source_url, else: :title

    {:noreply,
     assign(socket,
       adding: false,
       form: Map.put(blank_form(), field, typed),
       selected: nil,
       error: nil,
       ingredient_rows: []
     )}
  end

  def handle_event("import_link", %{"url" => text}, socket) do
    socket = assign(socket, import_url: text)

    case web_link(String.trim(text)) do
      url when is_binary(url) ->
        {:noreply, start_import(socket, url)}

      nil ->
        {:noreply,
         assign(socket, import_error: gettext("Paste a link that starts with https://."))}
    end
  end

  def handle_event("save_recipe", %{"recipe" => params} = payload, socket) do
    attrs =
      parse_recipe_params(Map.put(params, "ingredients", payload["ingredients"] || %{}))

    case socket.assigns.selected do
      nil ->
        case Recipes.create(socket.assigns.current_scope, attrs) do
          {:ok, recipe} ->
            Recipes.finish(socket.assigns.current_scope, recipe.id)
            {:noreply, socket |> assign(form: nil, error: nil) |> reload_recipes()}

          {:error, changeset} ->
            {:noreply, assign(socket, error: error_message(changeset))}
        end

      recipe ->
        case Recipes.update(socket.assigns.current_scope, recipe, attrs) do
          {:ok, updated} ->
            if updated.instructions != recipe.instructions,
              do:
                Recipes.finish(
                  socket.assigns.current_scope,
                  recipe.id,
                  "Its instructions were changed by hand: write its steps again from them."
                )

            {:noreply,
             socket
             |> assign(form: nil, selected: nil, error: nil)
             |> reload_recipes()}

          {:error, changeset} ->
            {:noreply, assign(socket, error: error_message(changeset))}
        end
    end
  end

  def handle_event("select_recipe", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/recipes?#{[id: id]}")}
  end

  def handle_event("edit_recipe", _, socket) do
    recipe = socket.assigns.selected

    rows =
      Enum.map(recipe.recipe_ingredients, fn ri ->
        %{
          name: ri.ingredient.name,
          quantity: to_string(ri.quantity || ""),
          unit: ri.unit || ""
        }
      end)

    {:noreply,
     assign(socket,
       form: recipe_to_form(recipe),
       ingredient_rows: rows,
       error: nil,
       show_recipe_menu: false
     )}
  end

  def handle_event("delete_recipe", _, socket) do
    case Recipes.delete(socket.assigns.current_scope, socket.assigns.selected) do
      {:ok, _} ->
        {:noreply, socket |> reload_recipes() |> push_patch(to: ~p"/recipes")}

      {:error, _} ->
        {:noreply, assign(socket, error: gettext("Could not delete recipe"))}
    end
  end

  # Sätt ihop: a dinner from recipes the household has. Sauces and sides come first, since
  # that's what a dinner is usually put together from.
  def handle_event("compose", _, socket) do
    options =
      socket.assigns.current_scope
      |> Recipes.list(without_parts: true, sort: :alphabetical)
      |> Enum.sort_by(&(&1.recipe_type != :component))

    {:noreply,
     assign(socket, adding: false, compose: %{options: options, servings: 4, error: nil})}
  end

  def handle_event("compose_servings", %{"by" => by}, socket) do
    compose = socket.assigns.compose
    servings = (compose.servings + String.to_integer(by)) |> max(1) |> min(24)
    {:noreply, assign(socket, compose: %{compose | servings: servings})}
  end

  def handle_event("put_together", params, socket) do
    scope = socket.assigns.current_scope
    compose = socket.assigns.compose

    attrs = %{
      title: String.trim(params["title"] || ""),
      servings: compose.servings,
      part_ids: Enum.map(params["part_ids"] || [], &String.to_integer/1)
    }

    case Recipes.put_together(scope, attrs) do
      {:ok, meal} ->
        Recipes.finish(scope, meal.id)

        {:noreply,
         socket
         |> assign(compose: nil, recipes: Recipes.list(scope))
         |> push_patch(to: ~p"/recipes?#{[id: meal.id]}")}

      {:error, :too_few_parts} ->
        {:noreply, assign(socket, compose: %{compose | error: gettext("Pick at least two.")})}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, compose: %{compose | error: gettext("Give it a name.")})}

      {:error, _} ->
        {:noreply,
         assign(socket,
           compose: %{compose | error: gettext("Couldn't put it together. Try again.")}
         )}
    end
  end

  def handle_event("close", _, socket) do
    if socket.assigns.selected,
      do: {:noreply, push_patch(socket, to: ~p"/recipes")},
      else: {:noreply, closed(socket)}
  end

  # What's missing for this recipe goes on this week's list.
  def handle_event("add_missing", _params, %{assigns: %{home_added: false}} = socket) do
    %{current_scope: scope, current_user: user, home: home} = socket.assigns
    list_id = Tore.Streams.shop_list(scope, Tore.Streams.monday(Tore.Clock.today()))
    for name <- home.missing, do: Tore.Shop.add_item(scope, list_id, name, nil, nil, user.id)
    {:noreply, assign(socket, home_added: true)}
  end

  def handle_event("add_missing", _params, socket), do: {:noreply, socket}

  # Cook now, when something isn't at home: first the sheet that asks about it.
  def handle_event("before_cooking", _params, socket),
    do: {:noreply, assign(socket, before_cooking: true)}

  def handle_event("close_before_cooking", _params, socket),
    do: {:noreply, assign(socket, before_cooking: false)}

  def handle_event("servings", %{"by" => by}, socket) do
    servings = (socket.assigns.servings + String.to_integer(by)) |> max(1) |> min(24)
    {:noreply, assign(socket, servings: servings)}
  end

  def handle_event("toggle_week", _, socket) do
    week = if socket.assigns.week, do: nil, else: week_days(socket.assigns.current_scope)
    {:noreply, assign(socket, week: week, put: nil)}
  end

  # Puts the recipe on a day for the servings shown; what the day had is kept for Undo.
  # The same day again takes it back off; another day moves it there, and the first day gets
  # back what it had. Undo puts the day back.
  def handle_event("put_on", %{"date" => iso}, socket) do
    date = Date.from_iso8601!(iso)

    case socket.assigns.put do
      %{date: ^date} ->
        {:noreply, undo_put(socket)}

      _other ->
        %{current_scope: scope, selected: recipe, servings: servings} = socket.assigns
        socket = undo_put(socket)
        plan_id = Tore.Streams.plan(scope, Tore.Streams.monday(date))
        key = Tore.Streams.slot_key(date)
        {:ok, state} = Tore.Planning.load_plan(scope, plan_id)
        before = Tore.Planning.slots_before(state, [key])

        {:ok, _} = Tore.Planning.assign_recipe(scope, plan_id, key, recipe.id, servings)

        {:noreply,
         assign(socket,
           week: week_days(scope),
           put: %{date: date, plan_id: plan_id, before: before}
         )}
    end
  end

  def handle_event("undo_put", _, socket), do: {:noreply, undo_put(socket)}

  def handle_event("toggle_recipe_menu", _, socket) do
    {:noreply, assign(socket, show_recipe_menu: !socket.assigns.show_recipe_menu)}
  end

  # The star on a gallery tile.
  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    recipe = Enum.find(socket.assigns.recipes, &(&1.id == String.to_integer(id)))
    :ok = Recipes.set_favorite(socket.assigns.current_scope, recipe.id, !recipe.favorite)
    {:noreply, put_favorite(socket, recipe.id, !recipe.favorite)}
  end

  def handle_event("toggle_favorite", _, socket) do
    recipe = socket.assigns.selected
    :ok = Recipes.set_favorite(socket.assigns.current_scope, recipe.id, !recipe.favorite)

    {:noreply,
     socket |> assign(show_recipe_menu: false) |> put_favorite(recipe.id, !recipe.favorite)}
  end

  # The picture arrives on its own when pi has drawn it (`{:recipe_changed, id}`).
  def handle_event("make_image", _params, socket) do
    Recipes.finish(
      socket.assigns.current_scope,
      socket.assigns.selected.id,
      "Draw its picture again."
    )

    {:noreply,
     socket
     |> assign(show_recipe_menu: false)
     |> put_flash(:info, gettext("Making a picture. It shows up here when it's ready."))}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("add_ingredient_row", _, socket) do
    rows = socket.assigns.ingredient_rows ++ [%{name: "", quantity: "", unit: ""}]
    {:noreply, assign(socket, ingredient_rows: rows)}
  end

  def handle_event("remove_ingredient_row", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    rows = List.delete_at(socket.assigns.ingredient_rows, idx)
    {:noreply, assign(socket, ingredient_rows: rows)}
  end

  def handle_event("sync_ingredient", params, socket) do
    rows =
      (params["ingredients"] || %{})
      |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
      |> Enum.map(fn {_, ing} ->
        %{name: ing["name"] || "", quantity: ing["quantity"] || "", unit: ing["unit"] || ""}
      end)

    {:noreply, assign(socket, ingredient_rows: rows)}
  end

  # pi changed a recipe, or undo put it back: what's on screen shows it as it is now.
  def handle_info({:recipe_changed, id}, socket) do
    socket = reload_recipes(socket)

    case socket.assigns.selected do
      %{id: ^id} ->
        {:noreply, assign(socket, selected: Recipes.get!(socket.assigns.current_scope, id))}

      _other ->
        {:noreply, socket}
    end
  end

  # A star set here or on another phone.
  def handle_info({:recipe_favorite, id, favorite?}, socket),
    do: {:noreply, put_favorite(socket, id, favorite?)}

  # The recipe pi saved from the link: a toast says so, and it is in the list.
  def handle_info({:recipe_saved, id}, %{assigns: %{importing: true}} = socket) do
    title = Recipes.get!(socket.assigns.current_scope, id).title

    {:noreply,
     socket
     |> assign(importing: false)
     |> put_flash(:info, gettext("Saved %{title}.", title: title))
     |> reload_recipes()}
  end

  def handle_info({:recipe_saved, _id}, socket), do: {:noreply, reload_recipes(socket)}

  # pi answers the link in the person's chat. If it is done without saving a recipe, what it said
  # is why (not a recipe, the site refused), in a toast.
  def handle_info({:pi, _session, event}, socket) do
    if socket.assigns.before_cooking, do: ToreWeb.BeforeCooking.forward(event)
    socket = ToreWeb.PiReply.event(socket, event)

    case {event, socket.assigns} do
      {%{"type" => type}, %{importing: true}} when type in ["agent_settled", "exited"] ->
        why = blank_to_nil(socket.assigns.pi_reply) || gettext("Couldn't import that URL.")
        {:noreply, socket |> assign(importing: false) |> put_flash(:error, why)}

      _other ->
        {:noreply, socket}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  defp undo_put(%{assigns: %{put: %{} = put}} = socket) do
    :ok = Tore.Planning.restore_slots(socket.assigns.current_scope, put.plan_id, put.before)
    assign(socket, week: week_days(socket.assigns.current_scope), put: nil)
  end

  defp undo_put(socket), do: socket

  defp select(socket, id) do
    recipe = Recipes.get!(socket.assigns.current_scope, id)

    scope = socket.assigns.current_scope
    names = Enum.map(recipe.recipe_ingredients, & &1.ingredient.name)
    home = Tore.Pantry.at_home(scope, names)
    list_id = Tore.Streams.shop_list(scope, Tore.Streams.monday(Tore.Clock.today()))

    assign(socket,
      selected: recipe,
      part_of: Recipes.meals_with(scope, recipe.id),
      servings: recipe.base_servings || 4,
      home: home,
      # Already on the list when there's nothing left to put there.
      home_added: Tore.Shop.not_on_list(scope, list_id, home.missing) == [],
      week: nil,
      put: nil,
      opened: id,
      form: nil,
      error: nil,
      show_recipe_menu: false,
      before_cooking: false
    )
  end

  defp closed(socket) do
    assign(socket,
      week: nil,
      put: nil,
      selected: nil,
      form: nil,
      adding: false,
      compose: nil,
      import_error: nil,
      error: nil,
      show_recipe_menu: false,
      before_cooking: false
    )
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      current_user={@current_user}
    >
      <.page max_width={:xl}>
        <.top_bar />
        <div class="mb-5">
          <header class="pt-1">
            <.page_icon icon="ph-book-open-duotone" tint="grey" />
            <h1 class="t-display mt-3">{gettext("Recipes")}</h1>
            <p class="num mt-1 text-[color:var(--muted)]" style="font-size: 15px;">
              {recipe_count_label(@recipes)}
            </p>
          </header>

          <%!-- The toolbar: the two views, then search, filters and New --%>
          <div class="mt-4 flex items-center gap-1 border-b border-[color:var(--hairline)] pb-1.5">
            <div class="flex gap-1" role="tablist">
              <button
                :for={
                  {view, icon, label} <- [
                    {:gallery, "ph-squares-four", gettext("Gallery")},
                    {:list, "ph-list-bullets", gettext("List")}
                  ]
                }
                type="button"
                phx-click="set_view"
                phx-value-view={view}
                role="tab"
                aria-selected={to_string(@view == view)}
                aria-label={label}
                title={label}
                data-view={view}
                class={[
                  "view-tab press grid size-8 place-items-center rounded-[var(--r-sm)]",
                  @view == view && "is-open",
                  @view != view && "text-[color:var(--muted)]"
                ]}
              >
                <.icon name={icon} class="size-5" />
              </button>
            </div>
            <span class="flex-1"></span>
            <button
              type="button"
              phx-click="toggle_search"
              aria-label={gettext("Search recipes")}
              aria-expanded={to_string(@show_search or @search != "")}
              class="icon-btn press"
            >
              <.icon name="ph-magnifying-glass" class="size-5" />
            </button>
            <button
              type="button"
              phx-click="toggle_more_filters"
              aria-label={gettext("More filters")}
              aria-expanded={to_string(@show_more_filters)}
              class={[
                "icon-btn press",
                @show_more_filters && "bg-[var(--sunken)] text-[color:var(--text)]"
              ]}
            >
              <.icon name="ph-sliders-horizontal" class="size-5" />
            </button>
            <button
              type="button"
              phx-click="new_recipe"
              aria-label={gettext("New recipe")}
              title={gettext("New recipe")}
              data-role="new-recipe"
              class="press ml-1 grid size-8 place-items-center rounded-[var(--r-md)] bg-[var(--accent)] text-[color:var(--on-accent)] hover:bg-[var(--accent-hover)]"
            >
              <.icon name="ph-plus" class="size-5" />
            </button>
          </div>

          <div class="mt-3 space-y-4">
            <%!-- Search, once asked for --%>
            <form :if={@show_search or @search != ""} phx-change="search" class="settle">
              <.field
                id="recipe-search"
                name="query"
                value={@search}
                placeholder={gettext("Search recipes, ingredients, or meals…")}
                aria-label={gettext("Search recipes, ingredients, or meals…")}
                autofocus
              >
                <:leading>
                  <.icon name="ph-magnifying-glass" class="size-5 shrink-0 text-[color:var(--muted)]" />
                </:leading>
              </.field>
            </form>

            <%!-- Expanded filters --%>
            <div :if={@show_more_filters} class="reveal space-y-3 pt-1">
              <div class="flex flex-wrap gap-2">
                <button
                  :for={tag <- common_tags()}
                  phx-click="filter_tag"
                  phx-value-tag={tag}
                  class={[
                    "px-3 h-7 rounded-[var(--r-pill)] transition-colors",
                    tag in @filter_tags &&
                      "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)]",
                    tag not in @filter_tags && "text-[color:var(--muted)] hover:text-[var(--text)]"
                  ]}
                  style="font-size: var(--t-meta);"
                >
                  {tag_label(tag)}
                </button>
              </div>
              <div
                class="flex flex-wrap items-center gap-x-6 gap-y-2 text-[color:var(--muted)]"
                style="font-size: var(--t-meta);"
              >
                <span class="text-[color:var(--subtle)] font-medium">{gettext("Time")}</span>
                <button
                  :for={t <- @time_filters}
                  phx-click="filter_time"
                  phx-value-max={t}
                  class={[
                    @filter_max_min == t && "text-[color:var(--accent)] font-medium",
                    @filter_max_min != t && "hover:text-[var(--text)]"
                  ]}
                >
                  {if t == :any, do: gettext("Any"), else: gettext("≤ %{n} min", n: t)}
                </button>
                <span class="ml-4 text-[color:var(--subtle)] font-medium">{gettext("Sort")}</span>
                <button
                  :for={s <- @sorts}
                  phx-click="sort"
                  phx-value-by={s}
                  class={[
                    @sort == s && "text-[color:var(--accent)] font-medium",
                    @sort != s && "hover:text-[var(--text)]"
                  ]}
                >
                  {sort_label(s)}
                </button>
              </div>
            </div>
          </div>
        </div>

        <p :if={@error} class="mb-4 text-[color:var(--danger)]" style="font-size: var(--t-meta);">
          {@error}
        </p>

        <div :if={@recipes == []} class="pt-4">
          <p class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
            {gettext("No recipes here")}
          </p>
          <p class="mt-1 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
            {gettext("Send Tore a link or a photo of a recipe, or write one yourself.")}
          </p>
        </div>

        <%!-- The library by collection. A group's tag shows that collection alone; tapped again,
             all of them. --%>
        <section :for={{type, recipes} <- groups(@recipes, @filter_type)} class="mb-7">
          <div class="mb-2.5 flex items-center gap-2">
            <button
              type="button"
              phx-click="filter_type"
              phx-value-type={if @filter_type == type, do: "all", else: type}
              aria-selected={to_string(@filter_type == type)}
              data-collection={type}
              class={["tag press", "tag-#{ToreWeb.Look.tint(type)}"]}
            >
              <.icon name={type_icon(type)} />
              {type_label(type)}
              <.icon :if={@filter_type == type} name="ph-x" class="opacity-70" />
            </button>
            <span class="num text-[13px] text-[color:var(--muted)]">{length(recipes)}</span>
          </div>

          <%!-- Gallery: two to a row, 4:5 pictures, the name on the picture. On a laptop the
             pointer on a tile shows its quick actions, in the order of its page's buttons. --%>
          <ul
            :if={@view == :gallery}
            class="grid grid-cols-2 gap-x-3 gap-y-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5"
          >
            <li
              :for={{recipe, i} <- Enum.with_index(recipes)}
              class="reveal relative"
              style={"--i: #{min(i, 8)}"}
            >
              <.link
                patch={~p"/recipes?#{[id: recipe.id]}"}
                data-dish={recipe.id}
                class="press-soft group relative block aspect-[4/5] w-full overflow-hidden rounded-[var(--r-lg)] text-left [clip-path:inset(0_round_var(--r-lg))]"
              >
                <%!-- clip-path, not only overflow: the browser leaves the picture's corners
                   square while its zoom animates, and rounds them only once it stops. --%>
                <.blank_cover :if={!recipe.image_path} dish={recipe} />
                <img
                  :if={recipe.image_path}
                  src={~p"/images/recipes/#{recipe.id}"}
                  alt=""
                  loading="lazy"
                  class="absolute inset-0 size-full rounded-[inherit] object-cover transition-transform duration-500 ease-[var(--ease-out)] group-hover:scale-[1.03]"
                  style={
                    if @selected == nil and @opened == recipe.id,
                      do: "view-transition-name: dish-#{recipe.id}"
                  }
                />
                <span
                  :if={recipe.image_path}
                  class="photo-shade absolute inset-0"
                  aria-hidden="true"
                >
                </span>
                <span class={[
                  "absolute inset-x-0 bottom-0 block p-3",
                  recipe.image_path && "on-photo-text"
                ]}>
                  <span
                    class={[
                      "line-clamp-2 block font-semibold",
                      !recipe.image_path && "text-[color:var(--text)]"
                    ]}
                    style="font-size: 14.5px; line-height: 1.25;"
                  >
                    <.icon
                      :if={recipe.favorite}
                      name="ph-star-fill"
                      class={[
                        "-mt-0.5 mr-0.5 size-3.5",
                        !recipe.image_path && "text-[color:var(--tag-yellow-ink)]"
                      ]}
                    />
                    {recipe.title}
                  </span>
                  <span
                    :if={recipe_meta(recipe) != ""}
                    class={[
                      "num mt-0.5 block truncate",
                      if(recipe.image_path, do: "opacity-85", else: "text-[color:var(--muted)]")
                    ]}
                    style="font-size: 12.5px;"
                  >
                    {recipe_meta(recipe)}
                  </span>
                </span>
              </.link>
              <div
                data-role="tile-actions"
                data-for={recipe.id}
                class="tile-actions absolute inset-x-2 top-2 flex gap-1.5"
              >
                <.link
                  patch={~p"/recipes?#{[id: recipe.id, then: "cook"]}"}
                  data-action="cook"
                  aria-label={cook_label(recipe)}
                  title={cook_label(recipe)}
                  class="on-photo press"
                >
                  <.icon name="ph-fire" class="size-4" />
                </.link>
                <.link
                  :if={recipe.recipe_type == :meal}
                  patch={~p"/recipes?#{[id: recipe.id, then: "week"]}"}
                  data-action="week"
                  aria-label={gettext("Put on the week")}
                  title={gettext("Put on the week")}
                  class="on-photo press"
                >
                  <.icon name="ph-calendar-blank" class="size-4" />
                </.link>
                <.link
                  navigate={~p"/capture?#{[return_to: "/recipes", recipe: recipe.id]}"}
                  data-action="ask"
                  aria-label={gettext("Ask Tore")}
                  title={gettext("Ask Tore")}
                  class="on-photo press"
                >
                  <.icon name="ph-chat-circle" class="size-4" />
                </.link>
                <button
                  type="button"
                  phx-click="toggle_favorite"
                  phx-value-id={recipe.id}
                  data-action="favorite"
                  aria-pressed={to_string(recipe.favorite)}
                  aria-label={gettext("Favourite")}
                  title={gettext("Favourite")}
                  class="on-photo press ml-auto"
                >
                  <.icon
                    name={if recipe.favorite, do: "ph-star-fill", else: "ph-star"}
                    class="size-4"
                  />
                </button>
              </div>
            </li>
          </ul>

          <%!-- List: one line each, for scanning and searching --%>
          <ul :if={@view == :list} class="border-t border-[color:var(--hairline)]">
            <li :for={recipe <- recipes} class="border-b border-[color:var(--hairline)]">
              <.link
                patch={~p"/recipes?#{[id: recipe.id]}"}
                data-dish={recipe.id}
                class="row-hover press-soft -mx-2 flex items-center gap-3 rounded-[var(--r-md)] px-2 py-2"
              >
                <span class="relative size-11 shrink-0 overflow-hidden rounded-[var(--r-md)]">
                  <.blank_cover :if={!recipe.image_path} dish={recipe} icon_class="size-6" />
                  <img
                    :if={recipe.image_path}
                    src={~p"/images/recipes/#{recipe.id}"}
                    alt=""
                    loading="lazy"
                    class="size-full object-cover"
                  />
                </span>
                <span class="min-w-0 flex-1">
                  <span
                    class="block truncate font-semibold text-[color:var(--text)]"
                    style="font-size: 15.5px;"
                  >
                    {recipe.title}
                  </span>
                  <span
                    :if={recipe_meta(recipe) != ""}
                    class="num block truncate text-[color:var(--muted)]"
                    style="font-size: 13px;"
                  >
                    {recipe_meta(recipe)}
                  </span>
                </span>
                <.icon
                  :if={recipe.favorite}
                  name="ph-star-fill"
                  class="size-4 shrink-0 text-[color:var(--tag-yellow-ink)]"
                />
              </.link>
            </li>
          </ul>
        </section>

        <%!-- A recipe is a page over the list; on a wide screen it fills the space beside the sidebar. --%>
        <div
          :if={@selected != nil or @form != nil or @adding or @compose != nil}
          class={[
            "fixed inset-0 z-50 flex items-end justify-center md:items-center md:p-4",
            recipe_page?(assigns) && "lg:left-[248px] lg:items-stretch lg:p-0"
          ]}
          phx-window-keydown="close"
          phx-key="Escape"
        >
          <div
            class={[
              "scrim absolute inset-0 hidden bg-black/50 md:block",
              recipe_page?(assigns) && "lg:hidden"
            ]}
            phx-click="close"
          >
          </div>
          <div
            data-role={recipe_page?(assigns) && "recipe-page"}
            class={[
              "relative h-full w-full overflow-y-auto bg-[var(--bg)] md:h-auto md:max-h-[90vh] md:max-w-lg md:rounded-[28px] md:shadow-[var(--shadow-pop)]",
              recipe_page?(assigns) &&
                "lg:h-full lg:max-h-none lg:max-w-none lg:rounded-none lg:shadow-none",
              (@form || @adding || @compose) && "sheet"
            ]}
          >
            <%= cond do %>
              <% @form -> %>
                <div class="p-6">{render_form(assigns)}</div>
              <% @adding -> %>
                <div class="p-6">{render_link(assigns)}</div>
              <% @compose -> %>
                <div class="p-6">{render_compose(assigns)}</div>
              <% @selected -> %>
                {render_detail(assigns)}
              <% true -> %>
            <% end %>
          </div>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  # A recipe on its own, not the form, the link panel or Sätt ihop over it.
  defp recipe_page?(assigns),
    do: assigns.selected != nil and !(assigns.form || assigns.adding || assigns.compose)

  defp render_detail(assigns) do
    ~H"""
    <article>
      <%!-- On a laptop each part is Plan's width (56rem of content, 59rem with its padding), as
         Today and Hemma are, so the day-to-day screens feel like one. --%>
      <%!-- Back and ⋯ on the page, above the hero --%>
      <div class="flex items-center justify-between px-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] lg:mx-auto lg:max-w-[59rem] lg:px-6 lg:pt-5">
        <.link
          patch={~p"/recipes"}
          aria-label={gettext("Back")}
          data-role="recipe-close"
          class="icon-btn press"
        >
          <.icon name="ph-caret-left" class="size-5" />
        </.link>
        <div class="relative" id="recipe-actions">
          <button
            type="button"
            phx-click="toggle_recipe_menu"
            aria-label={gettext("More")}
            aria-expanded={to_string(@show_recipe_menu)}
            class="icon-btn press"
          >
            <.icon name="ph-dots-three" class="size-5" />
          </button>
          <div
            :if={@show_recipe_menu}
            phx-click-away="toggle_recipe_menu"
            class="rise-in absolute right-0 top-12 z-10 w-48 origin-top-right overflow-hidden rounded-[var(--r-lg)] bg-[var(--sunken)] py-1 shadow-[var(--shadow-pop)]"
          >
            <button
              type="button"
              phx-click="toggle_favorite"
              data-role="toggle-favorite"
              class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--text)] hover:bg-[var(--border)]"
              style="font-size: 15px;"
            >
              <.icon
                name={if @selected.favorite, do: "ph-star-fill", else: "ph-star"}
                class="size-4 text-[color:var(--muted)]"
              />
              {if @selected.favorite,
                do: gettext("Remove from favourites"),
                else: gettext("Add to favourites")}
            </button>
            <button
              type="button"
              phx-click="edit_recipe"
              class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--text)] hover:bg-[var(--border)]"
              style="font-size: 15px;"
            >
              <.icon name="ph-pencil-simple" class="size-4 text-[color:var(--muted)]" />
              {gettext("Edit")}
            </button>
            <button
              type="button"
              phx-click="make_image"
              class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--text)] hover:bg-[var(--border)]"
              style="font-size: 15px;"
            >
              <.icon name="ph-image" class="size-4 text-[color:var(--muted)]" />
              {gettext("New picture")}
            </button>
            <button
              type="button"
              phx-click="delete_recipe"
              class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--danger)] hover:bg-[var(--border)]"
              style="font-size: 15px;"
            >
              <.icon name="ph-trash" class="size-4" />
              {gettext("Delete")}
            </button>
          </div>
        </div>
      </div>

      <%!-- The hero, like Andy Cooks': the words on the left, the dish on the right. On a phone the
           dish comes first. --%>
      <section
        data-role="hero"
        class="px-5 pt-2 lg:grid lg:mx-auto lg:max-w-[59rem] lg:grid-cols-2 lg:items-center lg:gap-14 lg:px-6 lg:pt-4"
      >
        <div class="reveal relative aspect-[5/4] w-full overflow-hidden rounded-[var(--r-lg)] bg-[var(--sunken)] lg:order-2">
          <.blank_cover :if={!@selected.image_path} dish={@selected} icon_class="size-20" />
          <img
            :if={@selected.image_path}
            src={~p"/images/recipes/#{@selected.id}"}
            alt=""
            class="absolute inset-0 size-full rounded-[inherit] object-cover"
            style={"view-transition-name: dish-#{@selected.id}"}
          />
        </div>

        <div class="mt-6 lg:order-1 lg:mt-0">
          <nav
            aria-label={gettext("Collection")}
            data-role="collection"
            class="reveal t-eyebrow flex items-center gap-1"
            style="--i: 1"
          >
            <.link patch={~p"/recipes"} class="hover:text-[color:var(--text)]">
              {gettext("Recipes")}
            </.link>
            <.icon name="ph-caret-right" class="size-3" />
            <.link
              patch={~p"/recipes?#{[type: @selected.recipe_type]}"}
              class="hover:text-[color:var(--text)]"
            >
              {type_label(@selected.recipe_type)}
            </.link>
          </nav>
          <h1 class="reveal t-hero mt-2" style="--i: 2">{@selected.title}</h1>

          <dl
            :if={total_minutes(@selected) > 0}
            data-role="times"
            class="reveal num mt-4 flex flex-wrap items-center gap-x-5 gap-y-1"
            style="--i: 3; font-size: 15px;"
          >
            <.icon name="ph-clock" class="size-5 text-[color:var(--muted)]" />
            <div :if={@selected.prep_time_minutes} class="flex gap-1">
              <dt class="font-semibold">{gettext("Prep:")}</dt>
              <dd>{duration(@selected.prep_time_minutes)}</dd>
            </div>
            <div :if={@selected.cook_time_minutes} class="flex gap-1">
              <dt class="font-semibold">{gettext("Cook:")}</dt>
              <dd>{duration(@selected.cook_time_minutes)}</dd>
            </div>
            <div class="flex gap-1">
              <dt class="font-semibold">{gettext("Total:")}</dt>
              <dd>{duration(total_minutes(@selected))}</dd>
            </div>
          </dl>

          <p
            :if={@selected.description not in [nil, ""]}
            class="reveal mt-4 text-[color:var(--text)] lg:max-w-[52ch]"
            style="--i: 3; font-size: 16px; line-height: 1.55;"
          >
            {@selected.description}
          </p>

          <%!-- What you can do with it --%>
          <%!-- On a phone the main action is the width of the page, the others a row under it. --%>
          <div
            data-role="actions"
            class="reveal mt-6 grid grid-cols-2 gap-2 lg:flex lg:flex-wrap [&>:first-child]:col-span-2 [&>:nth-child(2):last-child]:col-span-2"
            style="--i: 4"
          >
            <.link
              :if={@home.missing == []}
              navigate={~p"/recipes/#{@selected.id}/cook?#{[servings: @servings]}"}
              data-role="start-cooking"
              class="pill pill-lg pill-lamp press"
            >
              <.icon name="ph-fire-fill" />
              {if @selected.recipe_type == :baking, do: gettext("Bake now"), else: gettext("Cook now")}
            </.link>
            <button
              :if={@home.missing != []}
              type="button"
              phx-click="before_cooking"
              data-role="start-cooking"
              class="pill pill-lg pill-lamp press"
            >
              <.icon name="ph-fire-fill" />
              {if @selected.recipe_type == :baking, do: gettext("Bake now"), else: gettext("Cook now")}
            </button>
            <button
              :if={@selected.recipe_type == :meal}
              type="button"
              phx-click="toggle_week"
              aria-expanded={to_string(@week != nil)}
              data-role="put-on-week"
              class="pill pill-lg press"
            >
              <.icon name="ph-calendar-blank" /> {gettext("Put on the week")}
            </button>
            <.link
              navigate={
                ~p"/capture?#{[return_to: "/recipes?id=#{@selected.id}", recipe: @selected.id]}"
              }
              data-role="ask-tore"
              class="pill pill-lg press"
            >
              <.icon name="ph-chat-circle" /> {gettext("Ask Tore")}
            </.link>
          </div>
        </div>
      </section>

      <div class="px-5 pb-28 lg:mx-auto lg:max-w-[59rem] lg:px-6 lg:pb-16">
        <%!-- The page's properties: quiet rows, a label and its value. Servings is a stepper. --%>
        <dl class="props reveal mt-8 lg:max-w-2xl" style="--i: 5">
          <div>
            <dt><.icon name="ph-users" /> {gettext("Servings")}</dt>
            <dd class="flex items-center gap-1">
              <button
                type="button"
                phx-click="servings"
                phx-value-by="-1"
                disabled={@servings <= 1}
                aria-label={gettext("Fewer servings")}
                class="step-btn press"
              >
                <.icon name="ph-minus" class="size-4" />
              </button>
              <span
                id={"servings-#{@servings}"}
                data-role="servings"
                class="settle num w-8 text-center font-semibold"
              >
                {@servings}
              </span>
              <button
                type="button"
                phx-click="servings"
                phx-value-by="1"
                disabled={@servings >= 24}
                aria-label={gettext("More servings")}
                class="step-btn press"
              >
                <.icon name="ph-plus" class="size-4" />
              </button>
            </dd>
          </div>
          <div :if={source_host(@selected)}>
            <dt><.icon name="ph-link" /> {gettext("Source")}</dt>
            <dd>
              <a
                href={@selected.source_url}
                target="_blank"
                rel="noopener"
                class="underline decoration-[color:var(--hairline)] underline-offset-4 hover:decoration-[color:var(--text)]"
              >
                {source_host(@selected)}
              </a>
            </dd>
          </div>
          <div :if={@selected.parts != []}>
            <dt><.icon name="ph-squares-four" /> {gettext("Parts")}</dt>
            <dd data-role="parts" class="flex flex-wrap gap-x-3 gap-y-1 py-1.5">
              <.link
                :for={part <- @selected.parts}
                navigate={~p"/recipes?#{[id: part.id]}"}
                class="underline decoration-[color:var(--hairline)] underline-offset-4 hover:decoration-[color:var(--text)]"
              >
                {part.title}
              </.link>
            </dd>
          </div>
          <div :if={@part_of != []}>
            <dt><.icon name="ph-squares-four" /> {gettext("Part of")}</dt>
            <dd data-role="part-of" class="flex flex-wrap gap-x-3 gap-y-1 py-1.5">
              <.link
                :for={meal <- @part_of}
                navigate={~p"/recipes?#{[id: meal.id]}"}
                class="underline decoration-[color:var(--hairline)] underline-offset-4 hover:decoration-[color:var(--text)]"
              >
                {meal.title}
              </.link>
            </dd>
          </div>
          <div :if={@selected.recipe_ingredients != []} data-role="at-home">
            <dt>
              <.link
                navigate={~p"/pantry"}
                data-role="to-pantry"
                class="press flex items-center gap-2 hover:underline"
              >
                <.icon name="ph-house-simple" /> {gettext("At home")}
              </.link>
            </dt>
            <dd :if={@home.missing == []} class="font-semibold text-[color:var(--done)]">
              {gettext("All of it")}
            </dd>
            <dd :if={@home.missing != []} class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
              <span class="text-[color:var(--muted)]">
                {gettext("Missing: %{things}", things: Enum.join(@home.missing, ", "))}
              </span>
              <button
                :if={!@home_added}
                type="button"
                phx-click="add_missing"
                class="press font-semibold text-[color:var(--accent-ink)] hover:underline"
              >
                {gettext("Put on the list")}
              </button>
              <.link
                :if={@home_added}
                id="home-added"
                navigate={~p"/shop"}
                class="settle inline-flex items-center gap-1 font-semibold text-[color:var(--done)]"
              >
                <.icon name="ph-check" class="size-4" /> {gettext("On the list")}
              </.link>
            </dd>
          </div>
          <div :if={@selected.last_used_at}>
            <dt><.icon name="ph-calendar-blank" /> {gettext("Last made")}</dt>
            <dd>{ToreWeb.Dates.day(DateTime.to_date(@selected.last_used_at))}</dd>
          </div>
        </dl>

        <%!-- Which day: the next seven, each with what it has now. --%>
        <.live_component
          :if={@before_cooking}
          module={ToreWeb.BeforeCooking}
          id="before-cooking"
          scope={@current_scope}
          recipe={@selected}
          missing={@home.missing}
          cook_params={[servings: @servings]}
          on_close="close_before_cooking"
        />

        <div :if={@week} id="week-days" class="reveal mt-4 lg:max-w-xl" data-role="week-days">
          <p class="t-eyebrow mb-2">{gettext("Which day?")}</p>
          <ul class="menu-lines">
            <li :for={day <- @week} class="flex items-center gap-3 py-1">
              <button
                type="button"
                phx-click="put_on"
                phx-value-date={Date.to_iso8601(day.date)}
                disabled={day.recipe_id == @selected.id and !(@put && @put.date == day.date)}
                aria-pressed={to_string(@put != nil and @put.date == day.date)}
                data-day={Date.to_iso8601(day.date)}
                class="row-hover press-soft flex min-h-12 flex-1 items-center justify-between gap-3 rounded-[var(--r-md)] px-2 text-left"
              >
                <span class="font-semibold text-[color:var(--text)]">
                  {ToreWeb.Dates.weekday(day.date)}
                  <span class="num font-normal text-[color:var(--muted)]">{day.date.day}</span>
                </span>
                <%!-- The day just chosen is green with a tick; a day that had it before is plain --%>
                <span class={[
                  "flex min-w-0 items-center gap-1.5",
                  @put && @put.date == day.date && "text-[color:var(--done)] font-semibold",
                  !(@put && @put.date == day.date) && day.recipe_id == @selected.id &&
                    "text-[color:var(--text)]",
                  day.recipe_id != @selected.id && "text-[color:var(--muted)]"
                ]}>
                  <.icon :if={@put && @put.date == day.date} name="ph-check" class="size-4 shrink-0" />
                  <span class="truncate">{day.title || gettext("Free")}</span>
                </span>
              </button>
            </li>
          </ul>
          <p
            :if={@put}
            class="settle mt-2 flex items-center gap-3 px-2 text-[color:var(--muted)]"
            style="font-size: 15px;"
            data-role="put-done"
          >
            <.icon name="ph-check" class="size-4 text-[color:var(--done)]" />
            {gettext("On %{day}", day: ToreWeb.Dates.weekday_in_sentence(@put.date))}
            <button
              type="button"
              phx-click="undo_put"
              class="press ml-auto font-semibold text-[color:var(--accent-ink)]"
            >
              {gettext("Undo")}
            </button>
          </p>
        </div>

        <%!-- On a wide screen the ingredients sit beside the method, both in view while cooking --%>
        <div
          data-role="recipe-body"
          class={[
            @selected.recipe_ingredients != [] &&
              "lg:grid lg:grid-cols-[minmax(0,22rem)_minmax(0,1fr)] lg:gap-x-16"
          ]}
        >
          <%!-- Ingredients for the servings above: the name on the left, the amount on the right --%>
          <section :if={@selected.recipe_ingredients != []} class="reveal mt-9" style="--i: 4">
            <h2 class="t-head mb-3">{gettext("Ingredients")}</h2>
            <ul :if={@selected.parts == []} class="menu-lines">
              <.ingredient_line
                :for={ri <- @selected.recipe_ingredients}
                ri={ri}
                base={@selected.base_servings}
                servings={@servings}
              />
            </ul>
            <%!-- A meal of parts: each part's own, for the servings chosen --%>
            <div :for={part <- @selected.parts} data-part={part.id} class="mb-6 last:mb-0">
              <h3 class="t-eyebrow mb-1">{part.title}</h3>
              <ul class="menu-lines">
                <.ingredient_line
                  :for={ri <- part.recipe_ingredients}
                  ri={ri}
                  base={part.base_servings}
                  servings={@servings}
                />
              </ul>
            </div>
          </section>

          <%!-- A meal of parts before its first cook: each part's method; one order is written then --%>
          <section
            :if={@selected.parts != [] and is_nil(@selected.steps)}
            data-role="part-methods"
            class="mt-9"
          >
            <h2 class="t-head mb-1">{gettext("Method")}</h2>
            <p class="mb-5 text-[color:var(--muted)]" style="font-size: 15px;">
              {gettext("Tore puts the parts in one order when you start cooking.")}
            </p>
            <div :for={part <- @selected.parts} class="mb-7 last:mb-0">
              <h3 class="t-eyebrow mb-3">{part.title}</h3>
              <ol :if={part_actions(part) != []} class="list-decimal space-y-3 pl-5">
                <li
                  :for={action <- part_actions(part)}
                  class="text-[color:var(--text)]"
                  style="font-size: 16px; line-height: 1.55;"
                >
                  {action}
                </li>
              </ol>
              <p
                :if={part_actions(part) == [] and part.instructions}
                class="whitespace-pre-line text-[color:var(--text)]"
                style="font-size: 16px; line-height: 1.55;"
              >
                {part.instructions}
              </p>
            </div>
          </section>

          <%!-- The method: a real sequence, so it is numbered --%>
          <section
            :if={
              (@selected.steps || @selected.instructions) &&
                !(@selected.parts != [] and is_nil(@selected.steps))
            }
            class="mt-9"
          >
            <h2 class="t-head mb-4">{gettext("Method")}</h2>
            <%= if grouped_steps(@selected) != [] do %>
              <div :for={{phase, steps} <- grouped_steps(@selected)} class="mb-7 last:mb-0">
                <h3 :if={phase} class="t-eyebrow mb-3">{phase}</h3>
                <ol class="space-y-5">
                  <li :for={step <- steps} class="flex gap-4">
                    <span
                      class="num w-6 shrink-0 text-right font-semibold text-[color:var(--subtle)]"
                      style="font-size: 20px; line-height: 1.3;"
                    >
                      {step["order"]}
                    </span>
                    <div class="flex-1">
                      <p class="text-[color:var(--text)]" style="font-size: 16px; line-height: 1.55;">
                        {step["action"]}
                      </p>
                      <p
                        :if={step["duration_minutes"]}
                        class="num mt-1 text-[color:var(--muted)]"
                        style="font-size: 13px;"
                      >
                        {gettext("%{minutes} min", minutes: step["duration_minutes"])}
                      </p>
                    </div>
                  </li>
                </ol>
              </div>
            <% else %>
              <div class="prose prose-sm max-w-none text-[color:var(--text)]">
                {raw(MDEx.to_html!(@selected.instructions || ""))}
              </div>
            <% end %>
          </section>
        </div>
      </div>
    </article>
    """
  end

  attr :ri, :map, required: true
  attr :base, :integer, default: nil
  attr :servings, :integer, required: true

  defp ingredient_line(assigns) do
    ~H"""
    <li class="flex items-baseline justify-between gap-4 py-3.5">
      <span class="text-[color:var(--text)]" style="font-size: 16px;">
        {@ri.ingredient.name}
      </span>
      <span
        id={"amount-#{@ri.id}-#{@servings}"}
        data-role="amount"
        class="settle num shrink-0 text-[color:var(--muted)]"
        style="font-size: 15px;"
      >
        {amount(@ri, @base, @servings)}
      </span>
    </li>
    """
  end

  defp part_actions(part) do
    part
    |> Tore.Recipes.Recipe.decode_steps()
    |> Enum.sort_by(& &1["order"])
    |> Enum.map(& &1["action"])
  end

  defp amount(ri, base, servings) do
    quantity = Recipes.scale_quantity(ri.quantity, base, servings)
    unit = if ri.unit not in [nil, ""], do: " #{ri.unit}"
    "#{quantity}#{unit}"
  end

  # The next seven days, each with the dinner it has now.
  defp week_days(scope) do
    today = Tore.Clock.today()
    dates = Enum.map(0..6, &Date.add(today, &1))

    slots =
      dates
      |> Enum.map(&Tore.Streams.monday/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn monday ->
        {:ok, state} = Tore.Planning.load_plan(scope, Tore.Streams.plan(scope, monday))
        Enum.map(state.slots, fn {key, slot} -> {{monday, key}, slot} end)
      end)
      |> Map.new()

    planned =
      for {_, %{recipe_id: id, skipped: false}} when is_integer(id) <- slots, do: id

    titles = scope |> Recipes.get_many(planned) |> Map.new(&{&1.id, &1.title})

    for date <- dates do
      slot = slots[{Tore.Streams.monday(date), Tore.Streams.slot_key(date)}]
      recipe_id = slot && !slot.skipped && slot.recipe_id
      %{date: date, recipe_id: recipe_id || nil, title: recipe_id && titles[recipe_id]}
    end
  end

  defp source_host(%{source_url: url}) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> nil
    end
  end

  defp source_host(_recipe), do: nil

  defp render_link(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between">
        <h2 class="font-semibold tracking-tight text-[var(--text)]" style="font-size: var(--t-h1);">
          {gettext("New recipe")}
        </h2>
        <button
          type="button"
          phx-click="close"
          aria-label={gettext("Close")}
          class="press size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--muted)] hover:bg-[color:var(--hairline)]"
        >
          <.icon name="ph-x" class="size-5" />
        </button>
      </div>
      <p class="mt-1 text-[color:var(--muted)]">
        {gettext("Paste a link to a recipe and Tore reads it in.")}
      </p>

      <form id="import-link" phx-submit="import_link" class="mt-5 space-y-3">
        <.field
          id="import"
          name="url"
          inputmode="url"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          value={@import_url}
          placeholder="https://"
          aria-label={gettext("Link to the recipe")}
          errors={List.wrap(@import_error)}
          send={gettext("Get recipe")}
          enterkeyhint="go"
          phx-mounted={JS.focus()}
        />

        <%!-- The way out: the link typed so far comes along as the recipe's source. --%>
        <button
          type="submit"
          name="write"
          value="true"
          formnovalidate
          class="press w-full py-2 text-center text-[color:var(--muted)] hover:text-[color:var(--text)]"
          style="font-size: var(--t-meta);"
        >
          {gettext("Write it yourself")}
        </button>
      </form>
      <button
        type="button"
        phx-click="compose"
        data-role="compose"
        class="press w-full py-2 text-center text-[color:var(--muted)] hover:text-[color:var(--text)]"
        style="font-size: var(--t-meta);"
      >
        {gettext("Put together from other recipes")}
      </button>
    </div>
    """
  end

  defp render_compose(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between">
        <h2 class="font-semibold tracking-tight text-[var(--text)]" style="font-size: var(--t-h1);">
          {gettext("Put together")}
        </h2>
        <button
          type="button"
          phx-click="close"
          aria-label={gettext("Close")}
          class="press size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--muted)] hover:bg-[color:var(--hairline)]"
        >
          <.icon name="ph-x" class="size-5" />
        </button>
      </div>
      <p class="mt-1 text-[color:var(--muted)]">
        {gettext("Pick the parts of a dinner. It follows them when they change.")}
      </p>

      <form id="compose" phx-submit="put_together" class="mt-5">
        <.field
          id="compose-title"
          name="title"
          autocomplete="off"
          placeholder={gettext("Name, e.g. Entrecote with béarnaise")}
          aria-label={gettext("Name")}
          phx-mounted={JS.focus()}
        />

        <div class="mt-4 flex items-center justify-between">
          <span class="text-[color:var(--muted)]">{gettext("Servings")}</span>
          <span class="flex items-center gap-2">
            <button
              type="button"
              phx-click="compose_servings"
              phx-value-by="-1"
              disabled={@compose.servings <= 1}
              aria-label={gettext("Fewer servings")}
              class="step-btn press"
            >
              <.icon name="ph-minus" class="size-4" />
            </button>
            <span class="num w-8 text-center font-semibold">{@compose.servings}</span>
            <button
              type="button"
              phx-click="compose_servings"
              phx-value-by="1"
              disabled={@compose.servings >= 24}
              aria-label={gettext("More servings")}
              class="step-btn press"
            >
              <.icon name="ph-plus" class="size-4" />
            </button>
          </span>
        </div>

        <ul class="menu-lines mt-4">
          <li :for={recipe <- @compose.options}>
            <label class="flex cursor-pointer items-center gap-3 py-3">
              <input
                type="checkbox"
                name="part_ids[]"
                value={recipe.id}
                class="size-5 shrink-0 accent-[color:var(--text)]"
              />
              <span class="min-w-0 flex-1 truncate text-[color:var(--text)]">{recipe.title}</span>
              <span class={["tag shrink-0", "tag-#{ToreWeb.Look.tint(recipe.recipe_type)}"]}>
                {type_label(recipe.recipe_type)}
              </span>
            </label>
          </li>
        </ul>

        <p
          :if={@compose.error}
          role="alert"
          class="settle mt-3 text-[color:var(--warn)]"
          style="font-size: var(--t-meta);"
        >
          {@compose.error}
        </p>
        <div class="sticky bottom-0 -mx-6 mt-4 bg-[var(--bg)] px-6 py-3">
          <.button
            type="submit"
            variant={:primary}
            full
            phx-disable-with={gettext("Putting it together…")}
          >
            {gettext("Put together")}
          </.button>
        </div>
      </form>
    </div>
    """
  end

  defp render_form(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-5">
        <h2 class="font-semibold tracking-tight text-[var(--text)]" style="font-size: var(--t-h1);">
          {if @selected, do: gettext("Edit recipe"), else: gettext("New recipe")}
        </h2>
        <button
          type="button"
          phx-click="close"
          class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--muted)] hover:bg-[color:var(--hairline)]"
        >
          <.icon name="ph-x" class="size-5" />
        </button>
      </div>

      <form phx-submit="save_recipe" class="space-y-5">
        <.field name="recipe[title]" label={gettext("Title")} value={@form[:title] || ""} required />

        <label class="block">
          <span class="block mb-1 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
            {gettext("Type")}
          </span>
          <select
            name="recipe[recipe_type]"
            class="w-full bg-transparent border-0 border-b border-[color:var(--border)] py-2 text-[var(--text)] focus:outline-none focus:ring-0 focus:border-[color:var(--accent)]"
            style="font-size: var(--t-body);"
          >
            <option
              :for={t <- [:meal, :baking, :component, :assembly]}
              value={t}
              selected={@form[:recipe_type] == to_string(t)}
            >
              {type_label(t)}
            </option>
          </select>
        </label>

        <div class="flex gap-4">
          <div class="flex-1">
            <.field
              name="recipe[prep_time_minutes]"
              label={gettext("Prep (min)")}
              type="number"
              value={to_string_or_empty(@form[:prep_time_minutes])}
            />
          </div>
          <div class="flex-1">
            <.field
              name="recipe[cook_time_minutes]"
              label={gettext("Cook (min)")}
              type="number"
              value={to_string_or_empty(@form[:cook_time_minutes])}
            />
          </div>
        </div>

        <.field
          name="recipe[base_servings]"
          label={gettext("Servings")}
          type="number"
          value={to_string_or_empty(@form[:base_servings])}
        />
        <.field
          name="recipe[tags]"
          label={gettext("Tags")}
          value={@form[:tags] || ""}
          placeholder="quick, batch, vegetarian"
        />
        <div>
          <span class="block mb-2 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
            {gettext("Ingredients")}
          </span>
          <div class="space-y-2">
            <div
              :for={{row, idx} <- Enum.with_index(@ingredient_rows)}
              class="flex items-start gap-2"
            >
              <.field
                id={"ingredient-#{idx}-name"}
                name={"ingredients[#{idx}][name]"}
                value={row.name}
                placeholder={gettext("Ingredient")}
                aria-label={gettext("Ingredient")}
                phx-change="sync_ingredient"
                phx-value-index={idx}
                phx-debounce="blur"
                class="min-w-0 flex-1"
              />
              <.field
                id={"ingredient-#{idx}-quantity"}
                name={"ingredients[#{idx}][quantity]"}
                value={row.quantity}
                placeholder={gettext("Qty")}
                aria-label={gettext("Qty")}
                phx-change="sync_ingredient"
                phx-value-index={idx}
                phx-debounce="blur"
                class="w-20 shrink-0"
              />
              <.field
                id={"ingredient-#{idx}-unit"}
                name={"ingredients[#{idx}][unit]"}
                value={row.unit}
                placeholder={gettext("Unit")}
                aria-label={gettext("Unit")}
                phx-change="sync_ingredient"
                phx-value-index={idx}
                phx-debounce="blur"
                class="w-24 shrink-0"
              />
              <button
                type="button"
                phx-click="remove_ingredient_row"
                phx-value-index={idx}
                aria-label={gettext("Remove ingredient")}
                class="size-11 shrink-0 inline-flex items-center justify-center rounded-[var(--r-pill)] text-[color:var(--muted)] hover:text-[color:var(--danger)] hover:bg-[var(--danger-soft)]"
              >
                <.icon name="ph-trash" class="size-4" />
              </button>
            </div>
          </div>
          <button
            type="button"
            phx-click="add_ingredient_row"
            class="mt-2 inline-flex items-center gap-1 text-[color:var(--accent)] hover:underline"
            style="font-size: var(--t-meta); font-weight: 500;"
          >
            <.icon name="ph-plus" class="size-4" /> {gettext("Add ingredient")}
          </button>
        </div>
        <.field
          name="recipe[source_url]"
          label={gettext("Source URL")}
          value={@form[:source_url] || ""}
        />

        <.field
          type="textarea"
          id="recipe-instructions"
          name="recipe[instructions]"
          label={gettext("Instructions")}
          rows="6"
          value={@form[:instructions]}
        />

        <div class="flex gap-2 pt-4 border-t border-[color:var(--border)]">
          <.button type="submit" variant={:primary}>{gettext("Save")}</.button>
          <.button variant={:ghost} phx-click="close">{gettext("Cancel")}</.button>
        </div>
      </form>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp reload(socket) do
    Recipes.list(socket.assigns.current_scope,
      tags: socket.assigns.filter_tags,
      type: socket.assigns.filter_type,
      max_minutes: socket.assigns.filter_max_min,
      sort: socket.assigns.sort
    )
  end

  defp reload_recipes(socket), do: assign(socket, recipes: reload(socket))

  # A gallery tile's quick action, done as its page opens: Cook now (through the sheet before
  # cooking when something's missing, as the page's button does) or the week to put it on.
  defp then_do(%{assigns: %{selected: %{} = recipe}} = socket, "cook") do
    if socket.assigns.home.missing == [],
      do:
        push_navigate(socket,
          to: ~p"/recipes/#{recipe.id}/cook?#{[servings: socket.assigns.servings]}"
        ),
      else: assign(socket, before_cooking: true)
  end

  defp then_do(%{assigns: %{selected: %{recipe_type: :meal}}} = socket, "week"),
    do: assign(socket, week: week_days(socket.assigns.current_scope), put: nil)

  defp then_do(socket, _), do: socket

  defp cook_label(%{recipe_type: :baking}), do: gettext("Bake now")
  defp cook_label(_recipe), do: gettext("Cook now")

  defp put_favorite(socket, id, favorite?) do
    star = fn r -> if r.id == id, do: %{r | favorite: favorite?}, else: r end
    selected = socket.assigns.selected

    assign(socket,
      recipes: Enum.map(socket.assigns.recipes, star),
      selected: selected && star.(selected)
    )
  end

  # pi reads the page and saves it; changes to it are asked in the recipe's own chat (Ask Tore).
  # The sheet closes once pi has the link; the outcome comes as a toast. If pi can't take it, the
  # sheet stays, with why in a toast.
  defp start_import(socket, url) do
    socket
    |> assign(import_error: nil)
    |> ToreWeb.PiReply.ask(
      "From the Recipes screen: save the recipe at #{url}. Read the page itself.",
      gettext("Reading the recipe")
    )
    |> then(&if &1.assigns.pi_working, do: assign(&1, importing: true, adding: false), else: &1)
  end

  defp blank_to_nil(text) when text in [nil, ""], do: nil
  defp blank_to_nil(text), do: text

  # The first http(s) link in what was shared.
  defp shared_link(nil), do: nil

  defp shared_link(text) do
    Enum.find_value(Regex.scan(~r{https?://\S+}, text), fn [candidate] -> web_link(candidate) end)
  end

  # An http(s) link with a host, or nil.
  defp web_link(text) do
    case URI.parse(text) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        text

      _ ->
        nil
    end
  end

  defp blank_form do
    %{
      title: "",
      recipe_type: "meal",
      prep_time_minutes: nil,
      cook_time_minutes: nil,
      base_servings: nil,
      tags: "",
      source_url: "",
      instructions: ""
    }
  end

  defp recipe_to_form(recipe) do
    %{
      title: recipe.title,
      recipe_type: to_string(recipe.recipe_type),
      prep_time_minutes: recipe.prep_time_minutes,
      cook_time_minutes: recipe.cook_time_minutes,
      base_servings: recipe.base_servings,
      tags: recipe.tags |> Enum.map(& &1.name) |> Enum.join(", "),
      source_url: recipe.source_url,
      instructions: recipe.instructions
    }
  end

  defp parse_recipe_params(params) do
    tag_names =
      (params["tags"] || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    ingredients =
      (params["ingredients"] || %{})
      |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
      |> Enum.map(fn {_, ing} ->
        %{
          name: String.trim(ing["name"] || ""),
          quantity: ing["quantity"],
          unit: ing["unit"]
        }
      end)
      |> Enum.reject(fn %{name: name} -> name == "" end)

    %{
      title: params["title"],
      recipe_type: String.to_existing_atom(params["recipe_type"] || "meal"),
      prep_time_minutes: parse_int(params["prep_time_minutes"]),
      cook_time_minutes: parse_int(params["cook_time_minutes"]),
      base_servings: parse_int(params["base_servings"]),
      source_url: params["source_url"],
      instructions: params["instructions"],
      tags: tag_names,
      ingredients: ingredients
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_type("all"), do: :all
  defp parse_type(t), do: String.to_existing_atom(t)

  defp parse_time("any"), do: :any

  defp parse_time(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> :any
    end
  end

  defp parse_sort(s), do: String.to_existing_atom(s)

  defp grouped_steps(recipe) do
    case recipe.steps do
      nil ->
        []

      json ->
        Jason.decode!(json)
        |> Enum.sort_by(& &1["order"])
        |> Enum.chunk_by(& &1["phase"])
        |> Enum.map(fn steps -> {hd(steps)["phase"], steps} end)
    end
  end

  # The collections a recipe lives in. Only dinners are planned; the rest are found and started.
  defp type_label(type) do
    case to_string(type) do
      "all" -> gettext("All")
      "meal" -> gettext("Dinner")
      "baking" -> gettext("Baking")
      "component" -> gettext("Sauces & sides")
      "assembly" -> gettext("Assemblies")
    end
  end

  # The recipes by collection, in the collections' order; only the chosen one when one is.
  defp groups(recipes, filter) do
    by_type = Enum.group_by(recipes, & &1.recipe_type)

    for type <- ToreWeb.Look.collections(),
        filter in [:all, type],
        Map.has_key?(by_type, type),
        do: {type, by_type[type]}
  end

  defp recipes_view(%{preferences: %{"recipes_view" => "list"}}), do: :list
  defp recipes_view(_user), do: :gallery

  defp type_icon(type) when type in [:all, "all"], do: nil
  defp type_icon(type), do: ToreWeb.Look.collection_icon(type)

  # "35 min, vegetarian, quick": time first, then up to two tags.
  defp recipe_meta(recipe) do
    time = if total_minutes(recipe) > 0, do: [duration(total_minutes(recipe))], else: []
    Enum.join(time ++ (recipe.tags |> Enum.take(2) |> Enum.map(& &1.name)), ", ")
  end

  defp total_minutes(recipe),
    do: (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)

  # 45 min, 2 h, 3 h 30 min
  defp duration(minutes), do: ToreWeb.Dates.duration(minutes)

  defp error_message(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  defp sort_label(:recently_added), do: gettext("Recent")
  defp sort_label(:last_used), do: gettext("Last used")
  defp sort_label(:alphabetical), do: gettext("A–Z")

  defp recipe_count_label([]), do: nil
  defp recipe_count_label([_]), do: gettext("1 recipe")
  defp recipe_count_label(list), do: gettext("%{n} recipes", n: length(list))

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(v), do: to_string(v)

  defp common_tags, do: ["quick", "batch", "base-recipe", "vegetarian", "swedish", "asian"]

  defp tag_label("quick"), do: gettext("Quick")
  defp tag_label("batch"), do: gettext("Batch")
  defp tag_label("base-recipe"), do: gettext("Base recipe")
  defp tag_label("vegetarian"), do: gettext("Vegetarian")
  defp tag_label("swedish"), do: gettext("Swedish")
  defp tag_label("asian"), do: gettext("Asian")
  defp tag_label(tag), do: String.capitalize(tag)
end
