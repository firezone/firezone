defmodule Domain.Auth.Adapters.Email do
  use Supervisor
  alias Domain.Repo
  alias Domain.Auth.{Identity, Provider, Adapter}

  @behaviour Adapter

  @sign_in_token_expiration_seconds 15 * 60

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
    |> Domain.Validator.validate_email(:provider_identifier)
    |> Ecto.Changeset.put_change(:provider_state, state)
    |> Ecto.Changeset.put_change(:provider_virtual_state, virtual_state)
  end

  @impl true
  def ensure_provisioned(%Ecto.Changeset{} = changeset) do
    # XXX: Re-enable this when web app will start handling email delivery again,
    # we will need to verify that it's configured.
    # email_disabled? = Config.fetch_config!(:outbound_email_adapter) == Domain.Mailer.NoopAdapter

    # if email_disabled? do
    #   Ecto.Changeset.add_error(changeset, :adapter, "email adapter is not configured")
    # else
    changeset
    # end
  end

  @impl true
  def ensure_deprovisioned(%Ecto.Changeset{} = changeset) do
    changeset
  end

  defp identity_create_state(%Provider{} = _provider) do
    sign_in_token = Domain.Crypto.rand_string()

    {
      %{
        sign_in_token_hash: Domain.Crypto.hash(sign_in_token),
        sign_in_token_created_at: DateTime.utc_now()
      },
      %{
        sign_in_token: sign_in_token
      }
    }
  end

  # XXX: Send actual email here once web has templates
  def request_sign_in_token(%Identity{} = identity) do
    identity = Repo.preload(identity, :provider)
    {state, virtual_state} = identity_create_state(identity.provider)
    Identity.Mutator.update_provider_state(identity, state, virtual_state)
  end

  @impl true
  def verify_secret(%Identity{} = identity, token) do
    consume_sign_in_token(identity, token)
  end

  defp consume_sign_in_token(%Identity{} = identity, token) when is_binary(token) do
    Identity.Query.by_id(identity.id)
    |> Repo.fetch_and_update(
      with: fn identity ->
        sign_in_token_hash = identity.provider_state["sign_in_token_hash"]
        sign_in_token_created_at = identity.provider_state["sign_in_token_created_at"]

        cond do
          is_nil(sign_in_token_hash) ->
            :invalid_secret

          is_nil(sign_in_token_created_at) ->
            :invalid_secret

          sign_in_token_expired?(sign_in_token_created_at) ->
            :expired_secret

          not Domain.Crypto.equal?(token, sign_in_token_hash) ->
            :invalid_secret

          true ->
            Identity.Changeset.update_provider_state(identity, %{}, %{})
        end
      end
    )
  end

  defp sign_in_token_expired?(sign_in_token_created_at) do
    now = DateTime.utc_now()

    case DateTime.from_iso8601(sign_in_token_created_at) do
      {:ok, sign_in_token_created_at, 0} ->
        DateTime.diff(now, sign_in_token_created_at, :second) > @sign_in_token_expiration_seconds

      {:error, _reason} ->
        true
    end
  end
end
