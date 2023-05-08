defmodule Domain.Auth.Adapters.Email do
  alias Domain.Repo
  alias Domain.Config
  alias Domain.Auth.{Identity, Provider, Adapter}

  @behaviour Adapter

  @sign_in_token_expiration_seconds 15 * 60

  @impl true
  def ensure_provisioned(%Provider{} = provider) do
    # TODO: validate email settings are present and correct to enable the provider
    {:ok, provider}
  end

  @impl true
  def ensure_deprovisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  def identity_create_state(%Provider{} = _provider) do
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

  # def fetch_provider_by_email(email) do
  #   Actor.Query.by_email(email)
  #   |> Repo.fetch()
  # end

  def request_sign_in_token(%Identity{} = identity) do
    identity = Repo.preload(identity, :provider)
    {state, virtual_state} = identity_create_state(identity.provider)
    Identity.Mutator.update_provider_state(identity, state, virtual_state)
  end

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
            :invalid_token

          is_nil(sign_in_token_created_at) ->
            :invalid_token

          sign_in_token_expired?(sign_in_token_created_at) ->
            :expired_token

          not Domain.Crypto.equal?(token, sign_in_token_hash) ->
            :invalid_token

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
