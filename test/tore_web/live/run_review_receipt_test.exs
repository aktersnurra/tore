defmodule ToreWeb.RunReviewReceiptTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Tore.RunFixtures

  alias Tore.Harness.{KitchenRun, Runs}

  setup do
    user = user_fixture(name: "Tester")
    conn = Plug.Test.init_test_session(build_conn(), %{user_id: user.id})
    %{conn: conn, scope: scope_fixture(user), user: user}
  end

  defp await_run_tasks do
    for pid <- Task.Supervisor.children(Tore.TaskSupervisor) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> :timeout
      end
    end
  end

  test "says the lines don't add up and asks only for store, date and total", ctx do
    run = pending_review_fixture(ctx.scope)

    {:ok, _view, html} = live(ctx.conn, ~p"/runs/#{run.id}")

    assert html =~ "Raderna blir 20, men totalen säger 100"
    assert html =~ ~s(name="receipt[total]")
    refute html =~ "receipt[line_items]"
  end

  test "saving the corrected total logs the receipt", ctx do
    run = pending_review_fixture(ctx.scope)
    {:ok, view, _html} = live(ctx.conn, ~p"/runs/#{run.id}")

    view |> element(~s(form[phx-submit="confirm"])) |> render_change(%{receipt: %{total: "20"}})
    view |> element(~s(form[phx-submit="confirm"])) |> render_submit()
    await_run_tasks()

    assert %KitchenRun{status: :applied} = Runs.get(ctx.scope, run.id)
    assert [%{store_name: "ICA", total_amount: total}] = Tore.Costs.recent_receipts(ctx.scope, 5)
    assert Decimal.equal?(total, 20)
  end

  test "a total the verifier refuses leaves the run waiting", ctx do
    run = pending_review_fixture(ctx.scope)
    {:ok, view, _html} = live(ctx.conn, ~p"/runs/#{run.id}")
    Phoenix.PubSub.subscribe(Tore.PubSub, "toasts:user:#{ctx.user.id}")

    view
    |> element(~s(form[phx-submit="confirm"]))
    |> render_change(%{receipt: %{store_name: " "}})

    view |> element(~s(form[phx-submit="confirm"])) |> render_submit()
    await_run_tasks()

    assert_receive {:toast, :error, "Kvittot saknar butik."}
    assert %KitchenRun{status: :needs_user} = Runs.get(ctx.scope, run.id)
    assert Tore.Costs.recent_receipts(ctx.scope, 5) == []
  end

  test "an undone run says so", ctx do
    run = pending_review_fixture(ctx.scope)
    {:ok, _} = Runs.confirm(ctx.scope, run.id, hd(run.artifacts))
    {:ok, _} = Runs.revert(ctx.scope, run.id)

    {:ok, _view, html} = live(ctx.conn, ~p"/runs/#{run.id}")
    assert html =~ "Det här ångrades."
  end
end
