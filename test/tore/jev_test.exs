defmodule Tore.JevTest do
  use ExUnit.Case, async: true

  alias Tore.Jev

  defp req, do: Req.new(plug: {Req.Test, __MODULE__})

  test "asks the Decisions API about a state, and answers with what it said and cost" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/alpha/decisions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "model" => "typesafe/jev-1.14",
               "state" => ["Äter inte fläsk."],
               "questions" => %{"deal_1" => %{"type" => "noul"}}
             } = Jason.decode!(body)

      Req.Test.json(conn, %{
        "answers" => %{"deal_1" => %{"noul" => 0.82}},
        "usage" => %{"cost" => 0.00004}
      })
    end)

    assert {:ok, %{"deal_1" => %{"noul" => 0.82}}, 0.00004} =
             Jev.decide(
               ["Äter inte fläsk."],
               %{"deal_1" => %{"type" => "noul", "instructions" => "Köper de lax?"}},
               req: req(),
               api_key: "test-key"
             )
  end

  test "without a key it asks nothing" do
    assert {:error, :no_key} = Jev.decide(["x"], %{}, api_key: nil, req: req())
  end

  test "an answer without answers is an error" do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 502, "bad gateway"))
    assert {:error, _} = Jev.decide(["x"], %{}, api_key: "test-key", req: req())
  end
end
