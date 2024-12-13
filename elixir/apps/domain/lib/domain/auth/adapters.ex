defmodule Domain.Auth.Adapters do
  use Supervisor
  alias Domain.Auth.{Provider, Identity, Context}

  @adapters %{
    email: Domain.Auth.Adapters.Email,
    openid_connect: Domain.Auth.Adapters.OpenIDConnect,
    google_workspace: Domain.Auth.Adapters.GoogleWorkspace,
    microsoft_entra: Domain.Auth.Adapters.MicrosoftEntra,
    okta: Domain.Auth.Adapters.Okta,
    jumpcloud: Domain.Auth.Adapters.JumpCloud,
    userpass: Domain.Auth.Adapters.UserPass
  }

  @adapter_names Map.keys(@adapters)
  @adapter_modules Map.values(@adapters)

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    Supervisor.init(@adapter_modules, strategy: :one_for_one)
  end

  def list_all_adapters! do
    Map.keys(@adapters)
  end

  def list_user_provisioned_adapters! do
    enabled_adapters = Domain.Config.compile_config!(:auth_provider_adapters)
    enabled_idp_adapters = enabled_adapters -- ~w[email userpass]a
    Map.take(@adapters, enabled_idp_adapters)
  end

  def fetch_capabilities!(%Provider{} = provider) do
    adapter = fetch_provider_adapter!(provider)
    adapter.capabilities()
  end

  def fetch_capabilities!(adapter) when is_atom(adapter) do
    fetch_adapter!(adapter).capabilities()
  end

  def identity_changeset(%Ecto.Changeset{} = changeset, %Provider{} = provider) do
    adapter = fetch_provider_adapter!(provider)
    %Ecto.Changeset{} = adapter.identity_changeset(provider, changeset)
  end

  def provider_changeset(%Ecto.Changeset{changes: %{adapter: adapter}} = changeset)
      when adapter in @adapter_names do
    adapter = Map.fetch!(@adapters, adapter)
    %Ecto.Changeset{} = adapter.provider_changeset(changeset)
  end

  def provider_changeset(%Ecto.Changeset{data: %{adapter: adapter}} = changeset)
      when adapter in @adapter_names do
    adapter = Map.fetch!(@adapters, adapter)
    %Ecto.Changeset{} = adapter.provider_changeset(changeset)
  end

  def provider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
  end

  def ensure_provisioned(%Provider{} = provider) do
    adapter = fetch_provider_adapter!(provider)

    case adapter.ensure_provisioned(provider) do
      {:ok, provider} -> {:ok, provider}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  def ensure_deprovisioned(%Provider{} = provider) do
    adapter = fetch_provider_adapter!(provider)

    case adapter.ensure_deprovisioned(provider) do
      {:ok, provider} -> {:ok, provider}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  def sign_out(%Provider{} = provider, %Identity{} = identity, redirect_url) do
    adapter = fetch_provider_adapter!(provider)
    adapter.sign_out(provider, identity, redirect_url)
  end

  def verify_secret(%Provider{} = provider, %Identity{} = identity, %Context{} = context, secret) do
    adapter = fetch_provider_adapter!(provider)

    case adapter.verify_secret(identity, context, secret) do
      {:ok, %Identity{} = identity, expires_at} -> {:ok, identity, expires_at}
      {:error, :invalid_secret} -> {:error, :invalid_secret}
      {:error, :expired_secret} -> {:error, :expired_secret}
      {:error, :internal_error} -> {:error, :internal_error}
    end
  end

  def verify_and_update_identity(%Provider{} = provider, payload) do
    adapter = fetch_provider_adapter!(provider)

    case adapter.verify_and_update_identity(provider, payload) do
      {:ok, %Identity{} = identity, expires_at} ->
        {:ok, identity, expires_at}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid} ->
        {:error, :invalid}

      {:error, :expired} ->
        {:error, :expired}

      {:error, :internal_error} ->
        {:error, :internal_error}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def refresh_access_token(%Provider{} = provider, %Identity{} = identity) do
    adapter = fetch_provider_adapter!(provider)
    capabilities = adapter.capabilities()

    if Keyword.get(capabilities, :parent_adapter) == :openid_connect do
      adapter.refresh_access_token(%{identity | provider: provider})
    else
      {:error, :not_supported}
    end
  end

  defp fetch_provider_adapter!(%Provider{} = provider) do
    Map.fetch!(@adapters, provider.adapter)
  end

  defp fetch_adapter!(adapter_name) do
    Map.fetch!(@adapters, adapter_name)
  end
end
