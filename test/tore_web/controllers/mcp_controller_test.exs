defmodule ToreWeb.McpControllerTest do
  use ToreWeb.ConnCase, async: false

  defmodule StubToken do
    @behaviour Tore.Mcp.Token
    @impl true
    def verify("valid:" <> sub), do: {:ok, sub}
    def verify(_), do: {:error, :invalid}
  end

  setup %{conn: conn} do
    previous = {Application.get_env(:tore, :mcp), Application.get_env(:tore, :mcp_token_module)}
    Application.put_env(:tore, :mcp, audience: "https://tore.example.test/mcp")
    Application.put_env(:tore, :mcp_token_module, StubToken)

    on_exit(fn ->
      {mcp, module} = previous
      restore(:mcp, mcp)
      restore(:mcp_token_module, module)
    end)

    user = user_fixture(name: "Tester")
    {:ok, conn: put_req_header(conn, "content-type", "application/json"), user: user}
  end

  defp restore(key, nil), do: Application.delete_env(:tore, key)
  defp restore(key, value), do: Application.put_env(:tore, key, value)

  defp as(conn, user), do: put_req_header(conn, "authorization", "Bearer valid:#{user.oidc_sub}")

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    post(
      conn,
      "/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    )
  end

  test "a signed-in client initializes and lists the tools", %{conn: conn, user: user} do
    body =
      conn
      |> as(user)
      |> rpc("initialize", %{"protocolVersion" => "2025-06-18"})
      |> json_response(200)

    assert body["result"]["protocolVersion"] == "2025-06-18"
    assert body["result"]["serverInfo"]["name"] == "tore"

    body =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> as(user)
      |> rpc("tools/list")
      |> json_response(200)

    assert is_list(body["result"]["tools"])
  end

  test "an unknown protocol version gets the newest", %{conn: conn, user: user} do
    body =
      conn
      |> as(user)
      |> rpc("initialize", %{"protocolVersion" => "1999-01-01"})
      |> json_response(200)

    assert body["result"]["protocolVersion"] == Tore.Mcp.latest_protocol_version()
  end

  test "a notification is accepted with no body", %{conn: conn, user: user} do
    conn =
      conn
      |> as(user)
      |> post(
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      )

    assert response(conn, 202) == ""
  end

  test "an unknown method, and a batch, are JSON-RPC errors", %{conn: conn, user: user} do
    body = conn |> as(user) |> rpc("sampling/createMessage") |> json_response(200)
    assert body["error"]["code"] == -32601

    body =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> as(user)
      |> post("/mcp", Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))
      |> json_response(200)

    assert body["error"]["code"] == -32600
  end

  test "no token, a bad one, or someone with no account gets a 401 that points at the metadata",
       %{conn: conn} do
    for auth <- [nil, "Bearer nope", "Bearer valid:nobody", "Basic abc"] do
      conn = if auth, do: put_req_header(conn, "authorization", auth), else: conn
      conn = rpc(conn, "ping")

      assert conn.status == 401, "let in #{inspect(auth)}"

      assert [header] = get_resp_header(conn, "www-authenticate")

      assert header =~
               ~s(resource_metadata="#{ToreWeb.Endpoint.url()}/.well-known/oauth-protected-resource")
    end
  end

  test "a call runs as the active household of the token's person", %{user: user} do
    conn = ToreWeb.McpAuth.call(build_conn() |> as(user), [])

    assert conn.assigns.current_scope == %Tore.Scope{
             household_id: home_scope().household_id,
             user_id: user.id
           }
  end

  test "GET and DELETE are not offered", %{conn: conn, user: user} do
    assert conn |> as(user) |> get("/mcp") |> response(405) == ""
  end

  test "the metadata names the resource and Pocket ID" do
    body = build_conn() |> get("/.well-known/oauth-protected-resource") |> json_response(200)

    assert body["resource"] == ToreWeb.Endpoint.url() <> "/mcp"
    assert body["authorization_servers"] == [Application.fetch_env!(:tore, :oidc)[:issuer]]
    assert build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)
  end

  test "with no audience configured, MCP is off", %{conn: conn, user: user} do
    Application.put_env(:tore, :mcp, [])

    assert conn |> as(user) |> rpc("ping") |> response(404)
    assert build_conn() |> get("/.well-known/oauth-protected-resource") |> response(404)
  end
end
