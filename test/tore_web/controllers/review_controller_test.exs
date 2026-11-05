defmodule ToreWeb.ReviewControllerTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.Accounts
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}

  setup do
    {:ok, {user, _code}} = Accounts.create_admin("Gustaf")
    household_id = Tore.Household.get_household!().id
    {:ok, pid} = Tore.Harness.ProjectorSupervisor.start_or_lookup(household_id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user, household_id: household_id}
  end

  defp open_pending_run(household_id, user_id, opened_at) do
    sid = Run.next_stream_id()

    {:ok, [opened]} =
      Run.decide(
        %Commands.Open{
          household_id: household_id,
          kind: "receipt_ingestion_run",
          surface: :plan,
          started_by: "user",
          user_id: user_id,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    opened = %{opened | opened_at: opened_at}
    running = Run.evolve(%State.Draft{stream_id: sid}, opened)
    {:ok, [raised]} = Run.decide(%Commands.RaiseQuestion{question: "Which store?"}, running)

    :ok = Run.append(sid, [opened, raised], %{household_id: household_id})
    sid
  end

  test "opens the oldest pending review and returns to Home", ctx do
    newer = open_pending_run(ctx.household_id, ctx.user.id, ~U[2026-11-05 10:00:00Z])
    older = open_pending_run(ctx.household_id, ctx.user.id, ~U[2026-11-04 10:00:00Z])
    assert older != newer
    Process.sleep(50)

    conn = get(ctx.conn, ~p"/review")

    assert redirected_to(conn) == ~p"/runs/#{older}?#{[from: "/"]}"
  end

  test "goes Home when nothing is waiting", %{conn: conn} do
    assert conn |> get(~p"/review") |> redirected_to() == ~p"/"
  end

  test "a review with no return path goes back to Home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/runs/kr_missing")
  end
end
