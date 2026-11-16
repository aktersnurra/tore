defmodule Tore.Mcp.TokenTest do
  use ExUnit.Case, async: true

  alias Tore.Mcp.Token

  @issuer "https://id.example.test"
  @audience "https://tore.example.test/mcp"

  setup do
    key = JOSE.JWK.generate_key({:ec, "P-256"}) |> JOSE.JWK.merge(%{"kid" => "k1"})
    {:ok, key: key, context: context(key)}
  end

  defp context(key) do
    configuration = %Oidcc.ProviderConfiguration{
      issuer: @issuer,
      id_token_signing_alg_values_supported: ["ES256"]
    }

    Oidcc.ClientContext.from_manual(
      configuration,
      JOSE.JWK.to_public(key),
      @audience,
      :unauthenticated
    )
  end

  defp sign(key, overrides \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "sub" => "user-1",
          "aud" => @audience,
          "iat" => now,
          "exp" => now + 300
        },
        overrides
      )
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    {_, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "k1"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  test "a token Pocket ID issued for the MCP audience yields its subject", ctx do
    assert Token.validate(sign(ctx.key), ctx.context) == {:ok, "user-1"}
  end

  test "a token that also names the issuer, as Pocket ID adds for /userinfo, is accepted",
       ctx do
    token = sign(ctx.key, %{"aud" => [@audience, @issuer]})
    assert Token.validate(token, ctx.context) == {:ok, "user-1"}
  end

  test "a token for another app, another issuer, or past its expiry is refused", ctx do
    for overrides <- [
          %{"aud" => "burpee-claude"},
          %{"aud" => [@audience, "burpee-claude"]},
          %{"aud" => [@audience, @issuer, "burpee-claude"]},
          %{"aud" => @issuer},
          %{"iss" => "https://elsewhere.test"},
          %{"exp" => System.system_time(:second) - 60},
          %{"sub" => nil},
          %{"sub" => ""}
        ] do
      assert {:error, _} = Token.validate(sign(ctx.key, overrides), ctx.context),
             "accepted #{inspect(overrides)}"
    end
  end

  test "a token signed by another key is refused", ctx do
    other = JOSE.JWK.generate_key({:ec, "P-256"}) |> JOSE.JWK.merge(%{"kid" => "k1"})
    assert {:error, _} = Token.validate(sign(other), ctx.context)
  end

  test "anything that is not a JWT is refused", ctx do
    for token <- ["", "not-a-jwt", "a.b.c"] do
      assert {:error, _} = Token.validate(token, ctx.context)
    end
  end

  test "MCP is off until an audience is configured" do
    refute Token.enabled?([])
    refute Token.enabled?(audience: "")
    assert Token.enabled?(audience: @audience)
  end
end
