defmodule ToreWeb.Live.Auth do
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias Tore.Accounts

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = socket |> mount_current_user(session) |> attach_current_path()

    if socket.assigns.current_user do
      scope = socket.assigns.current_scope

      if Phoenix.LiveView.connected?(socket) do
        Phoenix.PubSub.subscribe(Tore.PubSub, "toasts:user:#{socket.assigns.current_user.id}")
        Phoenix.PubSub.subscribe(Tore.PubSub, Tore.Harness.Runs.topic(scope))
      end

      socket =
        socket
        |> assign(:inbox_count, inbox_count(scope))
        |> attach_toast_hook()
        |> attach_inbox_count_hook(scope)

      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  # A household with no language yet sends its members to /welcome, which picks it.
  def on_mount(:require_language, _params, _session, socket) do
    if Tore.Household.locale(socket.assigns.current_scope),
      do: {:cont, socket},
      else: {:halt, redirect(socket, to: "/welcome")}
  end

  # A page that shows runs says so with `on_mount {ToreWeb.Live.Auth, :hears_runs}`; other pages
  # never see `{:run_changed, run}`, so they need no clause for it.
  def on_mount(:hears_runs, _params, _session, socket),
    do: {:cont, assign(socket, :hears_runs, true)}

  defp attach_current_path(socket) do
    socket
    |> assign(:current_path, "/")
    |> attach_hook(:current_path, :handle_params, fn _params, url, socket ->
      path = URI.parse(url).path || "/"
      {:cont, assign(socket, :current_path, path)}
    end)
  end

  defp mount_current_user(socket, session) do
    case session["user_id"] && Accounts.get_session(session["user_id"]) do
      nil ->
        assign(socket, current_user: nil, current_scope: nil)

      {user, scope} ->
        Gettext.put_locale(ToreWeb.Gettext, user.locale)
        assign(socket, current_user: user, current_scope: scope)
    end
  end

  # Per-user PubSub topic for background jobs that need to surface a result
  # toast wherever the user happens to be at the moment they complete.
  defp attach_toast_hook(socket) do
    Phoenix.LiveView.attach_hook(socket, :toasts, :handle_info, fn
      {:toast, kind, message}, socket ->
        flash_key = if kind in [:error, :danger], do: :error, else: :info
        {:halt, Phoenix.LiveView.put_flash(socket, flash_key, message)}

      _other, socket ->
        {:cont, socket}
    end)
  end

  # Keep the global :inbox_count assign in sync — every authenticated
  # LiveView shares this via @inbox_count, most visibly Today's review pill.
  defp attach_inbox_count_hook(socket, scope) do
    Phoenix.LiveView.attach_hook(socket, :inbox_count, :handle_info, fn
      {:run_changed, _run}, socket ->
        socket = assign(socket, :inbox_count, inbox_count(scope))
        if socket.assigns[:hears_runs], do: {:cont, socket}, else: {:halt, socket}

      _other, socket ->
        {:cont, socket}
    end)
  end

  defp inbox_count(scope), do: length(Tore.Harness.Runs.list_reviews(scope))
end
