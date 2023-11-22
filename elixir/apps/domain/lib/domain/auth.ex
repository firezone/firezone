defmodule Domain.Auth do
  use Supervisor
  alias Domain.{Repo, Config, Validator}
  alias Domain.{Accounts, Actors}
  alias Domain.Auth.{Authorizer, Subject, Context, Permission, Roles, Role, Identity}
  alias Domain.Auth.{Adapters, Provider}

  @default_session_duration_hours %{
    account_admin_user: 24 * 7 - 1,
    account_user: 24 * 7,
    service_account: 20 * 365 * 24 * 7
  }

  @max_session_duration_hours @default_session_duration_hours

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

  def list_provider_adapters do
    Adapters.list_adapters()
  end

  def fetch_provider_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Provider.Query.all()
      |> Provider.Query.by_id(id)
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch()
      |> case do
        {:ok, provider} ->
          {:ok, Repo.preload(provider, preload)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  This functions allows to fetch singleton providers like `email` or `token`.
  """
  def fetch_active_provider_by_adapter(adapter, %Subject{} = subject, opts \\ [])
      when adapter in [:email, :token, :userpass] do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Provider.Query.by_adapter(adapter)
      |> Provider.Query.not_disabled()
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch()
      |> case do
        {:ok, provider} ->
          {:ok, Repo.preload(provider, preload)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def fetch_provider_by_id(id) do
    if Validator.valid_uuid?(id) do
      Provider.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_active_provider_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         true <- Validator.valid_uuid?(id) do
      {preload, _opts} = Keyword.pop(opts, :preload, [])

      Provider.Query.by_id(id)
      |> Provider.Query.not_disabled()
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch()
      |> case do
        {:ok, provider} ->
          {:ok, Repo.preload(provider, preload)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_active_provider_by_id(id) do
    if Validator.valid_uuid?(id) do
      Provider.Query.by_id(id)
      |> Provider.Query.not_disabled()
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def list_providers_for_account(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         :ok <- Accounts.ensure_has_access_to(subject, account) do
      Provider.Query.by_account_id(account.id)
      |> Repo.list()
    end
  end

  def list_active_providers_for_account(%Accounts.Account{} = account) do
    Provider.Query.by_account_id(account.id)
    |> Provider.Query.not_disabled()
    |> Repo.list()
  end

  def list_providers_pending_token_refresh_by_adapter(adapter) do
    datetime_filter = DateTime.utc_now() |> DateTime.add(30, :minute)

    Provider.Query.by_adapter(adapter)
    |> Provider.Query.by_provisioner(:custom)
    |> Provider.Query.by_non_empty_refresh_token()
    |> Provider.Query.token_expires_at({:lt, datetime_filter})
    |> Provider.Query.not_disabled()
    |> Repo.list()
  end

  def list_providers_pending_sync_by_adapter(adapter) do
    Provider.Query.by_adapter(adapter)
    |> Provider.Query.by_provisioner(:custom)
    |> Provider.Query.only_ready_to_be_synced()
    |> Provider.Query.not_disabled()
    |> Repo.list()
  end

  def new_provider(%Accounts.Account{} = account, attrs \\ %{}) do
    Provider.Changeset.create(account, attrs)
    |> Adapters.provider_changeset()
  end

  def create_provider(%Accounts.Account{} = account, attrs, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         :ok <- Accounts.ensure_has_access_to(subject, account),
         changeset =
           Provider.Changeset.create(account, attrs, subject)
           |> Adapters.provider_changeset(),
         {:ok, provider} <- Repo.insert(changeset) do
      Adapters.ensure_provisioned(provider)
    end
  end

  def create_provider(%Accounts.Account{} = account, attrs) do
    changeset =
      Provider.Changeset.create(account, attrs)
      |> Adapters.provider_changeset()

    with {:ok, provider} <- Repo.insert(changeset) do
      Adapters.ensure_provisioned(provider)
    end
  end

  def change_provider(%Provider{} = provider, attrs \\ %{}) do
    Provider.Changeset.update(provider, attrs)
    |> Adapters.provider_changeset()
  end

  def update_provider(%Provider{} = provider, attrs, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch_and_update(
        with: fn provider ->
          Provider.Changeset.update(provider, attrs)
          |> Adapters.provider_changeset()
        end
      )
    end
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
          else
            :cant_delete_the_last_provider
          end
        end
      )
      |> case do
        {:ok, provider} ->
          Adapters.ensure_deprovisioned(provider)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp other_active_providers_exist?(%Provider{id: id, account_id: account_id}) do
    Provider.Query.by_id({:not, id})
    |> Provider.Query.by_adapter({:not_in, [:token]})
    |> Provider.Query.not_disabled()
    |> Provider.Query.by_account_id(account_id)
    |> Provider.Query.lock()
    |> Repo.exists?()
  end

  def fetch_provider_capabilities!(%Provider{} = provider) do
    Adapters.fetch_capabilities!(provider)
  end

  # Identities

  def fetch_identity_by_id(id, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()) do
      Identity.Query.by_id(id)
      |> Authorizer.for_subject(Identity, subject)
      |> Repo.fetch()
    end
  end

  def fetch_active_identity_by_id(id) do
    Identity.Query.by_id(id)
    |> Identity.Query.not_disabled()
    |> Repo.fetch()
  end

  def fetch_identity_by_id(id) do
    Identity.Query.by_id(id)
    |> Repo.fetch()
  end

  def fetch_identity_by_id!(id) do
    Identity.Query.by_id(id)
    |> Repo.fetch!()
  end

  def fetch_identities_count_grouped_by_provider_id(%Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()) do
      {:ok, identities} =
        Identity.Query.group_by_provider_id()
        |> Authorizer.for_subject(Identity, subject)
        |> Repo.list()

      identities =
        Enum.reduce(identities, %{}, fn %{provider_id: id, count: count}, acc ->
          Map.put(acc, id, count)
        end)

      {:ok, identities}
    end
  end

  def sync_provider_identities_multi(%Provider{} = provider, attrs_list) do
    Identity.Sync.sync_provider_identities_multi(provider, attrs_list)
  end

  def upsert_identity(%Actors.Actor{} = actor, %Provider{} = provider, attrs) do
    Identity.Changeset.create_identity(actor, provider, attrs)
    |> Adapters.identity_changeset(provider)
    |> Repo.insert(
      conflict_target:
        {:unsafe_fragment,
         ~s/(account_id, provider_id, provider_identifier) WHERE deleted_at IS NULL/},
      on_conflict:
        {:replace,
         [
           :provider_state,
           :last_seen_user_agent,
           :last_seen_remote_ip,
           :last_seen_at
         ]},
      returning: true
    )
  end

  def new_identity(%Actors.Actor{} = actor, %Provider{} = provider, attrs \\ %{}) do
    Identity.Changeset.create_identity(actor, provider, attrs)
    |> Adapters.identity_changeset(provider)
  end

  def create_identity(
        %Actors.Actor{} = actor,
        %Provider{} = provider,
        attrs,
        %Subject{} = subject
      ) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()) do
      create_identity(actor, provider, attrs)
    end
  end

  def create_identity(%Actors.Actor{} = actor, %Provider{} = provider, attrs) do
    Identity.Changeset.create_identity(actor, provider, attrs)
    |> Adapters.identity_changeset(provider)
    |> Repo.insert()
  end

  def replace_identity(%Identity{} = identity, attrs, %Subject{} = subject) do
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
        Identity.Changeset.create_identity(identity.actor, identity.provider, attrs, subject)
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

  def delete_identity(%Identity{created_by: :provider}, %Subject{}) do
    {:error, :cant_delete_synced_identity}
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

  def delete_actor_identities(%Actors.Actor{} = actor) do
    {_count, nil} =
      Identity.Query.by_actor_id(actor.id)
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now(), provider_state: %{}])

    :ok
  end

  def identity_disabled?(%{disabled_at: nil}), do: false
  def identity_disabled?(_identity), do: true

  def identity_deleted?(%{deleted_at: nil}), do: false
  def identity_deleted?(_identity), do: true

  # Sign Up / In / Off

  def sign_in(%Provider{} = provider, id_or_provider_identifier, secret, %Context{} = context) do
    identity_queryable =
      Identity.Query.not_disabled()
      |> Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_id_or_provider_identifier(id_or_provider_identifier)

    with {:ok, identity} <- Repo.fetch(identity_queryable),
         {:ok, identity, expires_at} <- Adapters.verify_secret(provider, identity, secret) do
      {:ok, build_subject(identity, expires_at, context)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_secret} -> {:error, :unauthorized}
      {:error, :expired_secret} -> {:error, :unauthorized}
    end
  end

  def sign_in(%Provider{} = provider, payload, %Context{} = context) do
    with {:ok, identity, expires_at} <- Adapters.verify_and_update_identity(provider, payload) do
      {:ok, build_subject(identity, expires_at, context)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid} -> {:error, :unauthorized}
      {:error, :expired} -> {:error, :unauthorized}
    end
  end

  def sign_in(token, %Context{} = context) when is_binary(token) do
    with {:ok, identity, expires_at} <- verify_token(token, context.user_agent, context.remote_ip) do
      {:ok, build_subject(identity, expires_at, context)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_token} -> {:error, :unauthorized}
      {:error, :expired_token} -> {:error, :unauthorized}
      {:error, :unauthorized_browser} -> {:error, :unauthorized}
    end
  end

  def fetch_identity_by_provider_and_identifier(
        %Provider{} = provider,
        provider_identifier,
        opts \\ []
      ) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.by_provider_identifier(provider_identifier)
    |> Repo.fetch()
    |> case do
      {:ok, identity} ->
        {:ok, Repo.preload(identity, preload)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def build_subject(%Identity{} = identity, expires_at, context) do
    identity =
      identity
      |> Identity.Changeset.sign_in_identity(context)
      |> Repo.update!()

    identity_with_preloads = Repo.preload(identity, [:account, :actor])
    permissions = fetch_type_permissions!(identity_with_preloads.actor.type)

    %Subject{
      identity: identity,
      actor: identity_with_preloads.actor,
      permissions: permissions,
      account: identity_with_preloads.account,
      expires_at: build_subject_expires_at(identity_with_preloads.actor, expires_at),
      context: context
    }
  end

  defp build_subject_expires_at(%Actors.Actor{} = actor, expires_at) do
    now = DateTime.utc_now()

    default_session_duration_hours = Map.fetch!(@default_session_duration_hours, actor.type)
    expires_at = expires_at || DateTime.add(now, default_session_duration_hours, :hour)

    max_session_duration_hours = Map.fetch!(@max_session_duration_hours, actor.type)
    max_expires_at = DateTime.add(now, max_session_duration_hours, :hour)

    Enum.min([expires_at, max_expires_at], DateTime)
  end

  def sign_out(%Identity{} = identity, redirect_url) do
    identity = Repo.preload(identity, :provider)
    Adapters.sign_out(identity.provider, identity, redirect_url)
  end

  # Session

  @doc """
  This token is used to authenticate the user in the Portal UI and should be saved in user session.
  """
  def create_session_token_from_subject(%Subject{} = subject) do
    # TODO: we want to show all sessions in a UI so persist them to DB
    payload = session_token_payload(subject)
    sign_token(payload, subject.expires_at)
  end

  @doc """
  This token is used to authenticate the client and should be used in the Client WebSocket API.
  """
  def create_client_token_from_subject(%Subject{} = subject) do
    # TODO: we want to show all sessions in a UI so persist them to DB
    payload = client_token_payload(subject)
    sign_token(payload, subject.expires_at)
  end

  @doc """
  This token is used to authenticate the service account and should be used for REST API requests.
  """
  def create_access_token_for_identity(%Identity{} = identity) do
    payload = access_token_payload(identity)
    {:ok, expires_at, 0} = DateTime.from_iso8601(identity.provider_state["expires_at"])
    sign_token(payload, expires_at)
  end

  defp sign_token(payload, expires_at) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    max_age = DateTime.diff(expires_at, DateTime.utc_now(), :second)
    {:ok, Plug.Crypto.sign(key_base, salt, payload, max_age: max_age)}
  end

  def fetch_session_token_expires_at(token, opts \\ []) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)

    iterations = Keyword.get(opts, :key_iterations, 1000)
    length = Keyword.get(opts, :key_length, 32)
    digest = Keyword.get(opts, :key_digest, :sha256)
    cache = Keyword.get(opts, :cache, Plug.Crypto.Keys)
    secret = Plug.Crypto.KeyGenerator.generate(key_base, salt, iterations, length, digest, cache)

    with {:ok, message} <- Plug.Crypto.MessageVerifier.verify(token, secret) do
      {_data, signed, max_age} = Plug.Crypto.non_executable_binary_to_term(message)
      {:ok, datetime} = DateTime.from_unix(signed + trunc(max_age * 1000), :millisecond)
      {:ok, datetime}
    else
      :error -> {:error, :invalid_token}
    end
  end

  defp session_context_payload(remote_ip, user_agent)
       when is_tuple(remote_ip) and is_binary(user_agent) do
    :crypto.hash(:sha256, :erlang.term_to_binary({remote_ip, user_agent}))
  end

  defp verify_token(token, user_agent, remote_ip) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)

    case Plug.Crypto.verify(key_base, salt, token) do
      {:ok, payload} -> verify_token_payload(token, payload, user_agent, remote_ip)
      {:error, :invalid} -> {:error, :invalid_token}
      {:error, :expired} -> {:error, :expired_token}
    end
  end

  defp verify_token_payload(
         _token,
         {:identity, identity_id, secret, :ignore},
         _user_agent,
         _remote_ip
       ) do
    with {:ok, identity} <- fetch_active_identity_by_id(identity_id),
         {:ok, provider} <- fetch_active_provider_by_id(identity.provider_id),
         {:ok, identity, expires_at} <-
           Adapters.verify_secret(provider, identity, secret) do
      {:ok, identity, expires_at}
    else
      {:error, :invalid_secret} -> {:error, :invalid_token}
      {:error, :expired_secret} -> {:error, :expired_token}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp verify_token_payload(
         token,
         {:identity, identity_id, :ignore},
         _user_agent,
         _remote_ip
       ) do
    with {:ok, identity} <- fetch_active_identity_by_id(identity_id),
         {:ok, expires_at} <- fetch_session_token_expires_at(token) do
      {:ok, identity, expires_at}
    end
  end

  defp verify_token_payload(
         token,
         {:identity, identity_id, _context_payload},
         _user_agent,
         _remote_ip
       ) do
    with {:ok, identity} <- fetch_active_identity_by_id(identity_id),
         # XXX: Don't pin tokens to remote_ip and user_agent -- use device external_id instead?
         # true <- context_payload == session_context_payload(remote_ip, user_agent),
         {:ok, expires_at} <- fetch_session_token_expires_at(token) do
      {:ok, identity, expires_at}
    else
      false -> {:error, :unauthorized_browser}
      other -> other
    end
  end

  defp session_token_payload(%Subject{identity: %Identity{} = identity, context: context}) do
    {:identity, identity.id, session_context_payload(context.remote_ip, context.user_agent)}
  end

  defp client_token_payload(%Subject{identity: %Identity{} = identity}) do
    {:identity, identity.id, :ignore}
  end

  defp access_token_payload(%Identity{} = identity) do
    {:identity, identity.id, identity.provider_virtual_state.changes.secret, :ignore}
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

  def fetch_type_permissions!(%Role{} = type),
    do: type.permissions

  def fetch_type_permissions!(type_name) when is_atom(type_name),
    do: type_name |> Roles.build() |> fetch_type_permissions!()

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

  def can_grant_role?(%Subject{} = subject, granted_role) do
    granted_permissions = fetch_type_permissions!(granted_role)
    MapSet.subset?(granted_permissions, subject.permissions)
  end
end
