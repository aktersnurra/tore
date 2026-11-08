defmodule Tore.LLM.OpenAIWebSearchTest do
  use Tore.DataCase, async: false

  alias Tore.LLM.OpenAI

  setup do
    # OpenAI builds its client from app config; make sure the keys exist.
    Application.put_env(:tore, :openrouter_api_key, "test-key")
    Application.put_env(:tore, :openrouter_site_url, "http://localhost")
    Application.put_env(:tore, :openrouter_app_name, "tore-test")
    :ok
  end

  # OpenRouter.chat_completions/3 takes an injected `:req`, and Tore.LLM.OpenAI
  # forwards its opts straight through — so a stub Req captures the real body.
  defp capturing_req(test_pid, content) do
    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})

      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => 0.001}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    Req.new(plug: plug)
  end

  test "web_search/3 puts the web plugin in the request body" do
    req = capturing_req(self(), %{"candidates" => []})

    OpenAI.web_search("find recipes", "ramen", req: req)

    assert_received {:request_body, body}
    assert body["plugins"] == [%{"id" => "web", "max_results" => 5}]
  end

  test "web_search/3 honours a :max_results option" do
    req = capturing_req(self(), %{"candidates" => []})

    OpenAI.web_search("find recipes", "ramen", req: req, max_results: 3)

    assert_received {:request_body, body}
    assert body["plugins"] == [%{"id" => "web", "max_results" => 3}]
  end

  test "web_search/3 sends the system and user messages" do
    req = capturing_req(self(), %{"candidates" => []})

    OpenAI.web_search("find recipes", "ramen", req: req)

    assert_received {:request_body, body}

    assert [
             %{"role" => "system", "content" => "find recipes"},
             %{"role" => "user", "content" => "ramen"}
           ] =
             body["messages"]
  end

  test "web_search/3 decodes the JSON payload and usage" do
    req =
      capturing_req(self(), %{
        "candidates" => [%{"title" => "Best Ramen", "url" => "https://example.com/ramen"}]
      })

    assert {:ok, %{"candidates" => [candidate]}, usage} =
             OpenAI.web_search("find recipes", "ramen", req: req)

    assert candidate["url"] == "https://example.com/ramen"
    assert usage.prompt_tokens == 10
    assert usage.completion_tokens == 5
  end

  test "the facade delegates web_search/3 to the configured spec" do
    # config/test.exs wires :llm_spec to Tore.MockLLM.
    Mox.expect(Tore.MockLLM, :web_search, fn "sys", "user", opts ->
      assert opts == []
      {:ok, %{"candidates" => []}, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0.0}}
    end)

    assert {:ok, %{"candidates" => []}, _usage} =
             Tore.LLM.web_search(home_scope(), "sys", "user", [])

    Mox.verify!(Tore.MockLLM)
  end
end
