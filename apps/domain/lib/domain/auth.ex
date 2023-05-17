defmodule Domain.Auth do
  use Supervisor
  alias Domain.Repo
  alias Domain.Config
  alias Domain.{Accounts, Actors}
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
    |> Adapters.ensure_provisioned()
    |> Repo.insert()
  end

  def disable_provider(%Provider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(Provider, subject)
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
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch_and_update(with: &Provider.Changeset.enable_provider/1)
    end
  end

  def delete_provider(%Provider{} = provider, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch_and_update(
        with: fn provider ->
          if other_active_providers_exist?(provider) do
            provider
            |> Provider.Changeset.delete_provider()
            |> Adapters.ensure_deprovisioned()
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

  def fetch_identity_by_id(id) do
    Identity.Query.by_id(id)
    |> Repo.fetch()
  end

  def fetch_identity_by_id!(id) do
    Identity.Query.by_id(id)
    |> Repo.fetch!()
  end

  def create_identity(%Actors.Actor{} = actor, %Provider{} = provider, provider_identifier) do
    Identity.Changeset.create(actor, provider, provider_identifier)
    |> Adapters.identity_changeset(provider)
    |> Repo.insert()
  end

  def replace_identity(%Identity{} = identity, provider_identifier, %Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_identities_permission(),
         Authorizer.manage_own_identities_permission()
       ]}

    with :ok <- ensure_has_permissions(subject, required_permissions) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:identity, fn _repo, _effects_so_far ->
        Identity.Query.by_id(identity.id)
        |> Identity.Query.lock()
        |> Identity.Query.with_preloaded_assoc(:inner, :actor)
        |> Identity.Query.with_preloaded_assoc(:inner, :provider)
        |> Repo.fetch()
      end)
      |> Ecto.Multi.insert(:new_identity, fn %{identity: identity} ->
        Identity.Changeset.create(identity.actor, identity.provider, provider_identifier)
        |> Adapters.identity_changeset(identity.provider)
      end)
      |> Ecto.Multi.update(:deleted_identity, fn %{identity: identity} ->
        Identity.Changeset.delete_identity(identity)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{new_identity: identity}} ->
          {:ok, identity}

        {:error, _step, error_or_changeset, _effects_so_far} ->
          {:error, error_or_changeset}
      end
    end
  end

  def delete_identity(%Identity{} = identity, %Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_identities_permission(),
         Authorizer.manage_own_identities_permission()
       ]}

    with :ok <- ensure_has_permissions(subject, required_permissions) do
      Identity.Query.by_id(identity.id)
      |> Authorizer.for_subject(Identity, subject)
      |> Repo.fetch_and_update(with: &Identity.Changeset.delete_identity/1)
    end
  end

  # Sign Up / In / Off

  def sign_in(%Provider{} = provider, provider_identifier, secret, user_agent, remote_ip) do
    with {:ok, identity} <-
           fetch_identity_by_provider_and_identifier(provider, provider_identifier),
         {:ok, identity} <-
           Adapters.verify_secret(provider, identity, secret) do
      {:ok, build_subject(identity, user_agent, remote_ip)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_secret} -> {:error, :unauthorized}
      {:error, :expired_secret} -> {:error, :unauthorized}
    end
  end

  def sign_in(session_token, user_agent, remote_ip) do
    with {:ok, identity_id} <- verify_session_token(session_token, user_agent, remote_ip),
         {:ok, identity} <- fetch_identity_by_id(identity_id) do
      {:ok, build_subject(identity, user_agent, remote_ip)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_token} -> {:error, :unauthorized}
      {:error, :expired_token} -> {:error, :unauthorized}
      {:error, :unauthorized_browser} -> {:error, :unauthorized}
    end
  end

  defp fetch_identity_by_provider_and_identifier(%Provider{} = provider, provider_identifier) do
    Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.by_provider_identifier(provider_identifier)
    |> Repo.fetch()
  end

  defp build_subject(%Identity{} = identity, user_agent, remote_ip)
       when is_binary(user_agent) and is_tuple(remote_ip) do
    identity =
      identity
      |> Identity.Changeset.sign_in(user_agent, remote_ip)
      |> Repo.update!()

    identity_with_preloads = Repo.preload(identity, [:account, :actor])
    permissions = fetch_role_permissions!(identity_with_preloads.actor.role)

    %Subject{
      identity: identity,
      actor: identity_with_preloads.actor,
      permissions: permissions,
      account: identity_with_preloads.account,
      context: %Context{remote_ip: remote_ip, user_agent: user_agent}
    }
  end

  # Session

  # TODO: we need to leverage provider token expiration here
  def create_session_token_from_subject(%Subject{} = subject) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    payload = session_token_payload(subject)
    {:ok, Plug.Crypto.sign(key_base, salt, payload)}
  end

  defp session_token_payload(%Subject{identity: %Identity{} = identity, context: context}),
    do: {:identity, identity.id, session_context_payload(context.remote_ip, context.user_agent)}

  defp session_context_payload(remote_ip, user_agent)
       when is_tuple(remote_ip) and is_binary(user_agent) do
    :crypto.hash(:sha256, :erlang.term_to_binary({remote_ip, user_agent}))
  end

  defp verify_session_token(token, user_agent, remote_ip) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    max_age = Keyword.fetch!(config, :max_age)

    context_payload = session_context_payload(remote_ip, user_agent)

    case Plug.Crypto.verify(key_base, salt, token, max_age: max_age) do
      {:ok, {:identity, identity_id, ^context_payload}} ->
        {:ok, identity_id}

      {:ok, {_type, _id, _context_payload}} ->
        {:error, :unauthorized_browser}

      {:error, :invalid} ->
        {:error, :invalid_token}

      {:error, :expired} ->
        {:error, :expired_token}
    end
  end

  defp fetch_config! do
    Config.fetch_env!(:domain, __MODULE__)
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

  def ensure_type(%Subject{actor: %{type: type}}, type), do: :ok
  def ensure_type(%Subject{actor: %{}}, _type), do: {:error, :unauthorized}

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
