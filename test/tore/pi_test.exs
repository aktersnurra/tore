defmodule Tore.PiTest do
  use Tore.DataCase, async: false

  alias Tore.{Costs, Pi}
  alias Tore.Mcp.SessionToken

  import Tore.FakePi

  setup :fake_pi

  test "a prompt streams pi's events to the household's session topic", %{pi_log: log} do
    scope = home_scope()
    :ok = Pi.subscribe(scope, "chat")

    assert :ok = Pi.ask(scope, "chat", "Planera veckan")

    assert_receive {:pi, "chat", %{"type" => "message_update"} = update}, 5_000
    assert update["assistantMessageEvent"]["delta"] == "echo: Planera veckan"
    assert_receive {:pi, "chat", %{"type" => "agent_settled"}}, 5_000

    [header, prompt] = pi_records(log)

    assert %{
             "household" => household_id,
             "session" => "chat",
             "mcp_url" => "http://tore.test/mcp",
             "model" => "anthropic/claude-sonnet-5-5",
             "token" => token
           } = header

    assert household_id == scope.household_id
    assert {:ok, %Tore.Scope{household_id: ^household_id}} = SessionToken.verify(token)
    assert %{"type" => "prompt", "message" => "Planera veckan"} = prompt
    # What it cost counts against the household's limit.
    assert [{"pi_chat", 1, 0.01}] = Costs.llm_calls_this_month_by_feature(scope)
  end

  test "one household's session never hears another's" do
    mine = home_scope()
    theirs = scope_fixture(household_fixture())
    :ok = Pi.subscribe(theirs, "chat")

    assert :ok = Pi.ask(mine, "chat", "hej")
    refute_receive {:pi, _, _}, 500
  end

  test "a photo goes with the prompt", %{pi_log: log} do
    scope = home_scope()
    :ok = Pi.subscribe(scope, "receipt")

    assert :ok = Pi.ask(scope, "receipt", "Logga kvittot", images: [{"image/jpeg", "jpegbytes"}])
    assert_receive {:pi, "receipt", %{"type" => "agent_settled"}}, 5_000

    [_header, prompt] = pi_records(log)

    assert prompt["images"] == [
             %{
               "type" => "image",
               "mimeType" => "image/jpeg",
               "data" => Base.encode64("jpegbytes")
             }
           ]
  end

  test "run waits for the answer and ends the session" do
    System.put_env("FAKE_PI_REPLY", "Planerade sju middagar.")
    System.put_env("FAKE_PI_COST", "0.05")
    scope = home_scope()

    assert {:ok, %{text: "Planerade sju middagar.", cost_usd: 0.05}} =
             Pi.run(scope, "job-1", "Planera nästa vecka")

    assert GenServer.whereis(Tore.Pi.Session.via(scope, "job-1")) == nil
  end

  test "each of a person's chats is a session of its own, counted as chat" do
    scope = scope_fixture()
    {:ok, chat} = Tore.Chats.create(scope)
    session = Tore.Chats.session(chat)
    assert session == "chat-#{scope.user_id}-#{chat.id}"

    :ok = Pi.subscribe(scope, session)
    assert :ok = Pi.ask(scope, session, "hej")
    assert_receive {:pi, ^session, %{"type" => "agent_settled"}}, 5_000

    assert [{"pi_chat", 1, _}] = Costs.llm_calls_this_month_by_feature(scope)
  end

  test "messages is the conversation pi has kept, with what was said since" do
    earlier = [
      %{"role" => "user", "content" => [%{"type" => "text", "text" => "Vad blir det ikväll?"}]},
      %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "Tacos."}]}
    ]

    System.put_env("FAKE_PI_HISTORY", Jason.encode!(earlier))
    scope = home_scope()

    assert {:ok, ^earlier} = Pi.messages(scope, "chat-1")

    :ok = Pi.subscribe(scope, "chat-1")
    :ok = Pi.ask(scope, "chat-1", "Och imorgon?")
    assert_receive {:pi, "chat-1", %{"type" => "agent_settled"}}, 5_000

    assert {:ok, messages} = Pi.messages(scope, "chat-1")

    assert Enum.map(messages, &{&1["role"], Pi.assistant_text(&1)}) ==
             [
               {"user", "Vad blir det ikväll?"},
               {"assistant", "Tacos."},
               {"user", "Och imorgon?"},
               {"assistant", "echo: Och imorgon?"}
             ]
  end

  test "no session without a sponsor or with pi not configured" do
    unsponsored = scope_fixture(household_fixture())
    assert {:error, :ai_unavailable} = Pi.ask(unsponsored, "chat", "hej")

    Application.delete_env(:tore, :pi)
    assert {:error, :pi_off} = Pi.ask(home_scope(), "chat", "hej")
  end

  test "refusal_text names the household's refusals, also wrapped by a run, and nothing else" do
    Gettext.with_locale(ToreWeb.Gettext, "sv", fn ->
      assert Pi.refusal_text(:ai_unavailable) == "AI är avstängt för det här hushållet."
    end)

    assert Pi.refusal_text({:step_failed, :budget_exceeded}) == Pi.refusal_text(:budget_exceeded)
    assert is_binary(Pi.refusal_text(:budget_exceeded))
    assert Pi.refusal_text(:pi_off) == nil
    assert Pi.refusal_text(:timeout) == nil
  end

  test "a chat's token is its person's and names its session; a job's is the household's", %{
    pi_log: log
  } do
    user = user_fixture()
    person = %{home_scope() | user_id: user.id}

    :ok = Pi.ask(person, "chat-#{user.id}-1", "hej")
    :ok = Pi.ask(home_scope(), "plan_week-1", "plan")

    wait_for(fn -> length(Enum.filter(pi_records(log), &Map.has_key?(&1, "token"))) == 2 end)
    tokens = for %{"token" => t, "session" => s} <- pi_records(log), into: %{}, do: {s, t}

    assert {:ok, %Tore.Scope{user_id: user_id, pi_session: session}} =
             SessionToken.verify(tokens["chat-#{user.id}-1"])

    assert user_id == user.id
    # The chat tools (describe_chat, suggest_replies) find the chat by its session's name.
    assert session == "chat-#{user.id}-1"
    assert {:ok, %Tore.Scope{user_id: nil}} = SessionToken.verify(tokens["plan_week-1"])
  end

  test "small jobs run on the light model", %{pi_log: log} do
    :ok = Pi.ask(home_scope(), "home_pick-1", "pick")
    :ok = Pi.ask(home_scope(), "plan_week-1", "plan")

    wait_for(fn -> length(Enum.filter(pi_records(log), &Map.has_key?(&1, "model"))) == 2 end)
    models = for %{"model" => m, "session" => s} <- pi_records(log), into: %{}, do: {s, m}

    assert models == %{
             "home_pick-1" => "anthropic/claude-haiku-5-5",
             "plan_week-1" => "anthropic/claude-sonnet-5-5"
           }
  end

  test "what a run spent is counted when it stops before settling", %{pi_log: log} do
    hold_settle(log)

    assert {:error, :timeout} = Pi.run(home_scope(), "plan_week-1", "plan", timeout: 300)
    assert [{"pi_plan_week", 1, 0.01}] = Costs.llm_calls_this_month_by_feature(home_scope())
  end

  test "the chat's history shows when the household is over its budget" do
    {:ok, _} =
      Costs.log_llm_usage(home_scope(), %{feature: "seed", cost_usd: Pi.monthly_limit_usd()})

    assert {:ok, _messages} = Pi.messages(home_scope(), "chat")
  end
end
