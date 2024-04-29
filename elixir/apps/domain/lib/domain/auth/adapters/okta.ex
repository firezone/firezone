defmodule Domain.Auth.Adapters.Okta do
  use Supervisor
  alias Domain.Repo
  alias Domain.Actors
  alias Domain.Auth.{Provider, Adapter}
  alias Domain.Auth.Adapters.OpenIDConnect
  alias Domain.Auth.Adapters.Okta
  alias Domain.Auth.Adapters.Okta.{IdentityState, ProviderConfig, ProviderState}
  require Logger

  @behaviour Adapter
  @behaviour Adapter.IdP

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Okta.APIClient,
      # Background Jobs
      Okta.Jobs.RefreshAccessTokens,
      Okta.Jobs.SyncDirectory
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @impl true
  def capabilities do
    [
      provisioners: [:custom],
      default_provisioner: :custom,
      parent_adapter: :openid_connect
    ]
  end

  @impl true
  def identity_changeset(%Provider{} = _provider, %Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Repo.Changeset.trim_change(:provider_identifier)
    |> Domain.Repo.Changeset.copy_change(:provider_virtual_state, :provider_state)
    |> Ecto.Changeset.put_change(:provider_virtual_state, %{})
    |> Domain.Repo.Changeset.cast_polymorphic_embed(:provider_state,
      required: true,
      with: fn current_attrs, _attrs ->
        Ecto.embedded_load(IdentityState, current_attrs, :json)
      end
    )
  end

  @impl true
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Repo.Changeset.cast_polymorphic_embed(:adapter_config,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(ProviderConfig, current_attrs, :json)
        |> ProviderConfig.Changeset.changeset(attrs)
      end
    )
    |> Domain.Repo.Changeset.cast_polymorphic_embed(:adapter_state,
      with: fn current_attrs, _attrs ->
        Ecto.embedded_load(ProviderState, current_attrs, :json)
      end
    )
  end

  @impl true
  def ensure_provisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  @impl true
  def ensure_deprovisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  @impl true
  def sign_out(provider, identity, redirect_url) do
    provider = load(provider)
    OpenIDConnect.sign_out(provider, identity, redirect_url)
  end

  @impl true
  def verify_and_update_identity(%Provider{} = provider, payload) do
    provider = load(provider)
    OpenIDConnect.verify_and_update_identity(provider, payload)
  end

  def verify_and_upsert_identity(%Actors.Actor{} = actor, %Provider{} = provider, payload) do
    provider = load(provider)
    OpenIDConnect.verify_and_upsert_identity(actor, provider, payload)
  end

  def refresh_access_token(%Provider{} = provider) do
    provider = load(provider)
    OpenIDConnect.refresh_access_token(provider)
  end

  @impl true
  def load(%Provider{adapter_config: adapter_config, adapter_state: adapter_state} = provider) do
    %{
      provider
      | adapter_config: Repo.Changeset.load_polymorphic_embed(ProviderConfig, adapter_config),
        adapter_state: Repo.Changeset.load_polymorphic_embed(ProviderState, adapter_state)
    }
  end
end
