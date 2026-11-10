defmodule ToreWeb.UserSession do
  @moduledoc "Starts and ends a person's session. The only place `user_id` is written."

  import Plug.Conn

  @spec log_in(Plug.Conn.t(), Tore.Accounts.User.t()) :: Plug.Conn.t()
  def log_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, socket_id(user))
  end

  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    if socket_id = get_session(conn, :live_socket_id) do
      ToreWeb.Endpoint.broadcast(socket_id, "disconnect", %{})
    end

    configure_session(conn, drop: true)
  end

  @doc """
  Closes the user's open LiveViews. They reconnect at once and mount with the scope their memberships
  now give them, so a removal or a switch takes effect everywhere they're signed in.
  """
  @spec disconnect(pos_integer()) :: :ok
  def disconnect(user_id),
    do: ToreWeb.Endpoint.broadcast("users_sessions:#{user_id}", "disconnect", %{})

  defp socket_id(user), do: "users_sessions:#{user.id}"
end
