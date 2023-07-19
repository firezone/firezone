defmodule Domain.Auth.Adapters.Token do
  @moduledoc """
  This provider is used to authenticate service account using API keys.
  """
  use Supervisor
  alias Domain.Repo
  alias Domain.Auth.{Identity, Provider, Adapter}
  alias Domain.Auth.Adapters.Token.State

  @behaviour Adapter
  @behaviour Adapter.Local

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
      group: nil
    ]
  end

  @impl true
  def identity_changeset(%Provider{} = _provider, %Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Validator.trim_change(:provider_identifier)
    |> put_hash_and_expiration()
  end

  defp put_hash_and_expiration(changeset) do
    secret = Domain.Crypto.rand_token(32)
    secret_hash = Domain.Crypto.hash(secret)

    data = Map.get(changeset.data, :provider_virtual_state) || %{}
    attrs = Ecto.Changeset.get_change(changeset, :provider_virtual_state) || %{}

    Ecto.embedded_load(State, data, :json)
    |> State.Changeset.changeset(attrs)
    |> Ecto.Changeset.put_change(:secret_hash, secret_hash)
    |> case do
      %{valid?: false} = nested_changeset ->
        {changeset, _original_type} =
          Domain.Changeset.inject_embedded_changeset(
            changeset,
            :provider_virtual_state,
            nested_changeset
          )

        changeset

      %{valid?: true} = nested_changeset ->
        expires_at = Ecto.Changeset.fetch_change!(nested_changeset, :expires_at)

        changeset
        |> Ecto.Changeset.put_change(:provider_state, %{
          "expires_at" => DateTime.to_iso8601(expires_at),
          "secret_hash" => secret_hash
        })
        |> Ecto.Changeset.put_change(:provider_virtual_state, %{
          secret: secret
        })
    end
  end

  @impl true
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
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
  def verify_secret(%Identity{} = identity, secret) when is_binary(secret) do
    Identity.Query.by_id(identity.id)
    |> Repo.fetch_and_update(
      with: fn identity ->
        secret_hash = identity.provider_state["secret_hash"]
        secret_expires_at = identity.provider_state["expires_at"]

        cond do
          is_nil(secret_hash) ->
            :invalid_secret

          is_nil(secret_expires_at) ->
            :invalid_secret

          sign_in_token_expired?(secret_expires_at) ->
            :expired_secret

          not Domain.Crypto.equal?(secret, secret_hash) ->
            :invalid_secret

          true ->
            Ecto.Changeset.change(identity)
        end
      end
    )
    |> case do
      {:ok, identity} ->
        {:ok, expires_at, 0} = DateTime.from_iso8601(identity.provider_state["expires_at"])
        {:ok, identity, expires_at}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sign_in_token_expired?(secret_expires_at) do
    now = DateTime.utc_now()

    case DateTime.from_iso8601(secret_expires_at) do
      {:ok, secret_expires_at, 0} ->
        DateTime.diff(secret_expires_at, now, :second) < 0

      {:error, _reason} ->
        true
    end
  end
end
