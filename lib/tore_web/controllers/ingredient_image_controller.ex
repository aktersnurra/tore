defmodule ToreWeb.IngredientImageController do
  @moduledoc "A scanned pack's photo, served from Tore so the browser never asks Open Food Facts."

  use ToreWeb, :controller

  def show(conn, %{"id" => id}) do
    case Tore.Pantry.picture(conn.assigns.current_scope, id) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> send_resp(200, body)

      :none ->
        send_resp(conn, 404, "")
    end
  end
end
