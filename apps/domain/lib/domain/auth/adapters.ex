defmodule Domain.Auth.Adapters do
  use Supervisor
  alias Domain.Auth.{Provider, Identity}

  @adapters %{
    email: Domain.Auth.Adapters.Email
  }

  @adapter_names Map.keys(@adapters)
  @adapter_modules Map.values(@adapters)

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = @adapter_modules
    #  ++
    #   [
    #     {DynamicSupervisor, name: Domain.RefresherSupervisor, strategy: :one_for_one},
    #     Domain.Auth.OIDC.RefreshManager
    #   ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def identity_changeset(%Ecto.Changeset{} = changeset, %Provider{} = provider) do
    adapter = fetch_adapter!(provider)
    %Ecto.Changeset{} = adapter.identity_changeset(provider, changeset)
  end

  def ensure_provisioned(%Ecto.Changeset{changes: %{adapter: adapter}} = changeset)
      when adapter in @adapter_names do
    adapter = Map.fetch!(@adapters, adapter)
    %Ecto.Changeset{} = adapter.ensure_provisioned(changeset)
  end

  def ensure_provisioned(%Ecto.Changeset{} = changeset) do
    changeset
  end

  def ensure_deprovisioned(%Ecto.Changeset{data: %Provider{} = provider} = changeset) do
    adapter = fetch_adapter!(provider)
    %Ecto.Changeset{} = adapter.ensure_deprovisioned(changeset)
  end

  def verify_secret(%Provider{} = provider, %Identity{} = identity, secret) do
    adapter = fetch_adapter!(provider)

    case adapter.verify_secret(identity, secret) do
      {:ok, %Identity{} = identity} -> {:ok, identity}
      {:error, :invalid_secret} -> {:error, :invalid_secret}
      {:error, :expired_secret} -> {:error, :expired_secret}
    end
  end

  defp fetch_adapter!(provider) do
    Map.fetch!(@adapters, provider.adapter)
  end
end
