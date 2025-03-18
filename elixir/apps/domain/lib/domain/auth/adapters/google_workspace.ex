defmodule Domain.Auth.Adapters.GoogleWorkspace do
  use Supervisor
  alias Domain.Actors
  alias Domain.Auth.{Provider, Adapter, Identity}
  alias Domain.Auth.Adapters.OpenIDConnect
  alias Domain.Auth.Adapters.GoogleWorkspace
  alias Domain.Auth.Adapters.GoogleWorkspace.APIClient
  require Logger

  @behaviour Adapter
  @behaviour Adapter.IdP

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      GoogleWorkspace.APIClient,
      # Background Jobs
      GoogleWorkspace.Jobs.RefreshAccessTokens,
      GoogleWorkspace.Jobs.SyncDirectory
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
    |> Domain.Repo.Changeset.trim_change(:email)
    |> Domain.Repo.Changeset.trim_change(:provider_identifier)
    |> Domain.Repo.Changeset.copy_change(:provider_virtual_state, :provider_state)
    |> Ecto.Changeset.put_change(:provider_virtual_state, %{})
  end

  @impl true
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Repo.Changeset.cast_polymorphic_embed(:adapter_config,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(GoogleWorkspace.Settings, current_attrs, :json)
        |> GoogleWorkspace.Settings.Changeset.changeset(attrs)
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
    OpenIDConnect.sign_out(provider, identity, redirect_url)
  end

  def fetch_access_token(%Provider{} = provider) do
    case GoogleWorkspace.fetch_service_account_access_token(provider) do
      {:ok, access_token} ->
        {:ok, access_token}

      {:error, :missing_service_account_key} ->
        {:ok, provider.adapter_state["access_token"]}

      {:error, {401, _response} = reason} ->
        Logger.warning("401 while fetching service account access token",
          account_id: provider.account_id,
          account_slug: provider.account.slug,
          provider_id: provider.id,
          provider_adapter: provider.adapter,
          reason: inspect(reason)
        )

        {:error, reason}

      {:error, reason} ->
        Logger.error("Failed to fetch service account access token",
          account_id: provider.account_id,
          account_slug: provider.account.slug,
          provider_id: provider.id,
          provider_adapter: provider.adapter,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  def fetch_service_account_access_token(%Provider{} = provider) do
    key = provider.adapter_config["service_account_json_key"]
    sub = provider.adapter_state["userinfo"]["sub"]

    cond do
      is_nil(key) or key == "" ->
        {:error, :missing_service_account_key}

      is_nil(sub) or sub == "" ->
        {:error, :missing_sub}

      true ->
        unix_timestamp = :os.system_time(:seconds)
        jws = %{"alg" => "RS256", "typ" => "JWT"}
        jwk = JOSE.JWK.from_pem(key["private_key"])

        claim_set =
          %{
            "iss" => key["client_email"],
            "scope" => Enum.join(GoogleWorkspace.Settings.scope(), " "),
            "aud" => "https://oauth2.googleapis.com/token",
            "sub" => sub,
            "exp" => unix_timestamp + 3600,
            "iat" => unix_timestamp
          }
          |> Jason.encode!()

        jwt =
          JOSE.JWS.sign(jwk, claim_set, jws)
          |> JOSE.JWS.compact()
          |> elem(1)

        APIClient.fetch_service_account_token(jwt)
    end
  end

  @impl true
  def verify_and_update_identity(%Provider{} = provider, payload) do
    OpenIDConnect.verify_and_update_identity(provider, payload)
  end

  def verify_and_upsert_identity(%Actors.Actor{} = actor, %Provider{} = provider, payload) do
    OpenIDConnect.verify_and_upsert_identity(actor, provider, payload)
  end

  def refresh_access_token(%Provider{} = provider) do
    OpenIDConnect.refresh_access_token(provider)
  end

  @impl true
  def refresh_access_token(%Identity{} = identity) do
    OpenIDConnect.refresh_access_token(identity)
  end
end
