defmodule ToreWeb.HomeControllerTest do
  use ToreWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Tore.FakePi

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds

  setup :fake_pi

  setup do
    user = user_fixture(name: "Gustaf")
    %{conn: build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})}
  end

  test "opens the stored pick without asking pi", %{conn: conn, pi_log: log} do
    Phoenix.PubSub.subscribe(Tore.PubSub, Runs.topic(home_scope()))

    {:ok, %KitchenRun{id: stored}} =
      Runs.submit(
        home_scope(),
        Kinds.HomePick,
        %HomePick{screen: :shop, source: :model, swaps: []},
        %{}
      )

    # Fresh, but opened before refresh's ten-minute limit, so only the controller's check holds it.
    twenty_minutes_ago = DateTime.add(DateTime.utc_now(), -20, :minute)

    Tore.Repo.update_all(
      from(r in KitchenRun, where: r.id == ^stored),
      [set: [opened_at: twenty_minutes_ago, applied_at: twenty_minutes_ago]],
      household_id: 1
    )

    assert conn |> get(~p"/") |> redirected_to() == ~p"/shop"
    # A fresh pick starts no new one.
    assert pi_records(log) == []
  end

  test "without a pick, opens the fixed rule's screen and asks pi for one", %{
    conn: conn,
    pi_log: log
  } do
    opened = conn |> get(~p"/") |> redirected_to()
    assert opened in [~p"/today", ~p"/shop", ~p"/plan"]

    assert Enum.any?(
             pi_records(log),
             &(&1["type"] == "prompt" and &1["message"] =~ "Background job: home_pick.")
           )
  end

  test "a household that hasn't chosen its language goes to the welcome page first" do
    # Signs in with no pending membership, so they get a household of their own with no language.
    {:ok, user} =
      Tore.Accounts.sign_in(%{"sub" => "new-sub", "preferred_username" => "ny", "name" => "Ny"})

    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})

    assert conn |> get(~p"/") |> redirected_to() == ~p"/welcome"
  end
end
