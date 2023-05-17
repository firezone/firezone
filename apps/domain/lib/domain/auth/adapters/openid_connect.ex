defmodule Domain.Auth.Adapters.OpenIDConnect do
  use Supervisor
  alias Domain.Repo
  alias Domain.Auth.{Identity, Provider, Adapter}
  alias Domain.Auth.Adapters.OpenIDConnect.{Settings, State, PKCE}
  require Logger

  @behaviour Adapter

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end

  @impl true
  def identity_changeset(%Provider{} = provider, %Ecto.Changeset{} = changeset) do
    {state, virtual_state} = identity_create_state(provider)

    changeset
    |> Domain.Validator.trim_change(:provider_identifier)
    |> Ecto.Changeset.put_change(:provider_state, state)
    |> Ecto.Changeset.put_change(:provider_virtual_state, virtual_state)
  end

  @impl true
  def ensure_provisioned(%Ecto.Changeset{} = changeset) do
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

  defp identity_create_state(%Provider{} = _provider) do
    {%{}, %{}}
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
  def verify_secret(%Identity{} = identity, {redirect_uri, code_verifier, code}) do
    sync_identity(identity, %{
      grant_type: "authorization_code",
      redirect_uri: redirect_uri,
      code: code,
      code_verifier: code_verifier
    })
  end

  def refresh_token(%Identity{} = identity) do
    sync_identity(identity, %{
      grant_type: "refresh_token",
      refresh_token: identity.provider_state["refresh_token"]
    })
  end

  defp sync_identity(%Identity{} = identity, token_params) do
    {config, identity} = config_for_identity(identity)

    with {:ok, tokens} <- OpenIDConnect.fetch_tokens(config, token_params),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]),
         {:ok, userinfo} <- OpenIDConnect.fetch_userinfo(config, tokens["id_token"]) do
      # TODO: sync groups
      Identity.Query.by_id(identity.id)
      |> Repo.fetch_and_update(
        with: fn identity ->
          Identity.Changeset.update_provider_state(identity, %{
            id_token: tokens["id_token"],
            access_token: tokens["access_token"],
            refresh_token: tokens["refresh_token"],
            expires_at:
              if(tokens["expires_in"],
                do: DateTime.add(DateTime.utc_now(), tokens["expires_in"], :second)
              ),
            userinfo: userinfo,
            claims: claims
          })
        end
      )
    else
      {:error, {:invalid_jwt, "invalid exp claim: token has expired"}} ->
        {:error, :expired_token}

      {:error, {:invalid_jwt, _reason}} ->
        {:error, :invalid_token}

      {:error, other} ->
        Logger.error("Failed to connect OpenID Connect provider",
          provider_id: identity.provider_id,
          identity_id: identity.id,
          reason: inspect(other)
        )

        {:error, :internal_error}
    end
  end

  defp config_for_identity(%Identity{} = identity) do
    identity = Repo.preload(identity, :provider)
    {config_for_provider(identity.provider), identity}
  end

  defp config_for_provider(%Provider{} = provider) do
    Ecto.embedded_load(Settings, provider.adapter_config, :json)
    |> Map.from_struct()
  end
end
