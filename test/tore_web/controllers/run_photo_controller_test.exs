defmodule ToreWeb.RunPhotoControllerTest do
  use ToreWeb.ConnCase, async: false

  import Tore.RunFixtures

  alias Tore.Storage.Mock

  setup do
    Mock.reset()
    %{user: user_fixture()}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "serves the photo of a run in the household", %{conn: conn, user: user} do
    {sid, key} = run_with_photo_fixture(home_scope(), "receipt bytes")
    assert String.starts_with?(key, "households/#{home_scope().household_id}/#{sid}/")

    conn = get(authed(conn, user), ~p"/images/runs/#{sid}")

    assert conn.status == 200
    assert conn.resp_body == "receipt bytes"
  end

  test "another household's run photo is a 404", %{conn: conn, user: user} do
    {sid, _key} = run_with_photo_fixture(scope_fixture(household_fixture()))

    conn = get(authed(conn, user), ~p"/images/runs/#{sid}")

    assert conn.status == 404
  end
end
