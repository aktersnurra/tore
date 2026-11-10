defmodule Tore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ToreWeb.Telemetry,
        Tore.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:tore, :ecto_repos), skip: skip_migrations?()},
        # Runs live in the process that started them, so any still running at boot are dead.
        # Swept once here, before anything can open a run; off in test, where the sandbox owns
        # the connection.
        Tore.Harness.Runs,
        {DNSCluster, query: Application.get_env(:tore, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Tore.PubSub},
        Tore.Scheduler,
        {Task.Supervisor, name: Tore.TaskSupervisor}
      ] ++
        oidc_children() ++
        [
          # Start to serve requests, typically the last entry
          ToreWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tore.Supervisor]
    result = Supervisor.start_link(children, opts)

    if Application.get_env(:tore, :env, :prod) == :dev do
      Task.start(fn ->
        Process.sleep(500)
        Tore.Storage.S3.ensure_buckets_exist()
      end)
    end

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ToreWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Discovery against Pocket ID, started before the endpoint so sign-in works once requests
  # arrive. Skipped when sign-in isn't configured, so a dev machine without it still boots, and
  # in test. With the default backoff the worker exits on a failed fetch, and a Pocket ID that
  # is down at boot would restart it past the supervisor's limit and stop Tore.
  defp oidc_children do
    if Application.get_env(:tore, :oidc_start_worker, true) and Tore.Auth.Oidc.configured?() do
      [
        {Oidcc.ProviderConfiguration.Worker,
         %{
           issuer: Application.fetch_env!(:tore, :oidc)[:issuer],
           name: Tore.Auth.Oidc.provider_name(),
           backoff_type: :random_exponential,
           backoff_min: 1_000,
           backoff_max: 60_000
         }}
      ]
    else
      []
    end
  end
end
