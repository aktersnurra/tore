defmodule ToreWeb.PrepLive do
  use ToreWeb, :live_view

  alias Tore.Prep

  def mount(_params, _session, socket) do
    week_start = week_start(Date.utc_today())
    plan_id = Tore.Streams.plan(socket.assigns.current_scope, week_start)
    guide = Prep.get_guide_for_week(week_start)

    {:ok,
     assign(socket,
       week_start: week_start,
       plan_id: plan_id,
       guide: guide,
       generating: false,
       tab: "timeline"
     )}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, tab: tab)}

  def handle_event("generate_guide", _params, socket) do
    %{plan_id: plan_id, week_start: week_start, current_scope: scope} = socket.assigns
    lv = self()

    Task.start(fn ->
      result =
        try do
          Prep.generate_guide(scope, plan_id, week_start)
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end

      send(lv, {:guide_ready, result})
    end)

    {:noreply, assign(socket, generating: true)}
  end

  def handle_info({:guide_ready, {:ok, guide}}, socket) do
    {:noreply, assign(socket, guide: guide, generating: false)}
  end

  def handle_info({:guide_ready, {:error, :budget_exceeded}}, socket) do
    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:error, gettext("Monthly LLM budget reached"))}
  end

  def handle_info({:guide_ready, {:error, :cooldown}}, socket) do
    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:error, gettext("Please wait a moment before generating again"))}
  end

  def handle_info({:guide_ready, {:error, _}}, socket) do
    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:error, gettext("Prep guide generation failed"))}
  end

  def render(assigns) do
    tabs = [
      %{id: "timeline", label: gettext("Timeline")},
      %{id: "components", label: gettext("Components")},
      %{id: "notes", label: gettext("Notes")}
    ]

    total_min =
      case assigns.guide && assigns.guide.timeline do
        nil -> 0
        steps -> Enum.reduce(steps, 0, fn s, acc -> acc + (s["duration_min"] || 0) end)
      end

    assigns = assign(assigns, tabs: tabs, total_min: total_min)

    ~H"""
    <Layouts.app flash={@flash} current_path={assigns[:current_path] || "/prep"}>
      <.page max_width={:md}>
        <.card padded={false}>
          <header class="flex items-center justify-between px-6 pt-6 pb-3">
            <h1 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h1);">
              {gettext("Prep Guide")}
            </h1>
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="h-9 px-3 inline-flex items-center gap-1.5 rounded-[var(--r-lg)] border border-[color:var(--border)] text-[color:var(--muted)] hover:border-[color:var(--subtle)]"
                style="font-size: var(--t-meta);"
              >
                {Calendar.strftime(@week_start, "%b %-d")} – {Calendar.strftime(
                  Date.add(@week_start, 6),
                  "%b %-d"
                )}
                <.icon name="hero-chevron-down" class="size-3.5" />
              </button>
            </div>
          </header>

          <%= cond do %>
            <% @generating -> %>
              <div class="px-6 py-14 flex flex-col items-center text-center border-t border-[color:var(--hairline)]">
                <div class="size-8 animate-spin rounded-full border-2 border-[color:var(--accent)] border-t-transparent mb-4">
                </div>
                <p class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("Generating your prep guide…")}
                </p>
              </div>
            <% @guide -> %>
              <div class="px-6 pt-3 border-t border-[color:var(--hairline)]">
                <div class="flex items-baseline justify-between pb-4 border-b border-[color:var(--hairline)]">
                  <h2 class="font-semibold" style="font-size: var(--t-h2);">
                    {gettext("Sunday Prep Plan")}
                  </h2>
                  <div class="flex items-center gap-3">
                    <span
                      :if={@total_min > 0}
                      class="text-[color:var(--muted)]"
                      style="font-size: var(--t-meta);"
                    >
                      {gettext("%{duration} total", duration: format_duration(@total_min))}
                    </span>
                    <button
                      type="button"
                      phx-click="generate_guide"
                      data-confirm={
                        gettext("Regenerate the prep guide? The current guide will be replaced.")
                      }
                      class="size-7 inline-flex items-center justify-center rounded-[var(--r-md)] text-[color:var(--muted)] hover:text-[var(--text)] hover:bg-[color:var(--hairline)] transition-colors"
                    >
                      <.icon name="hero-arrow-path" class="size-4" />
                    </button>
                  </div>
                </div>

                <p class="mt-3 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("Batch prep to make the week easier. Most components keep 3–4 days.")}
                </p>

                <div class="mt-4">
                  <.tabs items={@tabs} active={@tab} />
                </div>

                <div class="pt-5 pb-6">
                  <%= cond do %>
                    <% @tab == "timeline" and @guide.timeline -> %>
                      {timeline_render(assigns)}
                    <% @tab == "timeline" -> %>
                      <.empty message={gettext("No timeline yet")} />
                    <% @tab == "components" and @guide.prep_session -> %>
                      <div class="space-y-6">
                        <div
                          :for={
                            {key, label} <- [
                              {"proteins", gettext("Proteins")},
                              {"bases", gettext("Bases")},
                              {"sauces", gettext("Sauces")},
                              {"vegetables", gettext("Vegetables")}
                            ]
                          }
                          :if={@guide.prep_session[key] not in [nil, []]}
                        >
                          <h3
                            class="uppercase tracking-wider text-[color:var(--subtle)] mb-2"
                            style="font-size: var(--t-micro); font-weight: 600;"
                          >
                            {label}
                          </h3>
                          <ul class="space-y-2">
                            <li
                              :for={item <- @guide.prep_session[key]}
                              class="flex gap-2"
                              style="font-size: var(--t-body);"
                            >
                              <span class="mt-1.5 size-1.5 rounded-full bg-[color:var(--accent)] shrink-0">
                              </span>
                              <span>
                                <span class="font-medium text-[var(--text)]">
                                  {hd(String.split(item, " — ", parts: 2))}
                                </span>
                                <span
                                  :if={String.contains?(item, " — ")}
                                  class="text-[color:var(--muted)]"
                                >
                                  {" — " <> List.last(String.split(item, " — ", parts: 2))}
                                </span>
                              </span>
                            </li>
                          </ul>
                        </div>
                      </div>
                    <% @tab == "components" -> %>
                      <.empty message={gettext("No components")} />
                    <% @tab == "notes" -> %>
                      <ul
                        :if={@guide.storage_notes}
                        class="space-y-2"
                        style="font-size: var(--t-body);"
                      >
                        <li
                          :for={line <- String.split(@guide.storage_notes, ~r/\.\s+/, trim: true)}
                          class="flex gap-2"
                        >
                          <span class="mt-1.5 size-1.5 rounded-full bg-[color:var(--subtle)] shrink-0">
                          </span>
                          <span class="text-[var(--text)]">{line}.</span>
                        </li>
                      </ul>
                      <.empty :if={!@guide.storage_notes} message={gettext("No notes")} />
                  <% end %>
                </div>
              </div>
            <% true -> %>
              <div class="px-6 py-14 flex flex-col items-center text-center border-t border-[color:var(--hairline)]">
                <div class="mb-5">
                  <.icon name="custom-prep" class="size-24" />
                </div>
                <h3 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h2);">
                  {gettext("No guide yet")}
                </h3>
                <p class="mt-1 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("Assign recipes in the planner, then generate your prep guide.")}
                </p>
                <div class="mt-5">
                  <.button variant={:primary} size={:lg} phx-click="generate_guide">
                    <.icon name="hero-sparkles" class="size-4" /> {gettext("Generate guide")}
                  </.button>
                </div>
              </div>
          <% end %>
        </.card>
      </.page>
    </Layouts.app>
    """
  end

  defp timeline_render(assigns) do
    {steps, _} =
      Enum.map_reduce(assigns.guide.timeline, 0, fn step, acc ->
        clock = format_clock_min(acc)
        new_acc = acc + (step["duration_min"] || 0)
        {Map.put(step, :clock, clock), new_acc}
      end)

    assigns = assign(assigns, steps: steps)

    ~H"""
    <ol class="relative pl-7">
      <span class="absolute left-2 top-2 bottom-2 w-px bg-[color:var(--hairline)]"></span>
      <li :for={step <- @steps} class="relative pb-5 last:pb-0">
        <span class="absolute -left-7 top-1 size-4 rounded-full bg-[color:var(--accent)] ring-4 ring-[var(--surface)]">
        </span>
        <div class="flex items-baseline gap-3">
          <span
            class="text-[color:var(--muted)] tabular-nums w-12 shrink-0"
            style="font-size: var(--t-meta);"
          >
            {step.clock}
          </span>
          <p class="font-semibold text-[var(--text)]" style="font-size: var(--t-body);">
            {step["task"] || step["uppgift"]}
          </p>
        </div>
        <p
          :if={step["detail"] || step["komponent"]}
          class="ml-[60px] mt-1 text-[color:var(--muted)]"
          style="font-size: var(--t-meta);"
        >
          {step["detail"] || step["komponent"]}
        </p>
      </li>
    </ol>
    """
  end

  defp format_clock_min(min) do
    h = div(min, 60)
    m = rem(min, 60)
    :io_lib.format("~B:~2..0B", [h, m]) |> IO.iodata_to_binary()
  end

  defp format_duration(min) when min >= 60 do
    h = div(min, 60)
    m = rem(min, 60)
    if m == 0, do: "#{h}h", else: "#{h}h #{m}m"
  end

  defp format_duration(min), do: "#{min}m"

  defp week_start(date) do
    dow = Date.day_of_week(date)
    Date.add(date, -(dow - 1))
  end
end
