defmodule ToreWeb.StepCards do
  @moduledoc """
  Something to follow with your hands full: one large card per step, stepped through with a
  tap, and the whole list one tap away to peek at what's coming. Cook mode and the week's prep
  both use it.

  A card is a map: `:text` (what to do), and optionally `:label` (the phase it belongs to),
  `:needs` (lines for what the step uses) and `:minutes`.

  The screen that renders it owns the position and handles two events: `"step"` with a `"to"`
  index, and `"toggle_overview"`.
  """

  use Phoenix.Component
  use Gettext, backend: ToreWeb.Gettext

  import ToreWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :cards, :list, required: true
  attr :index, :integer, required: true
  attr :overview, :boolean, default: false
  attr :close_to, :string, required: true, doc: "where the cross and the last card's button go"

  def deck(assigns) do
    assigns =
      assign(assigns,
        card: Enum.at(assigns.cards, assigns.index),
        last: length(assigns.cards) - 1
      )

    ~H"""
    <div
      id={@id}
      phx-hook=".Awake"
      class="fixed inset-0 z-[60] flex flex-col bg-[var(--bg)]"
      phx-window-keydown="step_key"
    >
      <header class="mx-auto flex w-full max-w-2xl items-center gap-3 px-4 pt-3">
        <.link
          navigate={@close_to}
          aria-label={gettext("Close")}
          class="press inline-flex size-11 shrink-0 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] hover:bg-[var(--border)]"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </.link>
        <p class="min-w-0 flex-1 truncate text-[14px] font-semibold text-[color:var(--muted)]">
          {@title}
        </p>
        <p class="num shrink-0 text-[14px] font-semibold text-[color:var(--text)]">
          {gettext("%{step} of %{total}", step: @index + 1, total: @last + 1)}
        </p>
      </header>

      <%!-- One segment per card: where you are, at a glance --%>
      <div class="mx-auto mt-3 flex w-full max-w-2xl gap-1 px-4" aria-hidden="true">
        <span
          :for={i <- 0..@last}
          class="h-1 flex-1 overflow-hidden rounded-full bg-[color:var(--border)]"
        >
          <span
            class="block h-full origin-left rounded-full bg-[color:var(--text)] transition-transform duration-[var(--dur-base)] ease-[var(--ease-out)]"
            style={"transform: scaleX(#{if i <= @index, do: 1, else: 0})"}
          >
          </span>
        </span>
      </div>

      <%!-- The card. Tapping it is the same as Next. --%>
      <button
        type="button"
        phx-click="step"
        phx-value-to={min(@index + 1, @last)}
        data-role="step-card"
        class="mx-auto flex w-full max-w-2xl flex-1 flex-col justify-center overflow-y-auto px-5 py-6 text-left"
      >
        <%!-- Keyed by position, so each new step arrives instead of swapping in place --%>
        <span id={"#{@id}-card-#{@index}"} class="reveal block">
          <span :if={@card[:label]} class="t-eyebrow block" style="font-size: 15px;">
            {@card.label}
          </span>
          <span
            class="mt-3 block font-bold text-[color:var(--text)]"
            style="font-size: 30px; line-height: 1.2; letter-spacing: -0.022em; text-wrap: pretty;"
          >
            {@card.text}
          </span>
          <span
            :if={@card[:minutes]}
            class="num mt-6 inline-flex h-10 items-center gap-2 rounded-full bg-[var(--sunken)] px-4 text-[16px] font-semibold text-[color:var(--text)]"
          >
            <.icon name="hero-clock" class="size-[18px] text-[color:var(--muted)]" />
            {gettext("%{minutes} min", minutes: @card.minutes)}
          </span>
          <span
            :if={@card[:needs] not in [nil, []]}
            class="menu-lines mt-7 block"
            style="padding-block: 4px;"
          >
            <span
              :for={need <- @card.needs}
              class="block py-3 text-[color:var(--text)]"
              style="font-size: 19px; line-height: 1.3;"
            >
              {need}
            </span>
          </span>
        </span>
      </button>

      <footer class="mx-auto flex w-full max-w-2xl items-center gap-2 px-4 pt-2 pb-[calc(env(safe-area-inset-bottom)+1rem)]">
        <button
          type="button"
          phx-click="step"
          phx-value-to={max(@index - 1, 0)}
          disabled={@index == 0}
          aria-label={gettext("Previous step")}
          class="press inline-flex size-14 shrink-0 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] disabled:opacity-30"
        >
          <.icon name="hero-chevron-left" class="size-6" />
        </button>
        <button
          type="button"
          phx-click="toggle_overview"
          aria-label={gettext("All steps")}
          class="press inline-flex size-14 shrink-0 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)]"
        >
          <.icon name="hero-list-bullet" class="size-6" />
        </button>
        <button
          :if={@index < @last}
          type="button"
          phx-click="step"
          phx-value-to={@index + 1}
          class="pill pill-lamp press h-14 flex-1 text-[17px]"
        >
          {gettext("Next")}
        </button>
        <.link
          :if={@index == @last}
          navigate={@close_to}
          class="pill press h-14 flex-1 bg-[color:var(--done)] text-[17px] text-[color:var(--bg)]"
        >
          <.icon name="hero-check" class="size-5" />
          {gettext("Done")}
        </.link>
      </footer>

      <%!-- Everything at once, to peek ahead. Tap a step to go there. --%>
      <div
        :if={@overview}
        id={"#{@id}-overview"}
        class="scrim fixed inset-0 z-[70] flex flex-col justify-end bg-black/50"
      >
        <div
          phx-click-away="toggle_overview"
          class="sheet mx-auto flex max-h-[88vh] w-full max-w-2xl flex-col rounded-t-[28px] bg-[var(--surface)] shadow-[var(--shadow-pop)]"
        >
          <div class="flex items-center justify-between px-5 pt-4 pb-2">
            <h2 class="t-head">{gettext("All steps")}</h2>
            <button
              type="button"
              phx-click="toggle_overview"
              aria-label={gettext("Close")}
              class="-mr-2 inline-flex size-11 items-center justify-center rounded-[var(--r-pill)] text-[color:var(--muted)] hover:bg-[var(--sunken)]"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <ol class="menu-lines overflow-y-auto px-5 pb-[calc(env(safe-area-inset-bottom)+1rem)]">
            <li :for={{card, i} <- Enum.with_index(@cards)}>
              <button
                type="button"
                phx-click="step"
                phx-value-to={i}
                aria-current={if i == @index, do: "step"}
                class="flex w-full items-baseline gap-3 py-3 text-left"
              >
                <span class={[
                  "num w-6 shrink-0 text-[13px] font-semibold",
                  i == @index && "text-[color:var(--text)]",
                  i != @index && "text-[color:var(--subtle)]"
                ]}>
                  {i + 1}
                </span>
                <span class="min-w-0 flex-1">
                  <span
                    :if={card[:label] && (i == 0 or Enum.at(@cards, i - 1)[:label] != card.label)}
                    class="block text-[13px] font-semibold text-[color:var(--muted)]"
                  >
                    {card.label}
                  </span>
                  <span
                    class={[
                      "block",
                      i < @index && "text-[color:var(--subtle)]",
                      i == @index && "font-semibold text-[color:var(--text)]",
                      i > @index && "text-[color:var(--text)]"
                    ]}
                    style="font-size: var(--t-body); line-height: 1.35;"
                  >
                    {card.text}
                  </span>
                  <span
                    :if={card[:needs] not in [nil, []]}
                    class="mt-0.5 block text-[color:var(--muted)]"
                    style="font-size: var(--t-meta);"
                  >
                    {Enum.join(card.needs, ", ")}
                  </span>
                </span>
                <span
                  :if={card[:minutes]}
                  class="num shrink-0 text-[13px] text-[color:var(--muted)]"
                >
                  {gettext("%{minutes} min", minutes: card.minutes)}
                </span>
              </button>
            </li>
          </ol>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Awake">
        // Keeps the screen on while the cards are open, where the browser allows it.
        export default {
          async mounted() {
            this.lock = async () => {
              try { this.sentinel = await navigator.wakeLock?.request("screen") } catch (_) {}
            }
            this.relock = () => document.visibilityState === "visible" && this.lock()
            document.addEventListener("visibilitychange", this.relock)
            await this.lock()
          },
          destroyed() {
            document.removeEventListener("visibilitychange", this.relock)
            this.sentinel?.release()
          }
        }
      </script>
    </div>
    """
  end

  @doc "Where an arrow key moves to from `index`, or `index` for any other key."
  @spec key_target(String.t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def key_target("ArrowRight", index, count), do: min(index + 1, count - 1)
  def key_target("ArrowLeft", index, _count), do: max(index - 1, 0)
  def key_target(_key, index, _count), do: index
end
