defmodule Domain.Auth.Adapters do
  use Supervisor
  alias Domain.Accounts
  alias Domain.Auth.{Provider, Identity}

  @adapters %{
    email: Domain.Auth.Adapters.Email,
    openid_connect: Domain.Auth.Adapters.OpenIDConnect,
    google_workspace: Domain.Auth.Adapters.GoogleWorkspace,
    userpass: Domain.Auth.Adapters.UserPass,
    token: Domain.Auth.Adapters.Token
  }

  @adapter_names Map.keys(@adapters)
  @adapter_modules Map.values(@adapters)

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Supervisor.init(@adapter_modules, strategy: :one_for_one)
  end

  def identity_changeset(%Ecto.Changeset{} = changeset, %Provider{} = provider, provider_attrs) do
    adapter = fetch_adapter!(provider)
    changeset = Ecto.Changeset.put_change(changeset, :provider_virtual_state, provider_attrs)
    %Ecto.Changeset{} = adapter.identity_changeset(provider, changeset)
  end

  def ensure_provisioned_for_account(
        %Ecto.Changeset{changes: %{adapter: adapter}} = changeset,
        %Accounts.Account{} = account
      )
      when adapter in @adapter_names do
    adapter = Map.fetch!(@adapters, adapter)
    %Ecto.Changeset{} = adapter.ensure_provisioned_for_account(changeset, account)
  end

  def ensure_provisioned_for_account(%Ecto.Changeset{} = changeset, %Accounts.Account{}) do
    changeset
  end

  def ensure_deprovisioned(%Ecto.Changeset{data: %Provider{} = provider} = changeset) do
    adapter = fetch_adapter!(provider)
    %Ecto.Changeset{} = adapter.ensure_deprovisioned(changeset)
  end

  def verify_secret(%Provider{} = provider, %Identity{} = identity, secret) do
    adapter = fetch_adapter!(provider)

    case adapter.verify_secret(identity, secret) do
      {:ok, %Identity{} = identity, expires_at} -> {:ok, identity, expires_at}
      {:error, :invalid_secret} -> {:error, :invalid_secret}
      {:error, :expired_secret} -> {:error, :expired_secret}
      {:error, :internal_error} -> {:error, :internal_error}
    end
  end

  def verify_identity(%Provider{} = provider, payload) do
    adapter = fetch_adapter!(provider)

    case adapter.verify_identity(provider, payload) do
      {:ok, %Identity{} = identity, expires_at} -> {:ok, identity, expires_at}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :invalid} -> {:error, :invalid}
      {:error, :expired} -> {:error, :expired}
      {:error, :internal_error} -> {:error, :internal_error}
    end
  end

  defp fetch_adapter!(provider) do
    Map.fetch!(@adapters, provider.adapter)
  end
end
