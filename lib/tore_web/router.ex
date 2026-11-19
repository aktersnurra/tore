defmodule ToreWeb.Router do
  use ToreWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ToreWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ToreWeb.Plugs.Locale
  end

  pipeline :require_auth do
    plug ToreWeb.Plugs.Auth
  end

  # Public routes — no authentication required
  scope "/", ToreWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    get "/auth/oidc", OidcController, :request
    get "/auth/oidc/callback", OidcController, :callback
    delete "/logout", SessionController, :delete
  end

  # MCP for someone's own Claude: Pocket ID signs them in, Tore checks the token (.docs/specs/mcp.md).
  pipeline :mcp_metadata do
    plug :accepts, ["json"]
  end

  scope "/.well-known", ToreWeb do
    pipe_through :mcp_metadata

    get "/oauth-protected-resource", McpMetadataController, :show
    get "/oauth-protected-resource/mcp", McpMetadataController, :show
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug ToreWeb.McpAuth
  end

  scope "/mcp", ToreWeb do
    pipe_through :mcp

    post "/", McpController, :create
    get "/", McpController, :unsupported
    delete "/", McpController, :unsupported
  end

  if Application.compile_env(:tore, :dev_routes) do
    scope "/dev", ToreWeb do
      pipe_through :browser

      get "/login", DevSessionController, :create
    end
  end

  # Authenticated users
  scope "/", ToreWeb do
    pipe_through [:browser, :require_auth]

    get "/images/recipes/:id", RecipeImageController, :show
    get "/", HomeController, :show

    live_session :welcome, on_mount: [{ToreWeb.Live.Auth, :require_authenticated}] do
      live "/welcome", WelcomeLive
    end

    live_session :authenticated,
      on_mount: [
        {ToreWeb.Live.Auth, :require_authenticated},
        {ToreWeb.Live.Auth, :require_language}
      ] do
      live "/today", HomeLive
      live "/plan", PlannerLive
      live "/recipes", RecipeLive
      live "/recipes/:id/cook", CookLive
      live "/shop", ShopLive
      live "/pantry", PantryLive
      live "/prep", PrepLive
      live "/settings", SettingsLive
      live "/capture", CaptureLive
    end
  end
end
