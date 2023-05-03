defmodule Domain.Auth.Adapters.Email do
  alias Domain.Config
  alias Domain.Auth.{Identity, Provider, Adapter}

  @behaviour Adapter

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
    {%{}, %{}}
  end

  # def fetch_provider_by_email(email) do
  #   Actor.Query.by_email(email)
  #   |> Repo.fetch()
  # end

  def request_sign_in_token(%Identity{} = identity) do
    sign_in_token = Domain.Crypto.rand_string()
    state_changeset = Email.Changeset.generate_sign_in_token(sign_in_token)

    Identity.Mutator.update_provider_state(identity, state_changeset, %{
      sign_in_token: sign_in_token
    })
  end

  # TODO: behaviour?
  def sign_in(%Identity{} = identity, token) do
    consume_sign_in_token(identity, token)
  end

  defp consume_sign_in_token(
         %Identity{provider_state: %{"sign_in_token_hash" => sign_in_token_hash}} = identity,
         token
       )
       when is_binary(token) do
    if Domain.Crypto.equal?(token, sign_in_token_hash) do
      Identity.Query.by_id(identity.id)
      |> Identity.Query.where_sign_in_token_is_not_expired()
      |> Identity.Mutator.reset_provider_state()
      |> case do
        {:ok, identity} -> {:ok, identity}
        {:error, :not_found} -> {:error, :invalid_token}
      end
    else
      {:error, :invalid_token}
    end
  end

  defp consume_sign_in_token(%Identity{}, _token) do
    {:error, :invalid_token}
  end
end
