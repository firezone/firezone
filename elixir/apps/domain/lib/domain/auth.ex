defmodule Domain.Auth do
  use Supervisor
  alias Domain.{Repo, Config, Validator}
  alias Domain.{Accounts, Actors}
  alias Domain.Auth.{Authorizer, Subject, Context, Permission, Roles, Role, Identity}
  alias Domain.Auth.{Adapters, Provider}

  @default_session_duration_hours %{
    account_admin_user: 3,
    account_user: 24 * 7
  }

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

  def fetch_active_provider_by_id(id, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         true <- Validator.valid_uuid?(id) do
      Provider.Query.by_id(id)
      |> Provider.Query.not_disabled()
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch()
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

  def list_active_providers_for_account(%Accounts.Account{} = account) do
    Provider.Query.by_account_id(account.id)
    |> Provider.Query.not_disabled()
    |> Repo.list()
  end

  def new_provider(%Accounts.Account{} = account, attrs \\ %{}) do
    Provider.Changeset.create_changeset(account, attrs)
    |> Adapters.provider_changeset()
  end

  def create_provider(%Accounts.Account{} = account, attrs, %Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         :ok <- Accounts.ensure_has_access_to(subject, account),
         changeset =
           Provider.Changeset.create_changeset(account, attrs, subject)
           |> Adapters.provider_changeset(),
         {:ok, provider} <- Repo.insert(changeset) do
      Adapters.ensure_provisioned(provider)
    end
  end

  def create_provider(%Accounts.Account{} = account, attrs) do
    changeset =
      Provider.Changeset.create_changeset(account, attrs)
      |> Adapters.provider_changeset()

    with {:ok, provider} <- Repo.insert(changeset) do
      Adapters.ensure_provisioned(provider)
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
    |> Provider.Query.not_disabled()
    |> Provider.Query.by_account_id(account_id)
    |> Provider.Query.lock()
    |> Repo.exists?()
  end

  def fetch_provider_capabilities!(%Provider{} = provider) do
    Adapters.fetch_capabilities!(provider)
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

  def create_identity(
        %Actors.Actor{} = actor,
        %Provider{} = provider,
        provider_identifier,
        provider_attrs \\ %{}
      ) do
    Identity.Changeset.create_identity(actor, provider, provider_identifier)
    |> Adapters.identity_changeset(provider, provider_attrs)
    |> Repo.insert()
  end

  def replace_identity(
        %Identity{} = identity,
        provider_identifier,
        provider_attrs \\ %{},
        %Subject{} = subject
      ) do
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
        Identity.Changeset.create_identity(
          identity.actor,
          identity.provider,
          provider_identifier,
          subject
        )
        |> Adapters.identity_changeset(identity.provider, provider_attrs)
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

  def sign_in(%Provider{} = provider, id_or_provider_identifier, secret, user_agent, remote_ip) do
    identity_queryable =
      Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_id_or_provider_identifier(id_or_provider_identifier)

    with {:ok, identity} <- Repo.fetch(identity_queryable),
         {:ok, identity, expires_at} <- Adapters.verify_secret(provider, identity, secret) do
      {:ok, build_subject(identity, expires_at, user_agent, remote_ip)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_secret} -> {:error, :unauthorized}
      {:error, :expired_secret} -> {:error, :unauthorized}
    end
  end

  def sign_in(%Provider{} = provider, payload, user_agent, remote_ip) do
    with {:ok, identity, expires_at} <-
           Adapters.verify_identity(provider, payload) do
      {:ok, build_subject(identity, expires_at, user_agent, remote_ip)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid} -> {:error, :unauthorized}
      {:error, :expired} -> {:error, :unauthorized}
    end
  end

  def sign_in(session_token, user_agent, remote_ip) when is_binary(session_token) do
    with {:ok, identity, expires_at} <-
           verify_session_token(session_token, user_agent, remote_ip) do
      {:ok, build_subject(identity, expires_at, user_agent, remote_ip)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_token} -> {:error, :unauthorized}
      {:error, :expired_token} -> {:error, :unauthorized}
      {:error, :unauthorized_browser} -> {:error, :unauthorized}
    end
  end

  def fetch_identity_by_provider_and_identifier(%Provider{} = provider, provider_identifier) do
    Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.by_provider_identifier(provider_identifier)
    |> Repo.fetch()
  end

  @doc false
  def build_subject(%Identity{} = identity, expires_at, user_agent, remote_ip)
      when is_binary(user_agent) and is_tuple(remote_ip) do
    identity =
      identity
      |> Identity.Changeset.sign_in_identity(user_agent, remote_ip)
      |> Repo.update!()

    identity_with_preloads = Repo.preload(identity, [:account, :actor])
    permissions = fetch_type_permissions!(identity_with_preloads.actor.type)

    %Subject{
      identity: identity,
      actor: identity_with_preloads.actor,
      permissions: permissions,
      account: identity_with_preloads.account,
      expires_at: build_subject_expires_at(identity_with_preloads.actor, expires_at),
      context: %Context{remote_ip: remote_ip, user_agent: user_agent}
    }
  end

  defp build_subject_expires_at(%Actors.Actor{} = actor, expires_at) do
    default_session_duration_hours = Map.fetch!(@default_session_duration_hours, actor.type)
    expires_at || DateTime.utc_now() |> DateTime.add(default_session_duration_hours, :hour)
  end

  # Session

  def create_session_token_from_subject(%Subject{} = subject) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    # TODO: we don't want client token to be invalid if you reconnect client from a different ip,
    # for the clients that move between cellular towers
    # TODO: we want to show all sessions in a UI so persist them to DB
    payload = session_token_payload(subject)
    max_age = DateTime.diff(subject.expires_at, DateTime.utc_now(), :second)

    {:ok, Plug.Crypto.sign(key_base, salt, payload, max_age: max_age)}
  end

  def create_access_token_for_identity(%Identity{} = identity) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    payload = {:identity, identity.id, identity.provider_virtual_state.secret, :ignore}
    {:ok, expires_at, 0} = DateTime.from_iso8601(identity.provider_state["expires_at"])
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

  defp verify_session_token(token, user_agent, remote_ip) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)

    case Plug.Crypto.verify(key_base, salt, token) do
      {:ok, payload} -> verify_session_token_payload(token, payload, user_agent, remote_ip)
      {:error, :invalid} -> {:error, :invalid_token}
      {:error, :expired} -> {:error, :expired_token}
    end
  end

  defp verify_session_token_payload(
         _token,
         {:identity, identity_id, secret, :ignore},
         _user_agent,
         _remote_ip
       ) do
    with {:ok, identity} <- fetch_identity_by_id(identity_id),
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

  defp verify_session_token_payload(
         token,
         {:identity, identity_id, context_payload},
         user_agent,
         remote_ip
       ) do
    with {:ok, identity} <- fetch_identity_by_id(identity_id),
         true <- context_payload == session_context_payload(remote_ip, user_agent),
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
end
