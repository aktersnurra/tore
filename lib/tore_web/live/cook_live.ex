defmodule ToreWeb.CookLive do
  @moduledoc """
  Cook mode: a recipe as cards to step through at the stove. The first card is what to take
  out; then one card per step, with what it uses and how long it takes. `?step=` holds the
  position, so a reload or the back button lands on the same card.
  """

  use ToreWeb, :live_view

  alias Tore.Recipes
  alias ToreWeb.StepCards

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    recipe = Recipes.get!(scope, String.to_integer(id))

    # A recipe that only has running text gets its steps written by the model the first time.
    # Only once the page is live: mount also runs for the first plain render.
    if connected?(socket) do
      ToreWeb.Background.run(fn -> Recipes.cook_steps(scope, recipe) end, &{:cook_steps, &1})
    end

    {:ok,
     assign(socket,
       recipe: recipe,
       cards: nil,
       failed: false,
       overview: false,
       close_to: ToreWeb.SafeReturn.path(params["from"], ~p"/recipes")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :index, step_index(params["step"], socket.assigns.cards))}
  end

  @impl true
  def handle_info({:cook_steps, {:ok, steps}}, socket) do
    cards = [
      needs_card(socket.assigns.recipe) | Enum.map(steps, &card(&1, socket.assigns.recipe))
    ]

    {:noreply, assign(socket, cards: cards, index: min(socket.assigns.index, length(cards) - 1))}
  end

  def handle_info({:cook_steps, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, failed: true)}

  @impl true
  def handle_event("step", %{"to" => to}, socket),
    do: {:noreply, go(socket, String.to_integer(to))}

  def handle_event("step_key", %{"key" => key}, socket) do
    %{index: index, cards: cards} = socket.assigns
    {:noreply, go(socket, StepCards.key_target(key, index, length(cards || [nil])))}
  end

  def handle_event("toggle_overview", _params, socket),
    do: {:noreply, update(socket, :overview, &(not &1))}

  defp go(socket, to) do
    %{recipe: recipe, close_to: close_to} = socket.assigns

    socket
    |> assign(overview: false)
    |> push_patch(to: ~p"/recipes/#{recipe.id}/cook?#{[step: to + 1, from: close_to]}")
  end

  # `?step=` counts from 1, like the counter on the screen.
  defp step_index(step, cards) do
    last = if cards, do: length(cards) - 1, else: 10_000

    case Integer.parse(step || "1") do
      {n, ""} when n >= 1 -> min(n - 1, last)
      _ -> 0
    end
  end

  defp needs_card(recipe) do
    %{
      text: gettext("Take this out"),
      needs: Enum.map(recipe.recipe_ingredients, &ingredient_line/1)
    }
  end

  defp card(step, recipe) do
    %{
      label: step["phase"] && String.capitalize(step["phase"]),
      text: step["action"],
      minutes: step["duration_minutes"],
      needs: Enum.map(step["ingredients"] || [], &need_line(&1, recipe))
    }
  end

  # A step names its ingredients; the amount comes from the recipe's own list when it's there.
  defp need_line(name, recipe) do
    case Enum.find(recipe.recipe_ingredients, &same_name?(&1.ingredient.name, name)) do
      nil -> name
      ingredient -> ingredient_line(ingredient)
    end
  end

  defp same_name?(a, b), do: String.downcase(a) == String.downcase(b)

  defp ingredient_line(%{quantity: nil} = ri), do: ri.ingredient.name

  defp ingredient_line(ri) do
    amount = ri.quantity |> Decimal.normalize() |> Decimal.to_string(:normal)
    Enum.join([amount, ri.unit, ri.ingredient.name] |> Enum.reject(&(&1 in [nil, ""])), " ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <StepCards.deck
        :if={@cards}
        id="cook-mode"
        title={@recipe.title}
        cards={@cards}
        index={@index}
        overview={@overview}
        close_to={@close_to}
      />

      <div
        :if={!@cards}
        id="cook-mode-waiting"
        class="fixed inset-0 z-[60] flex flex-col justify-center bg-[var(--bg)] px-5"
      >
        <div class="mx-auto w-full max-w-2xl">
          <p class="t-eyebrow">{@recipe.title}</p>
          <p class="t-title mt-3 flex items-center gap-3" role="status">
            <.icon
              :if={!@failed}
              name="hero-arrow-path"
              class="size-6 shrink-0 text-[color:var(--muted)] motion-safe:animate-spin"
            />
            {if @failed,
              do: gettext("Couldn't write the steps"),
              else: gettext("Writing the steps…")}
          </p>
          <p :if={@failed} class="mt-3 text-[color:var(--muted)]" style="font-size: var(--t-body);">
            {gettext(
              "The recipe is unchanged. Open it to read it as it is, or try again in a moment."
            )}
          </p>
          <.link
            navigate={@close_to}
            class="pill pill-lg press mt-8"
          >
            {gettext("Back")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
