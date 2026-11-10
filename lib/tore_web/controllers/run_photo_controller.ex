defmodule ToreWeb.RunPhotoController do
  @moduledoc """
  Serves the photo attached to a `KitchenRun` (uploaded receipts, shelf
  photos). Authenticated via the standard browser pipeline; the bytes
  come from S3 (`tore-runs`) but we don't expose Garage publicly — this
  controller is the seam.
  """

  use ToreWeb, :controller

  alias Tore.Harness.Run
  alias Tore.Storage
  alias Tore.Storage.Buckets

  def show(conn, %{"stream_id" => stream_id}) do
    with {:ok, state} <- Run.load(conn.assigns.current_scope, stream_id),
         key when is_binary(key) <- image_path_from(state),
         {:ok, body} <- Storage.client().get_object(Buckets.runs(), key) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp image_path_from(%{input: %{image_path: path}}) when is_binary(path), do: path
  defp image_path_from(%{input: %{"image_path" => path}}) when is_binary(path), do: path
  defp image_path_from(_), do: nil
end
