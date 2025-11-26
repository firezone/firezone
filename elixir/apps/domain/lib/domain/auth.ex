defmodule Domain.Auth do
  require Ecto.Query
  alias Domain.{Accounts, Actors, Tokens}
  alias Domain.Auth.{Subject, Context}
  require Logger

  # Tokens

  def create_service_account_token(
        %Actors.Actor{type: :service_account, account_id: account_id} = actor,
        attrs,
        %Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :client,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => actor.account_id,
        "actor_id" => actor.id
      })

    # Only account admins can create service account tokens
    if subject.actor.type == :account_admin_user do
      with {:ok, token} <- Tokens.create_token(attrs, subject) do
        {:ok, Domain.Crypto.encode_token_fragment!(token)}
      end
    else
      {:error, :unauthorized}
    end
  end

  def create_api_client_token(
        %Actors.Actor{type: :api_client, account_id: account_id} = actor,
        attrs,
        %Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :api_client,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => actor.account_id,
        "actor_id" => actor.id
      })

    # Only account admins can create API client tokens
    if subject.actor.type == :account_admin_user do
      with {:ok, token} <- Tokens.create_token(attrs, subject) do
        {:ok, Domain.Crypto.encode_token_fragment!(token)}
      end
    else
      {:error, :unauthorized}
    end
  end

  # Authentication

  def authenticate(encoded_token, %Context{} = context)
      when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         {:ok, subject} <- build_subject(token, context) do
      {:ok, subject}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :invalid_user_agent} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def build_subject(%Tokens.Token{type: type} = token, %Context{} = context)
      when type in [:browser, :client, :api_client] do
    account = Accounts.fetch_account_by_id!(token.account_id)

    with {:ok, actor} <- Actors.fetch_active_actor_by_id(token.actor_id) do
      {:ok,
       %Subject{
         actor: actor,
         account: account,
         expires_at: token.expires_at,
         context: context,
         token_id: token.id,
         auth_provider_id: token.auth_provider_id
       }}
    end
  end
end
