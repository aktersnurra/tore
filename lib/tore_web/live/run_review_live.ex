defmodule ToreWeb.RunReviewLive do
  @moduledoc """
  A run waiting for review: a receipt whose lines don't add up to its total, or a recipe the
  planner proposed. A receipt's card corrects the store, total and date (which sets its week);
  confirming goes through `Runs.confirm/3`, which verifies it again before applying.
  """

  use ToreWeb, :live_view

  alias Tore.Harness.Artifact.{CostEntry, RecipeProposal}
  alias Tore.Harness.{KitchenRun, Runs}

  @impl true
  def mount(%{"stream_id" => stream_id} = params, _session, socket) do
    socket =
      socket
      |> assign(:return_to, return_to_from_params(params))
      |> assign(:confirming_discard?, false)
      |> assign(:lightbox?, false)

    case Runs.get(socket.assigns.current_scope, stream_id) do
      %KitchenRun{status: :needs_user, artifacts: [_ | _]} = run ->
        {:ok, mount_needs_user(socket, stream_id, run)}

      %KitchenRun{status: status, failure_code: code}
      when status in [:applied, :failed, :discarded, :reverted] ->
        {:ok, assign(socket, stream_id: stream_id, state: status, error: code)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found.")
         |> push_navigate(to: socket.assigns.return_to)}
    end
  end

  # A recipe proposal carries no CostEntry, so it cannot go through the
  # receipt path — form_data_from/1 builds itself from the cost artifact.
  defp mount_needs_user(socket, stream_id, %KitchenRun{artifacts: [proposal]} = run) do
    case proposal do
      %RecipeProposal{} = proposal ->
        socket
        |> assign(:stream_id, stream_id)
        |> assign(:state, :recipe_proposal)
        |> assign(:has_photo?, false)
        |> assign(:proposal, proposal)
        |> assign(:error, nil)

      %CostEntry{} = cost ->
        socket
        |> assign(:stream_id, stream_id)
        |> assign(:state, :needs_user)
        |> assign(:has_photo?, has_image_path?(run.input))
        |> assign(:cost, cost)
        |> assign(:form_data, form_data_from(cost))
        |> assign(:error, nil)
    end
  end

  defp has_image_path?(%{"image_path" => p}) when is_binary(p) and p != "", do: true
  defp has_image_path?(_), do: false

  # Only allow same-origin paths in ?from= — never honour an absolute URL or
  # anything that could push the user off-site. Defaults to Home, whose pill
  # shows any reviews still waiting.
  defp return_to_from_params(params) do
    ToreWeb.SafeReturn.path(Map.get(params, "from"), "/")
  end

  @impl true
  def handle_event("update", %{"receipt" => params}, socket) do
    {:noreply, assign(socket, :form_data, merge_form(socket.assigns.form_data, params))}
  end

  def handle_event("open_lightbox", _params, socket),
    do: {:noreply, assign(socket, :lightbox?, true)}

  def handle_event("close_lightbox", _params, socket),
    do: {:noreply, assign(socket, :lightbox?, false)}

  def handle_event("ask_discard", _params, socket),
    do: {:noreply, assign(socket, :confirming_discard?, true)}

  def handle_event("cancel_discard", _params, socket),
    do: {:noreply, assign(socket, :confirming_discard?, false)}

  def handle_event("confirm_discard", _params, socket) do
    stream_id = socket.assigns.stream_id
    user_id = socket.assigns.current_user && socket.assigns.current_user.id

    # Discard is fast (no LLM), but we still fire-and-forget for symmetry with
    # save — the page navigates instantly, the toast confirms it landed.
    discarded_msg =
      case socket.assigns.state do
        :recipe_proposal -> gettext("Recipe discarded.")
        _ -> gettext("Receipt discarded.")
      end

    scope = socket.assigns.current_scope

    in_background(fn ->
      case Runs.discard(scope, stream_id, :user_discarded) do
        {:ok, _} ->
          broadcast_toast(user_id, :info, discarded_msg)

        {:error, reason} ->
          broadcast_toast(user_id, :error, "Couldn't discard: #{inspect(reason)}.")
      end
    end)

    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  def handle_event("confirm", _params, socket) do
    cost = build_cost(socket.assigns.cost, socket.assigns.form_data)
    user_id = socket.assigns.current_user && socket.assigns.current_user.id
    %{stream_id: stream_id, current_scope: scope} = socket.assigns

    # Fire-and-forget: bounce the user back immediately. The toast on
    # completion lands wherever they happen to be (PubSub topic
    # "toasts:user:<id>").
    in_background(fn ->
      case Runs.confirm(scope, stream_id, cost) do
        {:ok, _} ->
          broadcast_toast(user_id, :info, gettext("Receipt saved."))

        {:error, {:verifier_failed, code, _}} ->
          broadcast_toast(user_id, :error, receipt_message(code))

        {:error, _reason} ->
          broadcast_toast(user_id, :error, gettext("Couldn't save the receipt."))
      end
    end)

    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  def handle_event("save_recipe", _params, socket) do
    proposal = socket.assigns.proposal
    user_id = socket.assigns.current_user && socket.assigns.current_user.id
    %{stream_id: stream_id, current_scope: scope} = socket.assigns

    # Same fire-and-forget shape as the receipt save: the commit re-runs the
    # verifier and writes the catalog, so bounce the user back now and let the
    # toast confirm it landed.
    in_background(fn ->
      case Runs.confirm(scope, stream_id, proposal) do
        {:ok, _} ->
          broadcast_toast(user_id, :info, gettext("Recipe saved."))

        {:error, {:verifier_failed, code, _}} ->
          broadcast_toast(user_id, :error, verifier_message(code))

        {:error, reason} ->
          broadcast_toast(
            user_id,
            :error,
            "#{gettext("Couldn't save recipe")}: #{inspect(reason)}."
          )
      end
    end)

    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  defp verifier_message(:near_duplicate),
    do: gettext("You already have a recipe just like this one.")

  defp verifier_message(:no_ingredients), do: gettext("That recipe has no ingredients.")

  defp verifier_message(:slot_pinned),
    do: gettext("That day is pinned now, so the recipe wasn't saved. Unpin it and try again.")

  defp verifier_message(:slot_eating_out),
    do: gettext("You're eating out that day now, so the recipe wasn't saved.")

  defp verifier_message(_), do: gettext("That recipe came back incomplete.")

  # The toast is translated in the task, so it takes the page's locale along.
  defp in_background(fun) do
    locale = Gettext.get_locale(ToreWeb.Gettext)

    Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
      Gettext.put_locale(ToreWeb.Gettext, locale)
      fun.()
    end)
  end

  defp receipt_message(:missing_store), do: gettext("The receipt needs a store.")
  defp receipt_message(:missing_total), do: gettext("The receipt needs a total.")
  defp receipt_message(:date_in_future), do: gettext("The date is in the future.")
  defp receipt_message(_), do: gettext("Couldn't save the receipt.")

  defp broadcast_toast(nil, _kind, _msg), do: :ok

  defp broadcast_toast(user_id, kind, message) do
    Phoenix.PubSub.broadcast(Tore.PubSub, "toasts:user:#{user_id}", {:toast, kind, message})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={~p"/runs/#{@stream_id}"}>
      <div class="max-w-2xl mx-auto px-4 py-6">
        <.link
          navigate={@return_to}
          class="text-[color:var(--muted)] text-sm mb-4 inline-flex items-center gap-1"
        >
          <.icon name="hero-arrow-left" class="size-4" /> {back_label(@return_to)}
        </.link>
        {render_body(assigns)}
      </div>
    </Layouts.app>
    """
  end

  defp back_label("/capture"), do: gettext("Back to chat")
  defp back_label(_), do: gettext("Back")

  defp render_body(%{state: :needs_user} = assigns) do
    ~H"""
    <h2 class="text-xl font-semibold text-[color:var(--text)] mb-4">
      {gettext("Review receipt")}
    </h2>
    <p class="text-sm text-[color:var(--muted)] mb-4">
      {gettext("The lines add up to %{sum}, but the total says %{total}. Check the total, then save.",
        sum: sum_display(@cost),
        total: decimal_to_str(@cost.total)
      )}
    </p>

    <.error_banner :if={@error} code={@error} />

    <figure :if={@has_photo?} class="mb-5">
      <button
        type="button"
        phx-click="open_lightbox"
        aria-label={gettext("Open photo")}
        class="block w-full focus:outline-none"
      >
        <img
          src={~p"/images/runs/#{@stream_id}"}
          alt={gettext("Original photo")}
          class="w-full max-h-[60vh] object-contain rounded-2xl border border-[color:var(--border)] bg-[color:var(--accent-soft)]/30 cursor-zoom-in"
        />
      </button>
      <figcaption class="mt-1 text-xs text-[color:var(--muted)] text-center">
        {gettext("Tap to enlarge")}
      </figcaption>
    </figure>

    <%!-- Fullscreen lightbox. Backdrop click + Esc close. The image is at its
         natural size with overflow-auto on the container so the browser's
         own pan/pinch/scroll-zoom take over once it exceeds the viewport. --%>
    <div
      :if={@lightbox?}
      phx-click="close_lightbox"
      phx-window-keyup="close_lightbox"
      phx-key="Escape"
      class="fixed inset-0 z-50 bg-black/90 overflow-auto cursor-zoom-out"
    >
      <button
        type="button"
        phx-click="close_lightbox"
        aria-label={gettext("Close")}
        class="fixed top-4 right-4 z-10 size-10 rounded-full bg-white/10 text-white inline-flex items-center justify-center hover:bg-white/20"
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>

      <img
        src={~p"/images/runs/#{@stream_id}"}
        alt={gettext("Original photo")}
        class="mx-auto my-8 max-w-none"
      />
    </div>

    <form phx-change="update" phx-submit="confirm" class="space-y-4">
      <div class="grid grid-cols-2 gap-3">
        <label class="block">
          <span class="block text-xs text-[color:var(--muted)] mb-1">{gettext("Store")}</span>
          <input
            type="text"
            name="receipt[store_name]"
            value={@form_data.store_name}
            class="w-full rounded-lg border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-sm"
          />
        </label>
        <label class="block">
          <span class="block text-xs text-[color:var(--muted)] mb-1">{gettext("Date")}</span>
          <input
            type="date"
            name="receipt[date]"
            value={@form_data.date}
            class={[
              "w-full rounded-lg border bg-[var(--surface)] px-3 py-2 text-sm",
              @form_data.date_inferred? && "border-amber-500",
              !@form_data.date_inferred? && "border-[color:var(--border)]"
            ]}
          />
          <p :if={@form_data.date_inferred?} class="text-xs text-amber-600 mt-1">
            {gettext("Couldn't read the date from the receipt — please verify.")}
          </p>
        </label>
      </div>
      <label class="block">
        <span class="block text-xs text-[color:var(--muted)] mb-1">{gettext("Total")}</span>
        <input
          type="text"
          inputmode="decimal"
          name="receipt[total]"
          value={@form_data.total}
          class="w-full rounded-lg border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-sm"
        />
      </label>

      <%= if @confirming_discard? do %>
        <div class="flex gap-2">
          <button
            type="button"
            phx-click="cancel_discard"
            class="flex-1 rounded-xl border border-[color:var(--border)] bg-[var(--surface)] text-[color:var(--text)] py-3 font-semibold"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            phx-click="confirm_discard"
            class="flex-1 rounded-xl bg-red-600 text-white py-3 font-semibold"
          >
            {gettext("Discard")}
          </button>
        </div>
      <% else %>
        <div class="flex gap-2">
          <button
            type="button"
            phx-click="ask_discard"
            class="shrink-0 rounded-xl border border-[color:var(--border)] bg-[var(--surface)] text-[color:var(--muted)] px-4 py-3 font-semibold"
          >
            {gettext("Discard")}
          </button>
          <button
            type="submit"
            class="flex-1 rounded-xl bg-[color:var(--accent)] text-white py-3 font-semibold"
          >
            {gettext("Save receipt")}
          </button>
        </div>
      <% end %>
    </form>
    """
  end

  defp render_body(%{state: :recipe_proposal} = assigns) do
    ~H"""
    <h2 class="text-xl font-semibold text-[color:var(--text)] mb-1">{@proposal.title}</h2>
    <p class="text-sm text-[color:var(--muted)] mb-4">
      {gettext("Save this recipe to your catalog, or discard it.")}
    </p>

    <.error_banner :if={@error} code={@error} />

    <div class="rounded-2xl border border-[color:var(--border)] bg-[var(--surface)] p-4 space-y-4">
      <p :if={@proposal.description} class="text-sm text-[color:var(--text)]">
        {@proposal.description}
      </p>

      <p class="text-xs text-[color:var(--muted)]">
        {recipe_meta(@proposal)}
      </p>

      <section>
        <h3 class="text-sm font-medium text-[color:var(--text)] mb-2">
          {gettext("Ingredients")}
        </h3>
        <ul class="space-y-1">
          <li
            :for={ing <- @proposal.ingredients}
            class="text-sm text-[color:var(--text)] flex justify-between gap-3"
          >
            <span>{ing[:name]}</span>
            <span class="text-[color:var(--muted)] shrink-0">{ingredient_amount(ing)}</span>
          </li>
        </ul>
      </section>

      <section :if={@proposal.instructions}>
        <h3 class="text-sm font-medium text-[color:var(--text)] mb-2">{gettext("Method")}</h3>
        <p class="text-sm text-[color:var(--text)] whitespace-pre-line">
          {@proposal.instructions}
        </p>
      </section>

      <p :if={@proposal.source_url} class="text-xs text-[color:var(--muted)]">
        {gettext("From")} {@proposal.source_url}
      </p>
    </div>

    <%= if @confirming_discard? do %>
      <div class="flex gap-2 mt-4">
        <button
          type="button"
          phx-click="cancel_discard"
          class="flex-1 rounded-xl border border-[color:var(--border)] bg-[var(--surface)] text-[color:var(--text)] py-3 font-semibold"
        >
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          phx-click="confirm_discard"
          class="flex-1 rounded-xl bg-red-600 text-white py-3 font-semibold"
        >
          {gettext("Discard")}
        </button>
      </div>
    <% else %>
      <div class="flex gap-2 mt-4">
        <button
          type="button"
          phx-click="ask_discard"
          class="shrink-0 rounded-xl border border-[color:var(--border)] bg-[var(--surface)] text-[color:var(--muted)] px-4 py-3 font-semibold"
        >
          {gettext("Discard")}
        </button>
        <button
          type="submit"
          phx-click="save_recipe"
          class="flex-1 rounded-xl bg-[color:var(--accent)] text-white py-3 font-semibold"
        >
          {gettext("Save recipe")}
        </button>
      </div>
    <% end %>
    """
  end

  defp render_body(%{state: :applied} = assigns) do
    ~H"""
    <p class="text-[color:var(--accent)] font-semibold">{gettext("Already saved.")}</p>
    """
  end

  defp render_body(%{state: :reverted} = assigns) do
    ~H"""
    <p class="text-[color:var(--muted)] font-semibold">{gettext("This was undone.")}</p>
    """
  end

  defp render_body(%{state: :discarded} = assigns) do
    ~H"""
    <p class="text-[color:var(--muted)] font-semibold">{gettext("This was discarded.")}</p>
    """
  end

  defp render_body(%{state: :failed} = assigns) do
    ~H"""
    <p class="text-red-500 font-semibold">{gettext("This failed.")} {@error}</p>
    """
  end

  defp recipe_meta(%RecipeProposal{} = p) do
    [
      p.base_servings && "#{p.base_servings} #{gettext("servings")}",
      p.prep_time_minutes && "#{p.prep_time_minutes} #{gettext("min prep")}",
      p.cook_time_minutes && "#{p.cook_time_minutes} #{gettext("min cooking")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp ingredient_amount(ing) do
    [ing[:quantity], ing[:unit]]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp error_banner(assigns) do
    ~H"""
    <div class="mb-4 rounded-lg border border-red-500/40 bg-red-500/10 px-3 py-2 text-sm text-red-500">
      {gettext("Couldn't save:")} {@code}
    </div>
    """
  end

  defp form_data_from(%CostEntry{} = c) do
    %{
      store_name: c.store_name || "",
      date: Date.to_iso8601(c.date),
      date_inferred?: c.date_inferred? || false,
      total: decimal_to_str(c.total)
    }
  end

  defp merge_form(current, params) do
    # Once someone touches the date we trust it and drop the warning.
    new_date = params["date"] || current.date

    %{
      store_name: params["store_name"] || current.store_name,
      date: new_date,
      date_inferred?: current.date_inferred? and new_date == current.date,
      total: params["total"] || current.total
    }
  end

  # The lines stay as read; the card corrects the store, total and date.
  defp build_cost(%CostEntry{} = c, form) do
    %CostEntry{
      c
      | store_name: String.trim(form.store_name),
        date: parse_date(form.date, c.date),
        total: parse_decimal(form.total) || c.total
    }
  end

  defp sum_display(%CostEntry{line_items: items}) do
    items
    |> Enum.reduce(Decimal.new(0), fn it, acc ->
      if it[:total_price], do: Decimal.add(acc, it.total_price), else: acc
    end)
    |> Decimal.to_string(:normal)
  end

  defp parse_date(str, fallback) do
    case Date.from_iso8601(str || "") do
      {:ok, d} -> d
      _ -> fallback
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil
  defp parse_decimal(%Decimal{} = d), do: d

  defp parse_decimal(s) when is_binary(s) do
    case Decimal.parse(String.replace(s, ",", ".")) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp decimal_to_str(nil), do: ""
  defp decimal_to_str(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal_to_str(n) when is_number(n), do: to_string(n)
  defp decimal_to_str(s) when is_binary(s), do: s
end
