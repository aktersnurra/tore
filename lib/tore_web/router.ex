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

  pipeline :api do
    plug :accepts, ["json"]
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
    get "/images/runs/:stream_id", RunPhotoController, :show
    get "/review", ReviewController, :next

    live_session :authenticated,
      on_mount: [{ToreWeb.Live.Auth, :require_authenticated}] do
      live "/", HomeLive
      live "/plan", PlannerLive
      live "/recipes", RecipeLive
      live "/shop", ShopLive
      live "/prep", PrepLive
      live "/cooking", CookingLive
      live "/settings", SettingsLive
      live "/settings/pantry", PantryLive
      live "/settings/costs", CostLive
      live "/capture", CaptureLive
      live "/runs/:stream_id", RunReviewLive
    end
  end
end
