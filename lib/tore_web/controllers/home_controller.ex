defmodule ToreWeb.HomeController do
  use ToreWeb, :controller

  @doc """
  Opens the app where the stored pick says (`Tore.Home.current/1`), without waiting on a model.
  A stale pick starts a new one in the background, for the next time.
  """
  def show(conn, _params) do
    scope = conn.assigns.current_scope

    if Tore.Household.locale(scope) do
      %{screen: screen, stale?: stale?} = Tore.Home.current(scope)
      if stale?, do: Tore.Home.refresh(scope)
      redirect(conn, to: Tore.Home.path(screen))
    else
      redirect(conn, to: ~p"/welcome")
    end
  end
end
