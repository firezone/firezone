defmodule Domain.Auth.Adapters.OpenIDConnect do
  use Supervisor
  alias Domain.Repo
  alias Domain.Accounts
  alias Domain.Auth.{Identity, Provider, Adapter}
  alias Domain.Auth.Adapters.OpenIDConnect.{Settings, State, PKCE}
  require Logger

  @behaviour Adapter
  @behaviour Adapter.IdP

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end

  @impl true
  def capabilities do
    [
      provisioners: [:just_in_time],
      login_flow_group: :openid_connect
    ]
  end

  @impl true
  def identity_changeset(%Provider{} = _provider, %Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Validator.trim_change(:provider_identifier)
    |> Ecto.Changeset.put_change(:provider_state, %{})
    |> Ecto.Changeset.put_change(:provider_virtual_state, %{})
  end

  @impl true
  def ensure_provisioned_for_account(%Ecto.Changeset{} = changeset, %Accounts.Account{}) do
    Domain.Changeset.cast_polymorphic_embed(changeset, :adapter_config,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(Settings, current_attrs, :json)
        |> Settings.Changeset.changeset(attrs)
      end
    )
  end

  @impl true
  def ensure_deprovisioned(%Ecto.Changeset{} = changeset) do
    changeset
  end

  def authorization_uri(%Provider{} = provider, redirect_uri) when is_binary(redirect_uri) do
    config = config_for_provider(provider)

    verifier = PKCE.code_verifier()
    state = State.new()

    params = %{
      access_type: :offline,
      state: state,
      code_challenge_method: PKCE.code_challenge_method(),
      code_challenge: PKCE.code_challenge(verifier)
    }

    with {:ok, uri} <- OpenIDConnect.authorization_uri(config, redirect_uri, params) do
      {:ok, uri, {state, verifier}}
    end
  end

  def ensure_states_equal(state1, state2) do
    if State.equal?(state1, state2) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  @impl true
  def verify_identity(%Provider{} = provider, {redirect_uri, code_verifier, code}) do
    sync_identity(provider, %{
      grant_type: "authorization_code",
      redirect_uri: redirect_uri,
      code: code,
      code_verifier: code_verifier
    })
    |> case do
      {:ok, identity, expires_at} -> {:ok, identity, expires_at}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :expired_token} -> {:error, :expired}
      {:error, :invalid_token} -> {:error, :invalid}
      {:error, :internal_error} -> {:error, :internal_error}
    end
  end

  def refresh_token(%Identity{} = identity) do
    identity = Repo.preload(identity, :provider)

    sync_identity(identity.provider, %{
      grant_type: "refresh_token",
      refresh_token: identity.provider_state["refresh_token"]
    })
  end

  defp sync_identity(%Provider{} = provider, token_params) do
    config = config_for_provider(provider)

    with {:ok, tokens} <- OpenIDConnect.fetch_tokens(config, token_params),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]),
         {:ok, userinfo} <- OpenIDConnect.fetch_userinfo(config, tokens["access_token"]) do
      # TODO: sync groups
      # TODO: refresh the access token so it doesn't expire
      # TODO: first admin user token that configured provider should used for periodic syncs
      # TODO: active status for relays, gateways in list functions
      # TODO: JIT provisioning
      expires_at =
        cond do
          not is_nil(tokens["expires_in"]) ->
            DateTime.add(DateTime.utc_now(), tokens["expires_in"], :second)

          not is_nil(claims["exp"]) ->
            DateTime.from_unix!(claims["exp"])

          true ->
            nil
        end

      provider_identifier = claims["sub"]

      Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_provider_identifier(provider_identifier)
      |> Repo.fetch_and_update(
        with: fn identity ->
          Identity.Changeset.update_provider_state(
            identity,
            %{
              access_token: tokens["access_token"],
              refresh_token: tokens["refresh_token"],
              expires_at: expires_at,
              userinfo: userinfo,
              claims: claims
            }
          )
        end
      )
      |> case do
        {:ok, identity} -> {:ok, identity, expires_at}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_jwt, "invalid exp claim: token has expired"}} ->
        {:error, :expired_token}

      {:error, {:invalid_jwt, _reason}} ->
        {:error, :invalid_token}

      {:error, other} ->
        Logger.error("Failed to connect OpenID Connect provider",
          provider_id: provider.id,
          reason: inspect(other)
        )

        {:error, :internal_error}
    end
  end

  defp config_for_provider(%Provider{} = provider) do
    Ecto.embedded_load(Settings, provider.adapter_config, :json)
    |> Map.from_struct()
  end
end
