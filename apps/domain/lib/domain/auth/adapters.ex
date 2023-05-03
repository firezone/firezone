defmodule Domain.Auth.Adapters do
  use Supervisor
  alias Domain.Auth.Provider

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

  def identity_create_state(%Provider{} = provider) do
    adapter = fetch_adapter!(provider)
    adapter.identity_create_state(provider)
  end

  defp fetch_adapter!(provider) do
    Map.fetch!(@adapters, provider.adapter)
  end
end
