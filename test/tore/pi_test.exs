defmodule Tore.PiTest do
  use Tore.DataCase, async: false

  alias Tore.{Costs, Pi}
  alias Tore.Mcp.SessionToken

  @fake Path.expand("../support/bin/fake-pi", __DIR__)

  setup do
    log = Path.join(System.tmp_dir!(), "fake-pi-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:tore, :pi)

    Application.put_env(:tore, :pi,
      command: [@fake],
      mcp_url: "http://tore.test/mcp",
      model: "anthropic/claude-sonnet-5-5"
    )

    System.put_env("FAKE_PI_LOG", log)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tore, :pi, previous),
        else: Application.delete_env(:tore, :pi)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Tore.Pi.Sessions),
          do: DynamicSupervisor.terminate_child(Tore.Pi.Sessions, pid)

      for var <- ~w(FAKE_PI_LOG FAKE_PI_REPLY FAKE_PI_COST), do: System.delete_env(var)
      File.rm(log)
    end)

    %{log: log}
  end

  defp records(log),
    do: log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "a prompt streams pi's events to the household's session topic", %{log: log} do
    scope = home_scope()
    :ok = Pi.subscribe(scope, "chat")

    assert :ok = Pi.ask(scope, "chat", "Planera veckan")

    assert_receive {:pi, "chat", %{"type" => "message_update"} = update}, 5_000
    assert update["assistantMessageEvent"]["delta"] == "echo: Planera veckan"
    assert_receive {:pi, "chat", %{"type" => "agent_settled"}}, 5_000

    [header, prompt] = records(log)

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

  test "a photo goes with the prompt", %{log: log} do
    scope = home_scope()
    :ok = Pi.subscribe(scope, "receipt")

    assert :ok = Pi.ask(scope, "receipt", "Logga kvittot", images: [{"image/jpeg", "jpegbytes"}])
    assert_receive {:pi, "receipt", %{"type" => "agent_settled"}}, 5_000

    [_header, prompt] = records(log)

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

  test "no session without a sponsor or with pi not configured" do
    unsponsored = scope_fixture(household_fixture())
    assert {:error, :ai_unavailable} = Pi.ask(unsponsored, "chat", "hej")

    Application.delete_env(:tore, :pi)
    assert {:error, :pi_off} = Pi.ask(home_scope(), "chat", "hej")
  end
end
