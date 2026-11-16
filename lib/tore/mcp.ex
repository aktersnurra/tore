defmodule Tore.Mcp do
  @moduledoc """
  The MCP server someone's own Claude uses Tore through: JSON-RPC over stateless Streamable HTTP,
  one request per POST, JSON replies only. Every call runs as the signed-in person's active
  household. Writes go through `Tore.Harness.Runs.submit/4`, so they pass the same verifiers and
  undo as the app's, and no tool calls the server's model. See `.docs/specs/mcp.md`.
  """

  alias Tore.Scope

  @protocol_versions ~w[2025-06-18 2025-03-26 2024-11-05]

  @tools []

  def tools, do: @tools

  def latest_protocol_version, do: hd(@protocol_versions)

  # No scope for a request refused before sign-in matters (a batch).
  @spec handle(Scope.t() | nil, term(), [module()]) :: {:reply, map()} | :accepted
  def handle(scope, request, tools \\ tools())

  def handle(_scope, %{"jsonrpc" => "2.0", "method" => "notifications/" <> _} = request, _tools)
      when not is_map_key(request, "id"),
      do: :accepted

  def handle(
        %Scope{} = scope,
        %{"jsonrpc" => "2.0", "id" => id, "method" => method} = request,
        tools
      )
      when is_binary(method) do
    case dispatch(scope, method, Map.get(request, "params") || %{}, tools) do
      {:ok, result} -> {:reply, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
      {:error, code, message} -> error(id, code, message)
    end
  end

  def handle(_scope, request, _tools),
    do: error(if(is_map(request), do: Map.get(request, "id")), -32600, "Invalid Request")

  defp dispatch(_scope, "initialize", params, _tools) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       "protocolVersion" =>
         if(requested in @protocol_versions, do: requested, else: latest_protocol_version()),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "tore", "version" => version()}
     }}
  end

  defp dispatch(_scope, "ping", _params, _tools), do: {:ok, %{}}

  defp dispatch(_scope, "tools/list", _params, tools) do
    {:ok,
     %{
       "tools" =>
         Enum.map(tools, fn module ->
           %{
             "name" => module.name(),
             "description" => module.description(),
             "inputSchema" => module.schema()
           }
         end)
     }}
  end

  defp dispatch(_scope, method, _params, _tools),
    do: {:error, -32601, "Method not found: #{method}"}

  defp error(id, code, message),
    do:
      {:reply,
       %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}}

  defp version, do: Application.spec(:tore, :vsn) |> to_string()
end
