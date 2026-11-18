defmodule ToreWeb.DishChoices do
  @moduledoc """
  A few dishes to choose between, each with its photo and the reason it's offered: what Today
  shows for "Something else" and what Plan suggests for a day. Tapping one sends `event` with
  the recipe's id; the screen decides what choosing means.
  """

  use Phoenix.Component
  use Gettext, backend: ToreWeb.Gettext

  import ToreWeb.CoreComponents, only: [icon: 1]

  attr :choices, :list, required: true, doc: "[%{recipe: recipe, reasons: [String.t()]}]"
  attr :event, :string, required: true
  attr :prices, :map, default: %{}, doc: "recipe id => a price line such as \"−35 kr\""
  attr :selected_id, :any, default: nil
  attr :loading, :boolean, default: false

  def dish_choices(assigns) do
    ~H"""
    <div :if={@loading and @choices == []} class="space-y-2" role="status">
      <span class="sr-only">{gettext("Finding dishes…")}</span>
      <div :for={_ <- 1..3} class="flex items-center gap-4 p-2">
        <div class="shimmer size-20 shrink-0 rounded-[var(--r-lg)]"></div>
        <div class="flex-1 space-y-2">
          <div class="shimmer h-4 w-2/3 rounded"></div>
          <div class="shimmer h-3 w-1/2 rounded"></div>
        </div>
      </div>
    </div>
    <ul :if={@choices != []} class="space-y-1" data-role="dish-choices">
      <li :for={{choice, i} <- Enum.with_index(@choices)} class="reveal" style={"--i: #{i}"}>
        <button
          type="button"
          phx-click={@event}
          phx-value-id={choice.recipe.id}
          data-choice={choice.recipe.id}
          aria-pressed={to_string(@selected_id == choice.recipe.id)}
          class={[
            "row-hover press-soft flex w-full items-center gap-4 rounded-[var(--r-lg)] p-2 text-left",
            @selected_id == choice.recipe.id && "bg-[var(--sunken)]"
          ]}
        >
          <span class="relative size-20 shrink-0 overflow-hidden rounded-[var(--r-lg)] bg-[var(--sunken)]">
            <img
              :if={choice.recipe.image_path}
              src={"/images/recipes/#{choice.recipe.id}"}
              alt=""
              loading="lazy"
              class="absolute inset-0 size-full object-cover"
            />
          </span>
          <span class="min-w-0 flex-1">
            <span
              class="line-clamp-2 block font-semibold text-[color:var(--text)]"
              style="font-size: 16px; line-height: 1.25;"
            >
              {choice.recipe.title}
            </span>
            <span
              :if={choice.reasons != []}
              class="mt-1 line-clamp-1 block text-[color:var(--muted)]"
              style="font-size: 14px;"
            >
              {hd(choice.reasons)}
            </span>
          </span>
          <span
            :if={@prices[choice.recipe.id]}
            data-role="price-diff"
            class={[
              "num shrink-0 self-center",
              String.starts_with?(@prices[choice.recipe.id], "−") &&
                "font-medium text-[color:var(--done)]",
              !String.starts_with?(@prices[choice.recipe.id], "−") && "text-[color:var(--muted)]"
            ]}
            style="font-size: 14px;"
          >
            {@prices[choice.recipe.id]}
          </span>
          <.icon
            :if={@selected_id == choice.recipe.id}
            name="ph-check-circle-fill"
            class="size-5 shrink-0 text-[color:var(--done)]"
          />
        </button>
      </li>
    </ul>
    """
  end
end
