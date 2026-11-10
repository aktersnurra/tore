# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tore,
  ecto_repos: [Tore.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :tore, ToreWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ToreWeb.ErrorHTML, json: ToreWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tore.PubSub,
  live_view: [signing_salt: "pmbdTG6E"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tore: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  tore: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Port injection — wire spec + transport adapter injected per environment.
# Contexts call `Tore.LLM` (the facade), which dispatches to `:llm_spec`.
config :tore, :llm_spec, Tore.LLM.OpenAI
config :tore, :http_client, Tore.Adapters.ReqHTTP

config :tore, :openrouter_site_url, "https://scullion.gustafrydholm.xyz"
config :tore, :openrouter_app_name, "Tore"

config :tore, Tore.Scheduler,
  jobs: [
    {"0 3 * * *", {Tore.Deals, :clear_expired, []}},
    {"0 4 * * 0", {Tore.Harness.InboxSweeper, :sweep_weekly, []}},
    {"0 6 * * 6", {Tore.Harness.Kinds.MemoryReview, :review_weekly, []}},
    {"0 8 * * 6", {Tore.Deals, :scrape_all, []}},
    {"0 18 * * 6", {Tore.Planning, :plan_upcoming_weeks, []}}
  ]

config :tore, Tore.Mailer, adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, false

config :ex_aws,
  access_key_id: {:system, "GARAGE_ACCESS_KEY_ID"},
  secret_access_key: {:system, "GARAGE_SECRET_ACCESS_KEY"},
  region: "garage"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 3900,
  path_style: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
