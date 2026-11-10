defmodule ToreWeb.HomeControllerTest do
  use ToreWeb.ConnCase, async: false

  import Mox

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    user = user_fixture(name: "Gustaf")
    %{conn: build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})}
  end

  test "opens the stored pick without a model call", %{conn: conn} do
    {:ok, _} =
      Runs.submit(
        home_scope(),
        Kinds.HomePick,
        %HomePick{screen: :shop, source: :model, swaps: []},
        %{}
      )

    assert conn |> get(~p"/") |> redirected_to() == ~p"/shop"
  end

  test "without a pick, opens the fixed rule's screen and starts one in the background", %{
    conn: conn
  } do
    Phoenix.PubSub.subscribe(Tore.PubSub, Runs.topic(home_scope()))

    expect(Tore.MockLLM, :decide, fn _state, _questions, _opts ->
      {:ok, %{"screen" => %{"choice" => "plan", "confidence" => 0.9}},
       %{prompt_tokens: 1, completion_tokens: 0, cost_usd: 0.0}}
    end)

    opened = conn |> get(~p"/") |> redirected_to()
    assert opened in [~p"/today", ~p"/shop", ~p"/plan"]
    assert_receive {:run_changed, %KitchenRun{kind: "home_pick_run", status: :applied}}, 2000
  end

  test "a household that hasn't chosen its language goes to the welcome page first" do
    # Signs in with no pending membership, so they get a household of their own with no language.
    {:ok, user} =
      Tore.Accounts.sign_in(%{"sub" => "new-sub", "preferred_username" => "ny", "name" => "Ny"})

    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})

    assert conn |> get(~p"/") |> redirected_to() == ~p"/welcome"
  end
end
