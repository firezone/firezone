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
        "actor_id" => actor.id,
        "created_by_user_agent" => subject.context.user_agent,
        "created_by_remote_ip" => subject.context.remote_ip
      })

    # Only account admins can create service account tokens
    if subject.actor.type == :account_admin_user do
      with {:ok, token} <- Tokens.create_token(attrs, subject) do
        {:ok, Tokens.encode_fragment!(token)}
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
        "actor_id" => actor.id,
        "created_by_user_agent" => subject.context.user_agent,
        "created_by_remote_ip" => subject.context.remote_ip
      })

    # Only account admins can create API client tokens
    if subject.actor.type == :account_admin_user do
      with {:ok, token} <- Tokens.create_token(attrs, subject) do
        {:ok, Tokens.encode_fragment!(token)}
      end
    else
      {:error, :unauthorized}
    end
  end

  # Authentication

  def authenticate(encoded_token, %Context{} = context)
      when is_binary(encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, context),
         :ok <- maybe_enforce_token_context(token, context),
         {:ok, subject} <- build_subject(token, context) do
      {:ok, subject}
    else
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :invalid_user_agent} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_enforce_token_context(
         %Tokens.Token{type: token_type} = token,
         %Context{type: context_type} = context
       )
       when token_type == :browser or context_type == :browser do
    # We disabled this check because Google Chrome uses "Happy Eyeballs" algorithm which sometimes
    # connects to the server using IPv4 for HTTP request and then uses IPv6 for WebSockets.
    # This causes the remote IP to change leading to LiveView auth redirect loops.
    # token.created_by_remote_ip.address != context.remote_ip -> {:error, :invalid_remote_ip}
    if token.created_by_user_agent != context.user_agent do
      {:error, :invalid_user_agent}
    else
      :ok
    end
  end

  defp maybe_enforce_token_context(%Tokens.Token{}, %Context{}) do
    :ok
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

  # Authorization

  def ensure_type(%Subject{actor: %{type: type}}, type), do: :ok
  def ensure_type(%Subject{actor: %{}}, _type), do: {:error, :unauthorized}

  def email_regex do
    ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/
  end
end
