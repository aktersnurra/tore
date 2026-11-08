defmodule Tore.LLM.ChatTest do
  use Tore.DataCase, async: false
  import Mox

  setup :verify_on_exit!

  test "chat/3 returns string reply via MockLLM" do
    Tore.MockLLM
    |> expect(:chat, fn system, messages, _opts ->
      assert is_binary(system)
      assert [%{"role" => "user", "content" => "What can I cook tonight?"}] = messages
      {:ok, "Try pasta!", %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.0001}}
    end)

    assert {:ok, "Try pasta!", _usage} =
             Tore.LLM.chat(home_scope(), "You are a cooking assistant.", [
               %{"role" => "user", "content" => "What can I cook tonight?"}
             ])
  end

  test "chat/3 propagates errors" do
    Tore.MockLLM
    |> expect(:chat, fn _system, _messages, _opts -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} =
             Tore.LLM.chat(home_scope(), "system", [%{"role" => "user", "content" => "hello"}])
  end
end
