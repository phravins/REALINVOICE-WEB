defmodule RealinvoiceCloud.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TwMerge.Cache,
      RealinvoiceCloudWeb.Telemetry,
      RealinvoiceCloud.Repo,
      {DNSCluster, query: Application.get_env(:realinvoice_cloud, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RealinvoiceCloud.PubSub},
      # Start a worker by calling: RealinvoiceCloud.Worker.start_link(arg)
      # {RealinvoiceCloud.Worker, arg},
      # Start to serve requests, typically the last entry
      RealinvoiceCloudWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RealinvoiceCloud.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RealinvoiceCloudWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
