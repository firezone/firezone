defmodule Domain.Auth do
  require Ecto.Query
  alias Domain.{Accounts, Actors, Tokens}
  alias Domain.Auth.{Authorizer, Subject, Context, Permission, Roles, Role}
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

    with :ok <- ensure_has_permissions(subject, Authorizer.manage_service_accounts_permission()),
         {:ok, token} <- Tokens.create_token(attrs, subject) do
      {:ok, Tokens.encode_fragment!(token)}
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

    with :ok <- ensure_has_permissions(subject, Authorizer.manage_api_clients_permission()),
         {:ok, token} <- Tokens.create_token(attrs, subject) do
      {:ok, Tokens.encode_fragment!(token)}
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
      {:error, :actor_not_active} -> {:error, :unauthorized}
      {:error, :invalid_or_expired_token} -> {:error, :unauthorized}
      {:error, :invalid_remote_ip} -> {:error, :unauthorized}
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
      permissions = fetch_type_permissions!(actor.type)

      {:ok,
       %Subject{
         actor: actor,
         permissions: permissions,
         account: account,
         expires_at: token.expires_at,
         context: context,
         token_id: token.id,
         auth_provider_id: token.auth_provider_id
       }}
    end
  end

  # Permissions

  def has_permission?(
        %Subject{permissions: granted_permissions},
        %Permission{} = required_permission
      ) do
    Enum.member?(granted_permissions, required_permission)
  end

  def has_permission?(%Subject{} = subject, {:one_of, required_permissions}) do
    Enum.any?(required_permissions, fn required_permission ->
      has_permission?(subject, required_permission)
    end)
  end

  def fetch_type_permissions!(%Role{} = type),
    do: type.permissions

  def fetch_type_permissions!(type_name) when is_atom(type_name),
    do: type_name |> Roles.build() |> fetch_type_permissions!()

  # Authorization

  def ensure_type(%Subject{actor: %{type: type}}, type), do: :ok
  def ensure_type(%Subject{actor: %{}}, _type), do: {:error, :unauthorized}

  def ensure_has_permissions(%Subject{} = subject, required_permissions) do
    with :ok <- ensure_permissions_are_not_expired(subject) do
      required_permissions
      |> List.wrap()
      |> Enum.reject(fn required_permission ->
        has_permission?(subject, required_permission)
      end)
      |> Enum.uniq()
      |> case do
        [] ->
          :ok

        missing_permissions ->
          {:error,
           {:unauthorized, reason: :missing_permissions, missing_permissions: missing_permissions}}
      end
    end
  end

  defp ensure_permissions_are_not_expired(%Subject{expires_at: nil}) do
    :ok
  end

  defp ensure_permissions_are_not_expired(%Subject{expires_at: expires_at}) do
    if DateTime.after?(expires_at, DateTime.utc_now()) do
      :ok
    else
      {:error, {:unauthorized, reason: :subject_expired}}
    end
  end

  def can_grant_role?(%Subject{} = subject, granted_role) do
    granted_permissions = fetch_type_permissions!(granted_role)
    MapSet.subset?(granted_permissions, subject.permissions)
  end

  def email_regex do
    ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/
  end
end
