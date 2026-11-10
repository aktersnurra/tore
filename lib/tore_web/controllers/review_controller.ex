defmodule ToreWeb.ReviewController do
  use ToreWeb, :controller

  alias Tore.Harness.{Projector, ProjectorSupervisor}

  @doc "Opens the oldest review waiting, returning to Home once it's handled."
  def next(conn, _params) do
    household_id = conn.assigns.current_scope.household_id
    {:ok, _pid} = ProjectorSupervisor.start_or_lookup(household_id)

    # list_pending/1 is newest first.
    case List.last(Projector.list_pending(household_id)) do
      nil -> redirect(conn, to: ~p"/")
      run -> redirect(conn, to: ~p"/runs/#{run.stream_id}?#{[from: "/"]}")
    end
  end
end
