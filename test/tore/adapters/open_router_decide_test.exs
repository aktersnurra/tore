defmodule Tore.LLM.OpenAIDecideTest do
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

  @questions %{
    "screen" => %{
      "type" => "choice",
      "instructions" => "Which screen?",
      "criteria" => %{"shop" => "The list", "plan" => "The plan"}
    }
  }

  test "posts model, state and questions to the Decisions API and returns the answers", %{
    req: req
  } do
    stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/alpha/decisions"
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["https://tore.test"] = Plug.Conn.get_req_header(conn, "http-referer")

      assert %{
               "model" => "typesafe/jev-1.14",
               "state" => ["Saturday morning", "Five items left on the list"],
               "questions" => @questions
             } == raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "answers" => %{
          "screen" => %{
            "type" => "choice",
            "choice" => "shop",
            "probabilities" => %{"shop" => 0.9, "plan" => 0.1},
            "confidence" => 0.8
          }
        },
        "usage" => %{"input_tokens" => 120, "output_tokens" => 0, "cost" => 0.000005}
      })
    end)

    assert {:ok, %{"screen" => %{"choice" => "shop", "confidence" => 0.8}},
            %{prompt_tokens: 120, completion_tokens: 0, cost_usd: 0.000005}} =
             OpenAI.decide(["Saturday morning", "Five items left on the list"], @questions,
               req: req
             )
  end

  test "an error status comes back as an error", %{req: req} do
    stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => %{"message" => "bad"}})
    end)

    assert {:error, %OpenRouter.Error{status: 400}} =
             OpenAI.decide(["state"], @questions, req: req)
  end

  test "a body without answers is refused", %{req: req} do
    stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"usage" => %{}}) end)

    assert {:error, :invalid_decision} = OpenAI.decide(["state"], @questions, req: req)
  end
end
