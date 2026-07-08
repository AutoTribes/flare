defmodule Flare.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FlareWeb.Telemetry,
      Flare.Repo,
      {DNSCluster, query: Application.get_env(:flare, :dns_cluster_query) || :ignore},
      {Redix, {Application.fetch_env!(:flare, :redis_url), [name: :flare_redix]}},
      {Oban, Application.fetch_env!(:flare, Oban)},
      {Finch, name: Flare.Finch},
      {Phoenix.PubSub, name: Flare.PubSub},
      Flare.Sync.ConnectionRegistry,
      # Start a worker by calling: Flare.Worker.start_link(arg)
      # {Flare.Worker, arg},
      # Start to serve requests, typically the last entry
      FlareWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Flare.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FlareWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
