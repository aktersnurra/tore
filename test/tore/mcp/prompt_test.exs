defmodule Tore.Mcp.PromptTest do
  use Tore.DataCase, async: false

  alias Tore.Mcp

  defp rpc(method, params \\ %{}) do
    {:reply, reply} =
      Mcp.handle(home_scope(), %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      })

    reply
  end

  test "initialize offers prompts" do
    assert %{"result" => %{"capabilities" => %{"prompts" => _}}} = rpc("initialize")
  end

  test "plan_week is the instructions Tore's own planning job gives pi" do
    assert %{"result" => %{"prompts" => [%{"name" => "plan_week", "description" => _}]}} =
             rpc("prompts/list")

    assert %{"result" => %{"messages" => [%{"role" => "user", "content" => %{"text" => text}}]}} =
             rpc("prompts/get", %{"name" => "plan_week"})

    assert text == Tore.Agent.task("plan_week")
    assert text =~ "get_context"
    assert text =~ "set_dinner"
  end

  test "an unknown prompt is a JSON-RPC error" do
    assert %{"error" => %{"code" => -32602}} = rpc("prompts/get", %{"name" => "nope"})
  end
end
