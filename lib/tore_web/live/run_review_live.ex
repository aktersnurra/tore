defmodule ToreWeb.RunReviewLive do
  @moduledoc """
  A run waiting for review: a recipe that was read or proposed. Confirming goes through
  `Runs.confirm/3`, which verifies it again before applying.
  """

  use ToreWeb, :live_view

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.{KitchenRun, Runs}

  @impl true
  def mount(%{"stream_id" => stream_id} = params, _session, socket) do
    socket =
      socket
      |> assign(:return_to, return_to_from_params(params))
      |> assign(:confirming_discard?, false)

    case Runs.get(socket.assigns.current_scope, stream_id) do
      %KitchenRun{status: :needs_user, artifacts: [%RecipeProposal{} = proposal]} ->
        {:ok,
         socket
         |> assign(:stream_id, stream_id)
         |> assign(:state, :recipe_proposal)
         |> assign(:proposal, proposal)
         |> assign(:error, nil)}

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

  # Only allow same-origin paths in ?from= — never honour an absolute URL or
  # anything that could push the user off-site. Defaults to Home, whose pill
  # shows any reviews still waiting.
  defp return_to_from_params(params) do
    ToreWeb.SafeReturn.path(Map.get(params, "from"), "/")
  end

  @impl true
  def handle_event("ask_discard", _params, socket),
    do: {:noreply, assign(socket, :confirming_discard?, true)}

  def handle_event("cancel_discard", _params, socket),
    do: {:noreply, assign(socket, :confirming_discard?, false)}

  def handle_event("confirm_discard", _params, socket) do
    stream_id = socket.assigns.stream_id
    user_id = socket.assigns.current_user && socket.assigns.current_user.id

    # Discard is fast (no LLM), but we still fire-and-forget for symmetry with
    # save — the page navigates instantly, the toast confirms it landed.
    discarded_msg = gettext("Recipe discarded.")

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

  def handle_event("save_recipe", _params, socket) do
    proposal = socket.assigns.proposal
    user_id = socket.assigns.current_user && socket.assigns.current_user.id
    %{stream_id: stream_id, current_scope: scope} = socket.assigns

    # Fire-and-forget: the commit re-runs the verifier and writes the catalog,
    # so bounce the user back now and let the toast confirm it landed. The toast
    # lands wherever they happen to be (PubSub topic "toasts:user:<id>").
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

  defp broadcast_toast(nil, _kind, _msg), do: :ok

  defp broadcast_toast(user_id, kind, message) do
    Phoenix.PubSub.broadcast(Tore.PubSub, "toasts:user:#{user_id}", {:toast, kind, message})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      current_user={@current_user}
    >
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

  defp render_body(%{state: :recipe_proposal} = assigns) do
    ~H"""
    <h2 class="text-xl font-semibold text-[color:var(--text)] mb-1">{@proposal.title}</h2>
    <p class="text-sm text-[color:var(--muted)] mb-4">
      {gettext("Save this recipe to your catalog, or discard it.")}
    </p>

    <.error_banner :if={@error} code={@error} />

    <div class="rounded-[var(--r-lg)] border border-[color:var(--border)] bg-[var(--surface)] p-4 space-y-4">
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
          class="flex-1 rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] text-[color:var(--text)] py-3 font-semibold"
        >
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          phx-click="confirm_discard"
          class="flex-1 rounded-[var(--r-md)] bg-[color:var(--danger)] text-white py-3 font-semibold"
        >
          {gettext("Discard")}
        </button>
      </div>
    <% else %>
      <div class="flex gap-2 mt-4">
        <button
          type="button"
          phx-click="ask_discard"
          class="shrink-0 rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] text-[color:var(--muted)] px-4 py-3 font-semibold"
        >
          {gettext("Discard")}
        </button>
        <button
          type="submit"
          phx-click="save_recipe"
          class="flex-1 rounded-[var(--r-md)] bg-[color:var(--accent)] text-[color:var(--on-accent)] py-3 font-semibold"
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
    <p class="text-[color:var(--danger)] font-semibold">{gettext("This failed.")} {@error}</p>
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
    <div class="mb-4 rounded-[var(--r-md)] border border-[color:var(--danger)] bg-[var(--danger-soft)] px-3 py-2 text-sm text-[color:var(--danger)]">
      {gettext("Couldn't save:")} {@code}
    </div>
    """
  end
end
