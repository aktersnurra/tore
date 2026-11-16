defmodule ToreWeb.McpController do
  @moduledoc "POST /mcp: one JSON-RPC message per request, signed in by `ToreWeb.McpAuth`."
  use ToreWeb, :controller

  alias Tore.Mcp

  # A JSON array (a batch) is parsed under "_json"; batches are not supported.
  def create(conn, %{"_json" => _batch}), do: reply(conn, Mcp.handle(nil, :batch))

  def create(conn, _params),
    do: reply(conn, Mcp.handle(conn.assigns.current_scope, conn.body_params))

  # Stateless server: no event stream to open and no session to end.
  def unsupported(conn, _params),
    do: conn |> put_resp_header("allow", "POST") |> send_resp(405, "")

  defp reply(conn, :accepted), do: send_resp(conn, 202, "")
  defp reply(conn, {:reply, body}), do: json(conn, body)
end
