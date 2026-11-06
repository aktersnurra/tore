defmodule ToreWeb.DevSessionController do
  @moduledoc "Development-only sign-in that skips Pocket ID. Routed only when `:dev_routes` is on."

  use ToreWeb, :controller

  @claims %{"sub" => "dev", "preferred_username" => "dev", "name" => "Dev", "tore_ai" => true}

  def create(conn, _params) do
    {:ok, user} = Tore.Accounts.sign_in(@claims)

    conn
    |> ToreWeb.UserSession.log_in(user)
    |> redirect(to: ~p"/")
  end
end
