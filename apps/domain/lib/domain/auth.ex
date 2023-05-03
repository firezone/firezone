defmodule Domain.Auth do
  use Supervisor
  alias Domain.Repo
  alias Domain.Config
  alias Domain.{Accounts, Actors, ApiTokens}
  alias Domain.Auth.{Authorizer, Subject, Context, Permission, Roles, Role, Identity}
  alias Domain.Auth.{Adapters, Provider}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Adapters
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Providers

  def create_provider(%Accounts.Account{} = account, attrs, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         :ok <- Accounts.ensure_has_access_to(subject, account) do
      create_provider(account, attrs)
    end
  end

  def create_provider(%Accounts.Account{} = account, attrs) do
    Provider.Changeset.create_changeset(account, attrs)
    |> Repo.insert()
  end

  def disable_provider(%Provider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn provider ->
          if other_active_providers_exist?(provider) do
            Provider.Changeset.disable_provider(provider)
          else
            :cant_disable_the_last_provider
          end
        end
      )
    end
  end

  def enable_provider(%Provider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Provider.Changeset.enable_provider/1)
    end
  end

  def delete_provider(%Provider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn provider ->
          if other_active_providers_exist?(provider) do
            Provider.Changeset.delete_provider(provider)
          else
            :cant_delete_the_last_provider
          end
        end
      )
    end
  end

  defp other_active_providers_exist?(%Provider{id: id, account_id: account_id}) do
    Provider.Query.by_id({:not, id})
    |> Provider.Query.not_disabled()
    |> Provider.Query.by_account_id(account_id)
    |> Provider.Query.lock()
    |> Repo.exists?()
  end

  # Identities

  def link_identity(%Actors.Actor{} = actor, %Provider{} = provider, provider_identifier) do
    Identity.Changeset.create_changeset(actor, provider, provider_identifier)
    |> Repo.insert()
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

  def has_permissions?(%Subject{} = subject, required_permissions) do
    ensure_has_permissions(subject, required_permissions) == :ok
  end

  def fetch_role_permissions!(%Role{} = role),
    do: role.permissions

  def fetch_role_permissions!(role_name) when is_atom(role_name),
    do: role_name |> Roles.build() |> fetch_role_permissions!()

  # Authorization

  def ensure_has_access_to(%Subject{} = subject, %Provider{} = provider) do
    if subject.account.id == provider.account_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def ensure_has_permissions(%Subject{} = subject, required_permissions) do
    required_permissions
    |> List.wrap()
    |> Enum.reject(fn required_permission ->
      has_permission?(subject, required_permission)
    end)
    |> Enum.uniq()
    |> case do
      [] -> :ok
      missing_permissions -> {:error, {:unauthorized, missing_permissions: missing_permissions}}
    end
  end

  ############

  def fetch_subject!(%Actors.Actor{} = actor, remote_ip, user_agent) do
    actor = Repo.preload(actor, :account)
    role = fetch_actor_role!(actor)

    %Subject{
      actor: actor,
      permissions: role.permissions,
      account: actor.account,
      context: %Context{remote_ip: remote_ip, user_agent: user_agent}
    }
  end

  def fetch_subject!(%ApiTokens.ApiToken{} = api_token, remote_ip, user_agent) do
    api_token = Repo.preload(api_token, user: [:account])
    role = fetch_actor_role!(api_token.user)

    # XXX: Once we build audit logging here we need to build a different kind of subject
    %Subject{
      actor: {:user, api_token.user},
      permissions: role.permissions,
      account: api_token.user.account,
      context: %Context{remote_ip: remote_ip, user_agent: user_agent}
    }
  end

  defp fetch_actor_role!(%Actors.Actor{} = user) do
    Roles.build(user.role)
  end

  # def sign_in(:userpass, login, password): do, {:ok, session_token}
  # def sign_in(:api_token, token)
  # def sign_in(:user_token, token)
  # def sign_in(:oidc, provider, token)
  # def sign_in(:saml, provider, token)

  # TODO: for some tokens we want to save remote_ip and invalidate them when the IP changes
  def create_auth_token(%Subject{} = subject) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt, token_body(subject))
  end

  defp token_body(%Subject{actor: {:user, user}}), do: {:user, user.id}

  def consume_auth_token(token, remote_ip, user_agent) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    max_age = Keyword.fetch!(config, :max_age)

    case Plug.Crypto.verify(key_base, salt, token, max_age: max_age) do
      {:ok, {:user, user_id}} ->
        # TODO: we might want to check that user is active in future
        user = Actors.fetch_user_by_id!(user_id)
        role = fetch_actor_role!(user)

        {:ok,
         %Subject{
           actor: {:user, user},
           permissions: role.permissions,
           context: %Context{remote_ip: remote_ip, user_agent: user_agent}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_config! do
    Config.fetch_env!(:domain, __MODULE__)
  end

  def fetch_oidc_provider_config(provider_id) do
    with {:ok, provider} <- fetch_provider(:openid_connect_providers, provider_id) do
      redirect_uri =
        if provider.redirect_uri do
          provider.redirect_uri
        else
          external_url = Domain.Config.fetch_env!(:web, :external_url)
          "#{external_url}auth/oidc/#{provider.id}/callback/"
        end

      {:ok,
       %{
         discovery_document_uri: provider.discovery_document_uri,
         client_id: provider.client_id,
         client_secret: provider.client_secret,
         redirect_uri: redirect_uri,
         response_type: provider.response_type,
         scope: provider.scope
       }}
    end
  end

  def auto_create_users?(field, provider_id) do
    fetch_provider!(field, provider_id).auto_create_users
  end

  defp fetch_provider(field, provider_id) do
    Config.fetch_config!(field)
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  defp fetch_provider!(field, provider_id) do
    case fetch_provider(field, provider_id) do
      {:ok, provider} ->
        provider

      {:error, :not_found} ->
        raise RuntimeError, "Unknown provider #{provider_id}"
    end
  end
end
