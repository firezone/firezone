defmodule Domain.Auth.Adapters do
  use Supervisor
  alias Domain.Auth.{Provider, Identity}

  @adapters %{
    email: Domain.Auth.Adapters.Email
  }

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Domain.Auth.SAML.StartProxy,
      {DynamicSupervisor, name: Domain.RefresherSupervisor, strategy: :one_for_one},
      Domain.Auth.OIDC.RefreshManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def ensure_provisioned(%Provider{} = provider) do
    adapter = fetch_adapter!(provider)
    adapter.ensure_provisioned(provider)
  end

  def ensure_deprovisioned(%Provider{} = provider) do
    adapter = fetch_adapter!(provider)
    adapter.ensure_deprovisioned(provider)
  end

  def identity_create_state(%Provider{} = provider) do
    adapter = fetch_adapter!(provider)
    adapter.identity_create_state(provider)
  end

  def verify_secret(%Provider{} = provider, %Identity{} = identity, secret) do
    adapter = fetch_adapter!(provider)
    adapter.verify_secret(identity, secret)
  end

  defp fetch_adapter!(provider) do
    Map.fetch!(@adapters, provider.adapter)
  end
end
