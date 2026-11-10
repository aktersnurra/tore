defmodule ToreWeb.ReviewController do
  use ToreWeb, :controller

  @doc "Opens the oldest review waiting, returning to Home once it's handled."
  def next(conn, _params) do
    case Tore.Harness.Runs.list_reviews(conn.assigns.current_scope) do
      [] -> redirect(conn, to: ~p"/")
      [run | _] -> redirect(conn, to: ~p"/runs/#{run.id}?#{[from: "/"]}")
    end
  end
end
