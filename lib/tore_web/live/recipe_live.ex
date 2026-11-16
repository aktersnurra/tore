defmodule ToreWeb.RecipeLive do
  use ToreWeb, :live_view
  alias Tore.Recipes

  @sorts [:recently_added, :last_used, :alphabetical]
  @types [:all, :meal, :baking, :component, :assembly]
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
       importing: false,
       import_error: nil,
       import_url: "",
       sorts: @sorts,
       types: @types,
       time_filters: @time_filters,
       show_more_filters: false,
       ingredient_rows: [],
       show_recipe_menu: false,
       show_substitution: false,
       substitution: nil,
       substitution_loading: false,
       servings: nil,
       week: nil,
       put: nil
     )}
  end

  # A recipe opens at its own address, so Back closes it and a link can open one.
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, select(socket, String.to_integer(id))}
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
        importing: false,
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

  # The sheet stays open when a shared link's address is cleaned up.
  def handle_params(_params, _uri, %{assigns: %{adding: true}} = socket), do: {:noreply, socket}

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

  def handle_event("toggle_more_filters", _, socket) do
    {:noreply, assign(socket, show_more_filters: !socket.assigns.show_more_filters)}
  end

  # A new recipe starts from a link; writing it in by hand is the way out.
  def handle_event("new_recipe", _, socket) do
    {:noreply,
     assign(socket,
       adding: true,
       importing: false,
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
       importing: false,
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
          {:ok, _recipe} ->
            {:noreply, socket |> assign(form: nil, error: nil) |> reload_recipes()}

          {:error, changeset} ->
            {:noreply, assign(socket, error: error_message(changeset))}
        end

      recipe ->
        case Recipes.update(socket.assigns.current_scope, recipe, attrs) do
          {:ok, _recipe} ->
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

  def handle_event("close", _, socket) do
    if socket.assigns.selected,
      do: {:noreply, push_patch(socket, to: ~p"/recipes")},
      else: {:noreply, closed(socket)}
  end

  def handle_event("servings", %{"by" => by}, socket) do
    servings = (socket.assigns.servings + String.to_integer(by)) |> max(1) |> min(24)
    {:noreply, assign(socket, servings: servings)}
  end

  def handle_event("toggle_week", _, socket) do
    week = if socket.assigns.week, do: nil, else: week_days(socket.assigns.current_scope)
    {:noreply, assign(socket, week: week, put: nil)}
  end

  # Puts the recipe on a day for the servings shown; what the day had is kept for Undo.
  def handle_event("put_on", %{"date" => iso}, socket) do
    %{current_scope: scope, selected: recipe, servings: servings} = socket.assigns
    date = Date.from_iso8601!(iso)
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

  def handle_event("undo_put", _, %{assigns: %{put: %{} = put}} = socket) do
    :ok = Tore.Planning.restore_slots(socket.assigns.current_scope, put.plan_id, put.before)
    {:noreply, assign(socket, week: week_days(socket.assigns.current_scope), put: nil)}
  end

  def handle_event("toggle_recipe_menu", _, socket) do
    {:noreply, assign(socket, show_recipe_menu: !socket.assigns.show_recipe_menu)}
  end

  # The picture arrives on its own when it's made (`{:recipe_image, id, key}`).
  def handle_event("make_image", _params, socket) do
    Recipes.start_image(socket.assigns.current_scope, socket.assigns.selected.id)

    {:noreply,
     socket
     |> assign(show_recipe_menu: false)
     |> put_flash(:info, gettext("Making a picture. It shows up here when it's ready."))}
  end

  def handle_event("toggle_substitution", _params, socket) do
    {:noreply,
     assign(socket, show_substitution: !socket.assigns.show_substitution, substitution: nil)}
  end

  def handle_event("get_substitution", %{"missing" => missing}, socket) when missing != "" do
    recipe_title = (socket.assigns.selected && socket.assigns.selected.title) || "current recipe"
    scope = socket.assigns.current_scope

    ToreWeb.Background.run(
      fn -> Recipes.suggest_substitution(scope, missing, recipe_title) end,
      &{:substitution, &1}
    )

    {:noreply, assign(socket, substitution_loading: true)}
  end

  def handle_event("get_substitution", %{"missing" => ""}, socket) do
    {:noreply, socket}
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

  def handle_info({:recipe_image, id, key}, socket) do
    recipes =
      Enum.map(socket.assigns.recipes, fn recipe ->
        if recipe.id == id, do: %{recipe | image_path: key}, else: recipe
      end)

    selected =
      case socket.assigns.selected do
        %{id: ^id} = selected -> %{selected | image_path: key}
        other -> other
      end

    {:noreply, assign(socket, recipes: recipes, selected: selected)}
  end

  # The answer comes from the model, so it's asked for off the screen's own process.
  def handle_info({:substitution, result}, socket) do
    substitution =
      case result do
        {:ok, substitution} ->
          substitution

        {:error, _} ->
          %{
            suggestion: gettext("Couldn't find a substitution — try a web search."),
            updated_steps: nil
          }
      end

    {:noreply, assign(socket, substitution: substitution, substitution_loading: false)}
  end

  # An import still running when the sheet closes lands in the list without opening.
  def handle_info({:recipe_imported, result}, socket) do
    socket = socket |> assign(importing: false) |> reload_recipes()

    case {socket.assigns.adding, result} do
      {false, _} ->
        {:noreply, socket}

      {true, %{run_stream_id: run_id}} ->
        {:steps, steps} = Tore.Harness.Runs.get(socket.assigns.current_scope, run_id).undo

        recipe_id =
          Enum.find_value(steps, fn
            {:delete_recipe, id} -> id
            _ -> nil
          end)

        {:noreply,
         socket |> assign(adding: false) |> push_patch(to: ~p"/recipes?#{[id: recipe_id]}")}

      {true, %{text: text}} ->
        {:noreply, assign(socket, import_error: text)}

      {true, {:error, :crashed}} ->
        {:noreply, assign(socket, import_error: gettext("Couldn't import that URL."))}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  defp select(socket, id) do
    recipe = Recipes.get!(socket.assigns.current_scope, id)

    assign(socket,
      selected: recipe,
      servings: recipe.base_servings || 4,
      week: nil,
      put: nil,
      opened: id,
      form: nil,
      error: nil,
      show_recipe_menu: false,
      show_substitution: false,
      substitution: nil,
      substitution_loading: false
    )
  end

  defp closed(socket) do
    assign(socket,
      week: nil,
      put: nil,
      selected: nil,
      form: nil,
      adding: false,
      importing: false,
      import_error: nil,
      error: nil,
      show_recipe_menu: false,
      show_substitution: false,
      substitution: nil,
      substitution_loading: false
    )
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      current_user={@current_user}
    >
      <.page max_width={:md}>
        <div class="mb-6">
          <header class="flex items-start justify-between gap-4 pt-6">
            <div>
              <h1 class="t-display">{gettext("Recipes")}</h1>
              <p class="num mt-1.5 text-[color:var(--muted)]" style="font-size: 15px;">
                {recipe_count_label(@recipes)}
              </p>
            </div>
            <button
              type="button"
              phx-click="new_recipe"
              aria-label={gettext("New recipe")}
              class="press flex size-11 shrink-0 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] hover:bg-[var(--border)]"
            >
              <.icon name="hero-plus" class="size-5" />
            </button>
          </header>

          <div class="mt-6 space-y-4">
            <%!-- Search --%>
            <form phx-change="search" class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="size-5 absolute left-4 top-1/2 -translate-y-1/2 text-[color:var(--muted)]"
              />
              <input
                type="text"
                name="query"
                value={@search}
                placeholder={gettext("Search recipes, ingredients, or meals…")}
                class="w-full h-12 pl-11 pr-4 bg-[var(--sunken)] rounded-full text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-[color:var(--accent)]"
                style="font-size: var(--t-body);"
              />
            </form>

            <%!-- Type filters + More filters toggle --%>
            <div class="flex items-center justify-between gap-2">
              <%!-- Collections, as views of one library: the open one is underlined. --%>
              <div class="scroll-quiet -ml-4 flex gap-1 overflow-x-auto pl-4" role="tablist">
                <button
                  :for={type <- @types}
                  phx-click="filter_type"
                  phx-value-type={type}
                  role="tab"
                  aria-selected={to_string(@filter_type == type)}
                  data-collection={type}
                  class={[
                    "view-tab press inline-flex h-9 shrink-0 items-center gap-1.5 rounded-[var(--r-sm)] px-2.5 whitespace-nowrap",
                    @filter_type == type && "is-open text-[color:var(--text)]",
                    @filter_type != type && "text-[color:var(--muted)]"
                  ]}
                  style="font-size: 14px; font-weight: 600;"
                >
                  <span :if={type_icon(type)} aria-hidden="true">{type_icon(type)}</span>
                  {type_label(type)}
                </button>
              </div>
              <button
                type="button"
                phx-click="toggle_more_filters"
                aria-label={gettext("More filters")}
                aria-expanded={to_string(@show_more_filters)}
                class={[
                  "press shrink-0 inline-flex items-center justify-center size-9 rounded-full",
                  @show_more_filters && "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)]",
                  !@show_more_filters &&
                    "text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[var(--sunken)]"
                ]}
              >
                <.icon name="hero-adjustments-horizontal" class="size-5" />
              </button>
            </div>

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

        <%!-- A cookbook's contents page: the picture is the entry, with its name on it --%>
        <ul :if={@recipes != []} class="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <li
            :for={{recipe, i} <- Enum.with_index(@recipes)}
            class="reveal"
            style={"--i: #{min(i, 8)}"}
          >
            <.link
              patch={~p"/recipes?#{[id: recipe.id]}"}
              data-dish={recipe.id}
              class={[
                "press-soft press group relative block aspect-[3/4] w-full overflow-hidden rounded-[var(--r-xl)] text-left",
                !recipe.image_path && "bg-[var(--sunken)]"
              ]}
            >
              <img
                :if={recipe.image_path}
                src={~p"/images/recipes/#{recipe.id}"}
                alt=""
                loading="lazy"
                class="absolute inset-0 size-full object-cover transition-transform duration-500 ease-[var(--ease-out)] group-hover:scale-[1.04]"
                style={
                  if @selected == nil and @opened == recipe.id,
                    do: "view-transition-name: dish-#{recipe.id}"
                }
              />
              <span :if={recipe.image_path} class="photo-shade absolute inset-0" aria-hidden="true">
              </span>
              <span class="absolute inset-x-0 bottom-0 p-3.5">
                <span
                  class={[
                    "line-clamp-3 block font-bold",
                    recipe.image_path && "text-white",
                    !recipe.image_path && "text-[color:var(--text)]"
                  ]}
                  style="font-size: 17px; line-height: 1.15; letter-spacing: -0.015em;"
                >
                  {recipe.title}
                </span>
                <span
                  :if={recipe_meta(recipe) != ""}
                  class={[
                    "num mt-1 block truncate",
                    recipe.image_path && "text-white/75",
                    !recipe.image_path && "text-[color:var(--muted)]"
                  ]}
                  style="font-size: var(--t-micro);"
                >
                  {recipe_meta(recipe)}
                </span>
              </span>
            </.link>
          </li>
        </ul>

        <div
          :if={@selected != nil or @form != nil or @adding}
          class="fixed inset-0 z-50 flex items-end justify-center md:items-center md:p-4"
          phx-window-keydown="close"
          phx-key="Escape"
        >
          <div class="scrim absolute inset-0 hidden bg-black/50 md:block" phx-click="close"></div>
          <div class={[
            "scroll-quiet relative h-full w-full overflow-y-auto bg-[var(--bg)] md:h-auto md:max-h-[90vh] md:max-w-lg md:rounded-[28px] md:shadow-[var(--shadow-pop)]",
            (@form || @adding) && "sheet"
          ]}>
            <%= cond do %>
              <% @form -> %>
                <div class="p-6">{render_form(assigns)}</div>
              <% @adding -> %>
                <div class="p-6">{render_link(assigns)}</div>
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

  defp render_detail(assigns) do
    ~H"""
    <article>
      <%!-- The dish, with its name on the dark foot of the photograph --%>
      <div class={[
        "relative w-full overflow-hidden",
        @selected.image_path && "h-[58svh] min-h-[360px] max-h-[560px]",
        !@selected.image_path && "h-28"
      ]}>
        <img
          :if={@selected.image_path}
          src={~p"/images/recipes/#{@selected.id}"}
          alt=""
          class="absolute inset-0 size-full object-cover"
          style={"view-transition-name: dish-#{@selected.id}"}
        />
        <div
          :if={@selected.image_path}
          class="photo-foot absolute inset-x-0 bottom-0 h-3/5"
          aria-hidden="true"
        >
        </div>

        <div class="absolute inset-x-0 top-0 flex items-center justify-between p-4 pt-[calc(env(safe-area-inset-top)+1rem)]">
          <.link
            patch={~p"/recipes"}
            aria-label={gettext("Back")}
            data-role="recipe-close"
            class="on-photo press"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <div class="relative" id="recipe-actions">
            <button
              type="button"
              phx-click="toggle_recipe_menu"
              aria-label={gettext("More")}
              aria-expanded={to_string(@show_recipe_menu)}
              class="on-photo press"
            >
              <.icon name="hero-ellipsis-horizontal" class="size-5" />
            </button>
            <div
              :if={@show_recipe_menu}
              phx-click-away="toggle_recipe_menu"
              class="rise-in absolute right-0 top-12 z-10 w-48 origin-top-right overflow-hidden rounded-[var(--r-lg)] bg-[var(--sunken)] py-1 shadow-[var(--shadow-pop)]"
            >
              <button
                type="button"
                phx-click="edit_recipe"
                class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--text)] hover:bg-[var(--border)]"
                style="font-size: 15px;"
              >
                <.icon name="hero-pencil" class="size-4 text-[color:var(--muted)]" />
                {gettext("Edit")}
              </button>
              <button
                type="button"
                phx-click="make_image"
                class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--text)] hover:bg-[var(--border)]"
                style="font-size: 15px;"
              >
                <.icon name="hero-photo" class="size-4 text-[color:var(--muted)]" />
                {gettext("New picture")}
              </button>
              <button
                type="button"
                phx-click="delete_recipe"
                class="flex w-full items-center gap-3 px-4 py-3 text-left text-[color:var(--danger)] hover:bg-[var(--border)]"
                style="font-size: 15px;"
              >
                <.icon name="hero-trash" class="size-4" />
                {gettext("Delete")}
              </button>
            </div>
          </div>
        </div>

        <div :if={@selected.image_path} class="absolute inset-x-0 bottom-0 px-5 pb-1">
          <h1 class="reveal t-display" style="--i: 1">{@selected.title}</h1>
        </div>
      </div>

      <div class="px-5 pb-28">
        <div :if={!@selected.image_path}>
          <h1 class="t-display mt-2">{@selected.title}</h1>
        </div>

        <%!-- The page's properties: quiet rows, a label and its value. Servings is a stepper. --%>
        <dl class="props reveal mt-4" style="--i: 2">
          <div>
            <dt><.icon name="hero-squares-2x2" /> {gettext("Collection")}</dt>
            <dd data-role="collection">
              <span aria-hidden="true">{type_icon(@selected.recipe_type)}</span>
              {type_label(@selected.recipe_type)}
            </dd>
          </div>
          <div :if={total_time(@selected) != "—"}>
            <dt><.icon name="hero-clock" /> {gettext("Time")}</dt>
            <dd class="num">
              {total_time(@selected)}
              <span :if={@selected.prep_time_minutes} class="text-[color:var(--muted)]">
                · {gettext("%{minutes} min hands-on", minutes: @selected.prep_time_minutes)}
              </span>
            </dd>
          </div>
          <div>
            <dt><.icon name="hero-users" /> {gettext("Servings")}</dt>
            <dd class="flex items-center gap-1">
              <button
                type="button"
                phx-click="servings"
                phx-value-by="-1"
                disabled={@servings <= 1}
                aria-label={gettext("Fewer servings")}
                class="step-btn press"
              >
                <.icon name="hero-minus" class="size-4" />
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
                <.icon name="hero-plus" class="size-4" />
              </button>
            </dd>
          </div>
          <div :if={source_host(@selected)}>
            <dt><.icon name="hero-link" /> {gettext("Source")}</dt>
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
          <div :if={@selected.last_used_at}>
            <dt><.icon name="hero-calendar" /> {gettext("Last made")}</dt>
            <dd>{ToreWeb.Dates.day(DateTime.to_date(@selected.last_used_at))}</dd>
          </div>
        </dl>

        <%!-- What you can do with it, before anything to read --%>
        <div class="reveal scroll-quiet -mx-5 mt-5 flex gap-2 overflow-x-auto px-5" style="--i: 3">
          <.link
            navigate={~p"/recipes/#{@selected.id}/cook?#{[servings: @servings]}"}
            data-role="start-cooking"
            class="pill pill-lamp press"
          >
            <.icon name="hero-fire-solid" />
            {if @selected.recipe_type == :baking, do: gettext("Bake now"), else: gettext("Cook now")}
          </.link>
          <button
            :if={@selected.recipe_type == :meal}
            type="button"
            phx-click="toggle_week"
            aria-expanded={to_string(@week != nil)}
            data-role="put-on-week"
            class="pill press"
          >
            <.icon name="hero-calendar-days" /> {gettext("Put on the week")}
          </button>
          <button type="button" phx-click="toggle_substitution" class="pill press">
            <.icon name="hero-arrows-right-left" /> {gettext("Missing something?")}
          </button>
        </div>

        <%!-- Which day: the next seven, each with what it has now. --%>
        <div :if={@week} id="week-days" class="reveal mt-4" data-role="week-days">
          <p class="t-eyebrow mb-2">{gettext("Which day?")}</p>
          <ul class="menu-lines">
            <li :for={day <- @week} class="flex items-center gap-3 py-1">
              <button
                type="button"
                phx-click="put_on"
                phx-value-date={Date.to_iso8601(day.date)}
                disabled={day.recipe_id == @selected.id}
                data-day={Date.to_iso8601(day.date)}
                class="row-hover press-soft flex min-h-12 flex-1 items-center justify-between gap-3 rounded-[var(--r-md)] px-2 text-left"
              >
                <span class="font-semibold text-[color:var(--text)]">
                  {ToreWeb.Dates.weekday(day.date)}
                  <span class="num font-normal text-[color:var(--muted)]">{day.date.day}</span>
                </span>
                <span class={[
                  "truncate",
                  day.recipe_id == @selected.id && "text-[color:var(--done)] font-semibold",
                  day.recipe_id != @selected.id && "text-[color:var(--muted)]"
                ]}>
                  {day.title || gettext("Free")}
                </span>
              </button>
              <button
                :if={@put && @put.date == day.date}
                type="button"
                phx-click="undo_put"
                class="settle press shrink-0 px-2 font-semibold text-[color:var(--accent-ink)]"
              >
                {gettext("Undo")}
              </button>
            </li>
          </ul>
        </div>

        <div :if={@show_substitution} class="reveal mt-4">
          <form phx-submit="get_substitution" class="flex gap-2">
            <input
              type="text"
              name="missing"
              placeholder={gettext("e.g. crème fraîche")}
              autocomplete="off"
              autofocus
              class="h-11 min-w-0 flex-1 rounded-full bg-[var(--sunken)] px-4 text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus-visible:outline-2 focus-visible:outline-[color:var(--accent)]"
              style="font-size: 16px;"
            />
            <button type="submit" class="pill press" phx-disable-with={gettext("Asking…")}>
              {gettext("Ask")}
            </button>
          </form>
          <p
            :if={@substitution_loading}
            role="status"
            class="mt-3 flex items-center gap-2 text-[color:var(--muted)]"
            style="font-size: 14px;"
          >
            <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
            {gettext("Finding a swap…")}
          </p>
          <div :if={@substitution} class="reveal mt-3 rounded-[var(--r-lg)] bg-[var(--surface)] p-4">
            <p class="text-[color:var(--text)]" style="font-size: 15px; line-height: 1.5;">
              {@substitution.suggestion}
            </p>
            <p
              :if={@substitution.updated_steps}
              class="mt-2 text-[color:var(--muted)]"
              style="font-size: 14px; line-height: 1.5;"
            >
              {@substitution.updated_steps}
            </p>
          </div>
        </div>

        <p
          :if={@selected.description not in [nil, ""]}
          class="reveal mt-5 text-[color:var(--muted)]"
          style="--i: 4; font-size: 15px; line-height: 1.55;"
        >
          {@selected.description}
        </p>

        <%!-- Ingredients for the servings above: the name on the left, the amount on the right --%>
        <section :if={@selected.recipe_ingredients != []} class="reveal mt-9" style="--i: 4">
          <h2 class="t-head mb-3">{gettext("Ingredients")}</h2>
          <ul class="menu-lines">
            <li
              :for={ri <- @selected.recipe_ingredients}
              class="flex items-baseline justify-between gap-4 py-3.5"
            >
              <span class="text-[color:var(--text)]" style="font-size: 16px;">
                {ri.ingredient.name}
              </span>
              <span
                id={"amount-#{ri.id}-#{@servings}"}
                data-role="amount"
                class="settle num shrink-0 text-[color:var(--muted)]"
                style="font-size: 15px;"
              >
                {amount(ri, @selected.base_servings, @servings)}
              </span>
            </li>
          </ul>
        </section>

        <%!-- The method: a real sequence, so it is numbered --%>
        <section :if={@selected.steps || @selected.instructions} class="mt-9">
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
    </article>
    """
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
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
      <p class="mt-1 text-[color:var(--muted)]">
        {gettext("Paste a link to a recipe and Tore reads it in.")}
      </p>

      <form id="import-link" phx-submit="import_link" class="mt-5 space-y-3">
        <input
          type="text"
          name="url"
          inputmode="url"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          value={@import_url}
          placeholder="https://"
          aria-label={gettext("Link to the recipe")}
          aria-invalid={@import_error && "true"}
          aria-describedby={@import_error && "import-error"}
          readonly={@importing}
          phx-mounted={JS.focus()}
          class={[
            "w-full rounded-full border bg-[var(--surface)] px-5 py-3 text-[var(--text)] transition-colors duration-[var(--dur-fast)]",
            @import_error && "border-[color:var(--warn)]",
            !@import_error && "border-[color:var(--hairline)]"
          ]}
        />
        <p
          :if={@import_error}
          id="import-error"
          role="alert"
          class="settle text-[color:var(--warn)]"
          style="font-size: var(--t-meta);"
        >
          {@import_error}
        </p>
        <.button type="submit" variant={:primary} full disabled={@importing}>
          <span :if={@importing} class="inline-flex items-center gap-2" role="status">
            <.icon name="hero-arrow-path" class="size-4 animate-spin" />
            {gettext("Reading the recipe")}
          </span>
          <span :if={!@importing}>{gettext("Get recipe")}</span>
        </.button>

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
          <.icon name="hero-x-mark" class="size-5" />
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
              {type_icon(t)} {type_label(t)}
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
              class="flex items-center gap-2"
            >
              <input
                type="text"
                name={"ingredients[#{idx}][name]"}
                value={row.name}
                placeholder={gettext("Ingredient")}
                phx-change="sync_ingredient"
                phx-value-index={idx}
                phx-debounce="blur"
                class="flex-1 h-10 px-3 bg-[var(--surface)] rounded-[var(--r-md)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
                style="font-size: var(--t-body);"
              />
              <input
                type="text"
                name={"ingredients[#{idx}][quantity]"}
                value={row.quantity}
                placeholder={gettext("Qty")}
                phx-change="sync_ingredient"
                phx-value-index={idx}
                phx-debounce="blur"
                class="w-20 h-10 px-3 bg-[var(--surface)] rounded-[var(--r-md)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
                style="font-size: var(--t-body);"
              />
              <input
                type="text"
                name={"ingredients[#{idx}][unit]"}
                value={row.unit}
                placeholder={gettext("Unit")}
                phx-change="sync_ingredient"
                phx-value-index={idx}
                phx-debounce="blur"
                class="w-24 h-10 px-3 bg-[var(--surface)] rounded-[var(--r-md)] border border-[color:var(--border)] text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none focus:border-[color:var(--accent)]"
                style="font-size: var(--t-body);"
              />
              <button
                type="button"
                phx-click="remove_ingredient_row"
                phx-value-index={idx}
                class="size-9 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--subtle)] hover:text-[color:var(--danger)] hover:bg-[color:var(--hairline)]"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </div>
          <button
            type="button"
            phx-click="add_ingredient_row"
            class="mt-2 inline-flex items-center gap-1 text-[color:var(--accent)] hover:underline"
            style="font-size: var(--t-meta); font-weight: 500;"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("Add ingredient")}
          </button>
        </div>
        <.field
          name="recipe[source_url]"
          label={gettext("Source URL")}
          value={@form[:source_url] || ""}
        />

        <label class="block">
          <span class="block mb-1 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
            {gettext("Instructions")}
          </span>
          <textarea
            name="recipe[instructions]"
            rows="6"
            class="w-full bg-transparent border border-[color:var(--border)] rounded-[var(--r-sm)] px-3 py-2 text-[var(--text)] focus:outline-none focus:ring-0 focus:border-[color:var(--accent)]"
            style="font-size: var(--t-body);"
          >{@form[:instructions]}</textarea>
        </label>

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

  defp start_import(socket, url) do
    ctx = %{scope: socket.assigns.current_scope}

    ToreWeb.Background.run(
      fn -> Tore.Capture.Dispatch.import_recipe_from_url(url, ctx) end,
      &{:recipe_imported, &1}
    )

    assign(socket, importing: true, import_error: nil)
  end

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

  defp type_icon(type) do
    case to_string(type) do
      "all" -> nil
      "meal" -> "🍲"
      "baking" -> "🥐"
      "component" -> "🫙"
      "assembly" -> "🥪"
    end
  end

  # "35 min, vegetarian, quick": time first, then up to two tags.
  defp recipe_meta(recipe) do
    time = if total_time(recipe) == "—", do: [], else: [total_time(recipe)]
    Enum.join(time ++ (recipe.tags |> Enum.take(2) |> Enum.map(& &1.name)), ", ")
  end

  defp total_time(recipe) do
    prep = recipe.prep_time_minutes || 0
    cook = recipe.cook_time_minutes || 0
    total = prep + cook
    if total > 0, do: "#{total} min", else: "—"
  end

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
