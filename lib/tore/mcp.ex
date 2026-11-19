defmodule Tore.Mcp do
  @moduledoc """
  The MCP server someone's own Claude uses Tore through: JSON-RPC over stateless Streamable HTTP,
  one request per POST, JSON replies only. Every call runs as the signed-in person's active
  household. Writes go through `Tore.Harness.Runs.submit/4`, so they pass the same verifiers and
  undo as the app's, and no tool calls the server's model. See `.docs/specs/mcp.md`.
  """

  alias Tore.Mcp.{PlanWeek, Tools}
  alias Tore.Scope

  @protocol_versions ~w[2025-06-18 2025-03-26 2024-11-05]

  @tools [
    Tools.GetContext,
    Tools.GetPlanningHistory,
    Tools.SearchRecipes,
    Tools.GetRecipe,
    Tools.ListReceipts,
    Tools.ListDeals,
    Tools.SetDinner,
    Tools.ChangeDay,
    Tools.SetDaysOff,
    Tools.AddToList,
    Tools.CheckOff,
    Tools.RemoveFromList,
    Tools.MakeList,
    Tools.AddToPantry,
    Tools.RemoveFromPantry,
    Tools.UpdateMemory,
    Tools.SetBudget,
    Tools.WhatIf,
    Tools.SetBasics,
    Tools.MatchDeals,
    Tools.MarkCooked,
    Tools.DeleteRecipe,
    Tools.PutTogether,
    Tools.DeleteReceipt,
    Tools.SaveRecipe,
    Tools.SavePrepGuide,
    Tools.UpdateRecipe,
    Tools.DrawRecipePicture,
    Tools.LogReceipt,
    Tools.Undo
  ]

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
       "capabilities" => %{
         "tools" => %{"listChanged" => false},
         "prompts" => %{"listChanged" => false}
       },
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

  defp dispatch(scope, "tools/call", %{"name" => name} = params, tools) when is_binary(name) do
    case Enum.find(tools, &(&1.name() == name)) do
      nil -> {:error, -32602, "Unknown tool: #{name}"}
      module -> {:ok, tool_result(module.call(scope, Map.get(params, "arguments") || %{}))}
    end
  end

  defp dispatch(_scope, "tools/call", _params, _tools),
    do: {:error, -32602, "tools/call needs a tool name"}

  defp dispatch(_scope, "prompts/list", _params, _tools),
    do:
      {:ok,
       %{"prompts" => [%{"name" => PlanWeek.name(), "description" => PlanWeek.description()}]}}

  defp dispatch(scope, "prompts/get", %{"name" => "plan_week"}, _tools),
    do:
      {:ok,
       %{
         "description" => PlanWeek.description(),
         "messages" => [
           %{"role" => "user", "content" => %{"type" => "text", "text" => PlanWeek.text(scope)}}
         ]
       }}

  defp dispatch(_scope, "prompts/get", _params, _tools), do: {:error, -32602, "Unknown prompt"}

  defp dispatch(_scope, method, _params, _tools),
    do: {:error, -32601, "Method not found: #{method}"}

  # The content is JSON text for clients that only read text, and the same map as structured content.
  defp tool_result({:ok, result}) when is_map(result),
    do: %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
      "structuredContent" => result,
      "isError" => false
    }

  defp tool_result({:error, message}) when is_binary(message),
    do: %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}

  defp error(id, code, message),
    do:
      {:reply,
       %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}}

  defp version, do: Application.spec(:tore, :vsn) |> to_string()
end
