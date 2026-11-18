defmodule Tore.LLM.OpenAIChatWithToolsTest do
  use ExUnit.Case, async: false

  import Req.Test, only: [raw_body: 1, stub: 2]

  alias Tore.LLM.OpenAI

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_config =
      Map.new([:openrouter_api_key, :openrouter_site_url, :openrouter_app_name], fn key ->
        {key, Application.get_env(:tore, key)}
      end)

    Application.put_env(:tore, :openrouter_api_key, "test-key")
    Application.put_env(:tore, :openrouter_site_url, "https://tore.test")
    Application.put_env(:tore, :openrouter_app_name, "Tore Test")

    on_exit(fn ->
      Enum.each(previous_config, fn
        {key, nil} -> Application.delete_env(:tore, key)
        {key, value} -> Application.put_env(:tore, key, value)
      end)
    end)

    %{req: Req.new(plug: {Req.Test, __MODULE__})}
  end

  test "unwraps the OpenRouter response envelope and decodes tool calls", %{req: req} do
    stub(__MODULE__, fn conn ->
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["https://tore.test"] = Plug.Conn.get_req_header(conn, "http-referer")
      assert ["Tore Test"] = Plug.Conn.get_req_header(conn, "x-title")

      assert %{
               "model" => "anthropic/claude-haiku-5.5",
               "stream" => false,
               "tool_choice" => "auto",
               "tools" => [%{"type" => "function"}],
               "messages" => [%{"role" => "system"}, %{"role" => "user", "content" => "skip mon"}]
             } = raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{
                    "name" => "skip_meal",
                    "arguments" => ~s({"slot_key":"mon_dinner"})
                  }
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      })
    end)

    assert {:ok, {:tool_calls, [call]},
            %{prompt_tokens: 10, completion_tokens: 5, cost_usd: cost_usd}} =
             OpenAI.chat_with_tools(
               "sys",
               [%{role: "user", content: "skip mon"}],
               [
                 %{
                   type: "function",
                   function: %{name: "skip_meal", description: "x", parameters: %{}}
                 }
               ],
               req: req
             )

    assert cost_usd == 0.0
    assert call.id == "call_1"
    assert call.name == "skip_meal"
    assert call.args == %{"slot_key" => "mon_dinner"}
  end

  test "unwraps the OpenRouter response envelope and decodes a normal message", %{req: req} do
    stub(__MODULE__, fn conn ->
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

      assert %{
               "model" => "anthropic/claude-haiku-5.5",
               "stream" => false,
               "tool_choice" => "auto",
               "tools" => [%{"type" => "function"}],
               "messages" => [%{"role" => "system"}, %{"role" => "user", "content" => "hello"}]
             } = raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "Hello from the model"}}],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 5}
      })
    end)

    assert {:ok, {:message, "Hello from the model"}, %{prompt_tokens: 4, completion_tokens: 5}} =
             OpenAI.chat_with_tools(
               "sys",
               [%{role: "user", content: "hello"}],
               [%{type: "function", function: %{name: "skip_meal", parameters: %{}}}],
               req: req
             )
  end
end
