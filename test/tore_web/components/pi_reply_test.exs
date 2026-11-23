defmodule ToreWeb.PiReplyTest do
  use ToreWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "while Tore answers, the household's chef stirs a pot by the working line" do
    html = render_component(&ToreWeb.PiReply.pi_reply/1, working: "Tänker…", chef: :cook)

    assert html =~ ~s(data-role="pi-working")
    assert html =~ ~s(data-stage="cook")
    assert html =~ "data-stir"
    assert html =~ "Tänker…"
  end

  test "without a chef, the working line spins as before" do
    html = render_component(&ToreWeb.PiReply.pi_reply/1, working: "Tänker…")

    refute html =~ "data-stir"
    assert html =~ "ph-arrows-clockwise"
  end
end
