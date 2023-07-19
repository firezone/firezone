defmodule Domain.Auth.Adapters.Email do
  use Supervisor
  alias Domain.Repo
  alias Domain.Auth.{Identity, Provider, Adapter}

  @behaviour Adapter
  @behaviour Adapter.Local

  @sign_in_token_expiration_seconds 15 * 60

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
      provisioners: [:manual],
      login_flow_group: :email
    ]
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
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    %{
      outbound_email_adapter: outbound_email_adapter
    } =
      Domain.Config.fetch_resolved_configs!(changeset.data.account_id, [:outbound_email_adapter])

    if is_nil(outbound_email_adapter) do
      Ecto.Changeset.add_error(changeset, :adapter, "email adapter is not configured")
    else
      changeset
    end
  end

  @impl true
  def ensure_provisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  @impl true
  def ensure_deprovisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  defp identity_create_state(%Provider{} = _provider) do
    sign_in_token = Domain.Crypto.rand_string()

    {
      %{
        "sign_in_token_hash" => Domain.Crypto.hash(sign_in_token),
        "sign_in_token_created_at" => DateTime.utc_now()
      },
      %{
        sign_in_token: sign_in_token
      }
    }
  end

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
        sign_in_token_hash =
          identity.provider_state["sign_in_token_hash"] ||
            identity.provider_state[:sign_in_token_hash]

        sign_in_token_created_at =
          identity.provider_state["sign_in_token_created_at"] ||
            identity.provider_state[:sign_in_token_created_at]

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
            Identity.Changeset.update_identity_provider_state(identity, %{}, %{})
        end
      end
    )
    |> case do
      {:ok, identity} -> {:ok, identity, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sign_in_token_expired?(%DateTime{} = sign_in_token_created_at) do
    now = DateTime.utc_now()
    DateTime.diff(now, sign_in_token_created_at, :second) > @sign_in_token_expiration_seconds
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
