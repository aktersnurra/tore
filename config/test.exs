import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tore, Tore.Repo,
  database: Path.expand("../tore_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite has a single write lock. A modest busy_timeout lets a briefly-blocked
  # writer wait rather than immediately erroring. (Tests that write a shared,
  # un-isolated row — e.g. HouseholdTest — are additionally marked async: false,
  # since a write deadlock can't be resolved by waiting.)
  busy_timeout: 5_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tore, ToreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pfocKcuau3b5LoG8jNbG5PbtZjiesaLk7qgarj2Mb+Si90/pAFYcUWJezaObPEoQ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :tore, Tore.Mailer, adapter: Swoosh.Adapters.Test

config :tore, :uploads_dir, Path.expand("../tmp/uploads", __DIR__)

config :tore, :image_gen_client, Tore.Adapters.StubImageGen
config :tore, :http_client, Tore.MockHTTP
config :tore, :llm_spec, Tore.MockLLM
config :tore, :storage_client, Tore.Storage.Mock
config :tore, :env, :test
