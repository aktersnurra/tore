import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tore start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tore, ToreWeb.Endpoint, server: true
end

config :tore, ToreWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# The Pocket ID claim that lets someone use the server's LLM.
config :tore, :ai_claim, System.get_env("AI_CLAIM", "tore_ai")

if config_env() == :prod do
  config :tore,
         :uploads_dir,
         System.get_env("UPLOADS_DIR") ||
           raise("environment variable UPLOADS_DIR is missing. Example: /var/data/tore/uploads")

  config :tore, :openrouter_api_key, System.fetch_env!("OPENROUTER_API_KEY")

  config :tore,
         :openrouter_site_url,
         System.get_env("OPENROUTER_SITE_URL", "https://scullion.gustafrydholm.xyz")

  config :tore, :openrouter_app_name, System.get_env("OPENROUTER_APP_NAME", "Tore")
  config :tore, :openrouter_model, System.get_env("OPENROUTER_MODEL", "openai/gpt-5-mini")

  config :tore,
         :openrouter_vision_model,
         System.get_env("OPENROUTER_VISION_MODEL", "google/gemini-3.5-flash")

  config :tore,
         :openrouter_image_model,
         System.get_env("OPENROUTER_IMAGE_MODEL", "google/gemini-3.1-flash-image")

  config :tore,
         :openrouter_check_model,
         System.get_env("OPENROUTER_CHECK_MODEL", "openai/gpt-oss-120b:free")

  config :tore,
         :openrouter_check_model_fallback,
         System.get_env("OPENROUTER_CHECK_MODEL_FALLBACK", "openai/gpt-oss-120b")

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /var/lib/tore/tore.db
      """

  config :tore, Tore.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :tore, :oidc,
    issuer:
      System.get_env("OIDC_ISSUER") || raise("environment variable OIDC_ISSUER is missing."),
    client_id:
      System.get_env("OIDC_CLIENT_ID") || raise("environment variable OIDC_CLIENT_ID is missing."),
    client_secret:
      System.get_env("OIDC_CLIENT_SECRET") ||
        raise("environment variable OIDC_CLIENT_SECRET is missing."),
    redirect_uri: System.get_env("OIDC_REDIRECT_URI") || "https://#{host}/auth/oidc/callback"

  config :tore, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  case System.get_env("SMTP_RELAY") do
    nil ->
      :ok

    relay ->
      config :tore, Tore.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: relay,
        port: String.to_integer(System.get_env("SMTP_PORT", "25")),
        no_mx_lookups: true
  end

  config :ex_aws,
    access_key_id: System.fetch_env!("GARAGE_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("GARAGE_SECRET_ACCESS_KEY"),
    region: "garage"

  config :ex_aws, :s3,
    scheme: "http://",
    host: System.fetch_env!("GARAGE_HOST"),
    port: String.to_integer(System.get_env("GARAGE_PORT", "3900")),
    path_style: true

  config :tore, :storage_client, Tore.Storage.S3

  config :tore, ToreWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tore, ToreWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tore, ToreWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
