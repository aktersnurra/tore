defmodule Tore.Capture.QuickSwapsTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Capture.Router
  alias Tore.Home

  setup :verify_on_exit!

  @usage %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}

  defp turn(swaps) do
    expect(Tore.MockLLM, :chat_with_tools, 2, fn _sys, messages, tools, _opts ->
      assert Enum.any?(tools, &(&1.function.name == "quick_swaps"))

      case List.last(messages) do
        %{role: "tool", name: "quick_swaps", content: content} ->
          send(self(), {:tool_result, Jason.decode!(content)})
          {:ok, {:message, "Klart."}, @usage}

        _user ->
          call = %{id: "call_1", name: "quick_swaps", args: %{"swaps" => swaps}}
          {:ok, {:tool_calls, [call]}, @usage}
      end
    end)
  end

  test "a turn's swaps go to the person's chat bar and nowhere else" do
    user = user_fixture()
    Phoenix.PubSub.subscribe(Tore.PubSub, Home.swaps_topic(user.id))

    turn([
      %{"label" => "Inköpslistan", "screen" => "shop"},
      %{"label" => "Mer pasta", "prompt" => "Föreslå en pastarätt till"}
    ])

    assert {:ok, bubbles} =
             Router.route("vad blir det ikväll?", [], %{household_id: 1, user_id: user.id})

    assert_receive {:quick_swaps,
                    [
                      %{label: "Inköpslistan", action: {:open, :shop}},
                      %{label: "Mer pasta", action: {:prompt, "Föreslå en pastarätt till"}}
                    ]}

    assert_receive {:tool_result, %{"status" => "ok"}}
    assert Enum.map(bubbles, & &1.text) |> Enum.reject(&(&1 == "")) == ["Klart."]
  end

  test "invalid swaps go back to the model and reach no bar" do
    user = user_fixture()
    Phoenix.PubSub.subscribe(Tore.PubSub, Home.swaps_topic(user.id))
    turn([%{"label" => "Admin", "screen" => "settings/users"}])

    assert {:ok, bubbles} = Router.route("hej", [], %{household_id: 1, user_id: user.id})

    assert_receive {:tool_result, %{"status" => "rejected", "message" => message}}
    assert message =~ "screen"
    refute_received {:quick_swaps, _}
    refute Enum.any?(bubbles, &(&1.text =~ "Tool failed"))
  end

  describe "Home.suggested_swaps/1" do
    test "takes at most three, each opening a listed screen or sending one line" do
      assert {:ok, [%{label: "Plan", action: {:open, :plan}}]} =
               Home.suggested_swaps([%{"label" => " Plan ", "screen" => "plan"}])

      for bad <- [
            [%{"label" => "x", "screen" => "plan"}] |> List.duplicate(4) |> List.flatten(),
            [%{"label" => String.duplicate("a", 25), "screen" => "plan"}],
            [%{"label" => "", "screen" => "plan"}],
            [%{"label" => "x", "screen" => "nowhere"}],
            [%{"label" => "x", "prompt" => "two\nlines"}],
            [%{"label" => "x", "screen" => "plan", "prompt" => "both"}],
            [%{"label" => "x"}],
            "not a list"
          ] do
        assert {:error, reason} = Home.suggested_swaps(bad)
        assert is_binary(reason)
      end
    end
  end
end
