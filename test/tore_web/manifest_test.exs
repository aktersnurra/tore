defmodule ToreWeb.ManifestTest do
  use ToreWeb.ConnCase, async: true

  test "the app manifest offers Tore in the share sheet, opening Recipes with the link", %{
    conn: conn
  } do
    conn = get(conn, "/manifest.webmanifest")

    assert conn.status == 200
    manifest = Jason.decode!(conn.resp_body)

    assert %{
             "action" => "/recipes",
             "method" => "GET",
             "params" => %{"url" => "url", "text" => "text"}
           } =
             manifest["share_target"]
  end
end
