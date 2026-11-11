defmodule ToreWeb.PrepLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = user_fixture(name: "Gustaf")

    {:ok, _guide} =
      Tore.Prep.save_guide(home_scope(), %{
        week_start: Tore.Streams.monday(Tore.Clock.today()),
        timeline: [
          %{"task" => "Koka riset", "detail" => "Ris till tre middagar", "duration_min" => 20},
          %{"task" => "Rosta grönsakerna", "detail" => nil, "duration_min" => 35}
        ]
      })

    %{conn: Plug.Test.init_test_session(conn, %{user_id: user.id})}
  end

  test "the timeline can be followed one card at a time", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/prep")
    refute html =~ ~s(id="prep-steps")

    html = view |> element(~s([data-role="start-prep"])) |> render_click()
    assert html =~ ~s(id="prep-steps")
    assert html =~ "1 av 2"
    assert html =~ "Ris till tre middagar"
    assert html =~ "20 min"

    html = view |> element(~s([data-role="step-card"])) |> render_click()
    assert html =~ "2 av 2"
    assert html =~ "Klar"
  end

  test "all the steps are one tap away", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prep")
    view |> element(~s([data-role="start-prep"])) |> render_click()

    render_click(view, "toggle_overview")
    assert has_element?(view, "#prep-steps-overview", "Rosta grönsakerna")

    view |> element(~s(#prep-steps-overview button[phx-value-to="1"])) |> render_click()
    assert render(view) =~ "2 av 2"
  end
end
