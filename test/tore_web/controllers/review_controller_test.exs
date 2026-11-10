defmodule ToreWeb.ReviewControllerTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Tore.RunFixtures

  setup do
    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  test "opens the oldest pending review and returns to Home", ctx do
    pending_review_fixture(home_scope(), ~U[2026-11-05 10:00:00Z])
    %{id: older} = pending_review_fixture(home_scope(), ~U[2026-11-04 10:00:00Z])

    conn = get(ctx.conn, ~p"/review")

    assert redirected_to(conn) == ~p"/runs/#{older}?#{[from: "/"]}"
  end

  test "a question has nothing to review", ctx do
    pending_question_fixture(home_scope())
    assert ctx.conn |> get(~p"/review") |> redirected_to() == ~p"/"
  end

  test "goes Home when nothing is waiting", %{conn: conn} do
    assert conn |> get(~p"/review") |> redirected_to() == ~p"/"
  end

  test "a review with no return path goes back to Home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/runs/kr_missing")
  end
end
