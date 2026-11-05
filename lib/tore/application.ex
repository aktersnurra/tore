defmodule Tore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ToreWeb.Telemetry,
      Tore.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:tore, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:tore, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tore.PubSub},
      Tore.Harness.ProjectorRegistry,
      Tore.Harness.ProjectorSupervisor,
      Tore.Accounts.RateLimiter,
      Tore.Accounts.LoginToken,
      Tore.Scheduler,
      {Task.Supervisor, name: Tore.TaskSupervisor},
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
end
