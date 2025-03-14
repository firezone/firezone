defmodule Domain.Auth do
  @doc """
  This module is the core of our security, it is designed to have multiple layers of
  protection and provide guidance for the developers to avoid common security pitfalls.

  ## Authentication

  Authentication is split into two core components:

  1. *Sign In* - exchange of a secret (IdP ID token or username/password) for our internal token.

     This token is stored in the database (see `Domain.Tokens` module) and then encoded to be
     stored in browser session or on mobile clients. For more details see "Tokens" section below.

  2. Authentication - verification of the token and extraction of the subject from it.

  ## Authorization and Subject

  Authorization is a domain concern because it's tightly coupled with the business logic
  and allows better control over the access to the data. Plus makes it more secure iterating
  faster on the UI/UX without risking to compromise security.

  Every function directly or indirectly called by the end user MUST have a Subject
  as last or second to last argument, implementation of the functions MUST use
  it's own context `Authorizer` module (that implements behaviour `Domain.Auth.Authorizer`)
  to filter the data based on the account and permissions of the subject.

  As an extra measure, whenever a function performs an action on an object that is not
  further re-queried using the `for_subject/1` the implementation MUST check that the subject
  has access to given object. It can be done by one of `ensure_has_access_to?/2` functions
  added to domain contexts responsible for the given schema, eg. `Domain.Accounts.ensure_has_access_to/2`.

  Only exception is the authentication flow where user cannot contain the subject yet,
  but such queries MUST be filtered by the `account_id` and use indexes to prevent
  simple DDoS attacks.

  ## Tokens

  ### Color Coding

  The tokens are color coded using a `type` field, which means that a token issued for a browser session
  cannot be used for client calls and vice versa. Type of the token also limits permissions that will
  be later added to the subject.

  You can find all the token types in enum value of `type` field in `Domain.Tokens.Token` schema.

  ### Secure client exchange

  The tokens consists of two parts: client-supplied nonce (typically 32-byte hex-encoded string) and
  server-generated fragment.

  The server-generated fragment is additionally signed using `Phoenix.Token` to prevent tampering with it
  and make sure that database lookups won't be made for invalid tokens. See `Domain.Tokens.encode_fragment!/1` for
  more details.

  ### Expiration

  Token expiration depends on the context in which it can be used and is limited by
  `@max_session_duration_hours` to prevent extremely long-lived tokens for
  `clients` and `browsers`. For more details see `token_expires_at/3`.

  ## Identity Providers

  You can find all the IdP adapters in `Domain.Auth.Adapters` module.
  """
  use Supervisor
  require Ecto.Query
  alias Domain.Repo
  alias Domain.{Accounts, Actors, Tokens}
  alias Domain.Auth.{Authorizer, Subject, Context, Permission, Roles, Role}
  alias Domain.Auth.{Adapters, Provider}
  alias Domain.Auth.Identity

  # This session duration is used when IdP doesn't return the token expiration date,
  # or no IdP is used (eg. sign in via email or userpass).
  @default_session_duration_hours [
    browser: [
      account_admin_user: 10,
      account_user: 10
    ],
    client: [
      account_admin_user: 24 * 7,
      account_user: 24 * 7
    ]
  ]

  # We don't want to allow extremely long-lived sessions for clients and browsers
  # even if IdP returns them.
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

  def all_user_provisioned_provider_adapters!(%Accounts.Account{} = account) do
    idp_sync_enabled? = Accounts.idp_sync_enabled?(account)

    Adapters.list_user_provisioned_adapters!()
    |> Map.keys()
    |> Enum.map(fn adapter ->
      capabilities = Adapters.fetch_capabilities!(adapter)
      requires_idp_sync_feature? = capabilities[:default_provisioner] == :custom
      enabled_for_account? = idp_sync_enabled? or not requires_idp_sync_feature?
      {adapter, enabled: enabled_for_account?, sync: requires_idp_sync_feature?}
    end)
  end

  def fetch_provider_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()),
         true <- Repo.valid_uuid?(id) do
      Provider.Query.all()
      |> Provider.Query.by_id(id)
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch(Provider.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # used to during auth flow in the UI where Subject doesn't exist yet
  def fetch_active_provider_by_id(id, opts \\ []) do
    if Repo.valid_uuid?(id) do
      Provider.Query.not_disabled()
      |> Provider.Query.by_id(id)
      |> Repo.fetch(Provider.Query, opts)
    else
      {:error, :not_found}
    end
  end

  @doc """
  This functions allows to fetch singleton providers like `email` or `token`.
  """
  def fetch_active_provider_by_adapter(adapter, %Subject{} = subject, opts \\ [])
      when adapter in [:email, :userpass] do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.not_disabled()
      |> Provider.Query.by_adapter(adapter)
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch(Provider.Query, opts)
    end
  end

  def list_providers(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.not_deleted()
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.list(Provider.Query, opts)
    end
  end

  # used to build list of auth options for the UI
  def all_active_providers_for_account!(%Accounts.Account{} = account) do
    Provider.Query.not_disabled()
    |> Provider.Query.by_account_id(account.id)
    |> Repo.all()
  end

  def all_third_party_providers!(%Subject{} = subject) do
    Provider.Query.not_deleted()
    |> Provider.Query.by_account_id(subject.account.id)
    |> Provider.Query.by_adapter({:not_in, [:email, :userpass]})
    |> Authorizer.for_subject(Provider, subject)
    |> Repo.all()
  end

  def all_providers!(%Subject{} = subject) do
    Provider.Query.not_deleted()
    |> Provider.Query.by_account_id(subject.account.id)
    |> Authorizer.for_subject(Provider, subject)
    |> Repo.all()
  end

  def all_providers_pending_token_refresh_by_adapter!(adapter) do
    datetime_filter = DateTime.utc_now() |> DateTime.add(30, :minute)

    Provider.Query.not_disabled()
    |> Provider.Query.by_adapter(adapter)
    |> Provider.Query.by_provisioner(:custom)
    |> Provider.Query.by_non_empty_refresh_token()
    |> Provider.Query.token_expires_at({:lt, datetime_filter})
    |> Repo.all()
  end

  def all_providers_pending_sync_by_adapter!(adapter) do
    Provider.Query.not_disabled()
    |> Provider.Query.by_adapter(adapter)
    |> Provider.Query.by_provisioner(:custom)
    |> Provider.Query.only_ready_to_be_synced()
    |> Repo.all()
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

  # used for testing and seeding the database
  @doc false
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
    mutate_provider(provider, subject, fn provider ->
      Provider.Changeset.update(provider, attrs)
      |> Adapters.provider_changeset()
    end)
  end

  def disable_provider(%Provider{} = provider, %Subject{} = subject) do
    mutate_provider(provider, subject, fn provider ->
      if other_active_providers_exist?(provider) do
        {:ok, _tokens} = Tokens.delete_tokens_for(provider, subject)
        Provider.Changeset.disable_provider(provider)
      else
        :cant_disable_the_last_provider
      end
    end)
  end

  def enable_provider(%Provider{} = provider, %Subject{} = subject) do
    mutate_provider(provider, subject, &Provider.Changeset.enable_provider/1)
  end

  def delete_provider(%Provider{} = provider, %Subject{} = subject) do
    provider
    |> mutate_provider(subject, fn provider ->
      if other_active_providers_exist?(provider) do
        :ok = delete_identities_for(provider, subject)
        {:ok, _groups} = Actors.delete_groups_for(provider, subject)
        Provider.Changeset.delete_provider(provider)
      else
        :cant_delete_the_last_provider
      end
    end)
    |> case do
      {:ok, provider} ->
        Adapters.ensure_deprovisioned(provider)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enable_group_filters_for(%Provider{} = provider, %Subject{} = subject) do
    mutate_provider(provider, subject, &Provider.Changeset.enable_group_filters/1)
  end

  def disable_group_filters_for(%Provider{} = provider, %Subject{} = subject) do
    mutate_provider(provider, subject, &Provider.Changeset.disable_group_filters/1)
  end

  defp mutate_provider(%Provider{} = provider, %Subject{} = subject, callback)
       when is_function(callback, 1) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_providers_permission()) do
      Provider.Query.not_deleted()
      |> Provider.Query.by_id(provider.id)
      |> Authorizer.for_subject(Provider, subject)
      |> Repo.fetch_and_update(Provider.Query, with: callback)
    end
  end

  defp other_active_providers_exist?(%Provider{id: id, account_id: account_id}) do
    Provider.Query.not_disabled()
    |> Provider.Query.by_id({:not, id})
    |> Provider.Query.by_account_id(account_id)
    |> Provider.Query.lock()
    |> Repo.exists?()
  end

  def fetch_provider_capabilities!(%Provider{} = provider) do
    Adapters.fetch_capabilities!(provider)
  end

  # Identities

  def max_last_seen_at_by_actor_ids(actor_ids) do
    Identity.Query.not_deleted()
    |> Identity.Query.by_actor_id({:in, actor_ids})
    |> Identity.Query.max_last_seen_at_grouped_by_actor_id()
    |> Repo.all()
    |> Enum.reduce(%{}, fn %{actor_id: id, max: max}, acc ->
      Map.put(acc, id, max)
    end)
  end

  # used during email auth flow
  def fetch_active_identity_by_provider_and_identifier(
        %Provider{adapter: :email} = provider,
        provider_identifier,
        opts \\ []
      ) do
    Identity.Query.not_disabled()
    |> Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.by_account_id(provider.account_id)
    |> Identity.Query.by_provider_identifier(provider_identifier)
    |> Repo.fetch(Identity.Query, opts)
  end

  def fetch_identity_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()),
         true <- Repo.valid_uuid?(id) do
      Identity.Query.not_deleted()
      |> Identity.Query.by_id(id)
      |> Authorizer.for_subject(Identity, subject)
      |> Repo.fetch(Identity.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # TODO: can be replaced with peek for consistency
  def fetch_identities_count_grouped_by_provider_id(%Subject{} = subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()) do
      identities =
        Identity.Query.not_deleted()
        |> Identity.Query.group_by_provider_id()
        |> Authorizer.for_subject(Identity, subject)
        |> Repo.all()
        |> Enum.reduce(%{}, fn %{provider_id: id, count: count}, acc ->
          Map.put(acc, id, count)
        end)

      {:ok, identities}
    end
  end

  def all_identities_for(%Actors.Actor{} = actor, opts \\ []) do
    Identity.Query.not_deleted()
    |> Identity.Query.by_actor_id(actor.id)
    |> Repo.all(opts)
  end

  def list_identities_for(%Actors.Actor{} = actor, %Subject{} = subject, opts \\ []) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()) do
      Identity.Query.not_deleted()
      |> Identity.Query.by_actor_id(actor.id)
      |> Authorizer.for_subject(Identity, subject)
      |> Repo.list(Identity.Query, opts)
    end
  end

  def sync_provider_identities(filtered_memberships, %Provider{} = provider, attrs_list) do
    Identity.Sync.sync_provider_identities(filtered_memberships, provider, attrs_list)
  end

  def all_actor_ids_by_membership_rules!(account_id, membership_rules) do
    Identity.Query.not_disabled()
    |> Identity.Query.by_account_id(account_id)
    |> Identity.Query.by_membership_rules(membership_rules)
    |> Identity.Query.returning_distinct_actor_ids()
    |> Repo.all()
  end

  def get_identity_email(%Identity{} = identity) do
    provider_email(identity) || identity.provider_identifier
  end

  def identity_has_email?(%Identity{} = identity) do
    not is_nil(provider_email(identity)) or identity.provider.adapter == :email or
      identity.provider_identifier =~ "@"
  end

  defp provider_email(%Identity{} = identity) do
    get_in(identity.provider_state, ["userinfo", "email"])
  end

  # used by IdP adapters
  def upsert_identity(%Actors.Actor{} = actor, %Provider{} = provider, attrs) do
    Identity.Changeset.create_identity(actor, provider, attrs)
    |> Adapters.identity_changeset(provider)
    |> Repo.insert(
      conflict_target:
        {:unsafe_fragment,
         ~s/(account_id, provider_id, provider_identifier) WHERE deleted_at IS NULL/},
      on_conflict: {:replace, [:provider_state]},
      returning: true
    )
    |> case do
      {:ok, identity} ->
        {:ok, _groups} = Actors.update_dynamic_group_memberships(actor.account_id)
        {:ok, identity}

      {:error, changeset} ->
        {:error, changeset}
    end
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

  # used during sign up flow
  def create_identity(
        %Actors.Actor{account_id: account_id} = actor,
        %Provider{account_id: account_id} = provider,
        attrs
      ) do
    attrs =
      attrs
      |> maybe_put_email()
      |> maybe_put_identifier()

    Identity.Changeset.create_identity(actor, provider, attrs)
    |> Adapters.identity_changeset(provider)
    |> Repo.insert()
    |> case do
      {:ok, identity} ->
        {:ok, _groups} = Actors.update_dynamic_group_memberships(account_id)
        {:ok, identity}

      {:error, changeset} ->
        {:error, changeset}
    end
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
        Identity.Query.not_deleted()
        |> Identity.Query.by_id(identity.id)
        |> Identity.Query.lock()
        |> Identity.Query.with_preloaded_assoc(:inner, :actor)
        |> Identity.Query.with_preloaded_assoc(:inner, :provider)
        |> Repo.fetch(Identity.Query)
      end)
      |> Ecto.Multi.insert(:new_identity, fn %{identity: identity} ->
        Identity.Changeset.create_identity(identity.actor, identity.provider, attrs, subject)
        |> Adapters.identity_changeset(identity.provider)
      end)
      |> Ecto.Multi.run(:delete_tokens, fn _repo, %{identity: identity} ->
        {:ok, _tokens} = Tokens.delete_tokens_for(identity, subject)
      end)
      |> Ecto.Multi.update(:deleted_identity, fn %{identity: identity} ->
        Identity.Changeset.delete_identity(identity)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{new_identity: identity}} ->
          {:ok, _groups} = Actors.update_dynamic_group_memberships(identity.account_id)
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
      Identity.Query.not_deleted()
      |> Identity.Query.by_id(identity.id)
      |> Authorizer.for_subject(Identity, subject)
      |> Repo.fetch_and_update(Identity.Query,
        with: fn identity ->
          {:ok, _tokens} = Tokens.delete_tokens_for(identity, subject)
          Identity.Changeset.delete_identity(identity)
        end
      )
      |> case do
        {:ok, identity} ->
          {:ok, _groups} = Actors.update_dynamic_group_memberships(identity.account_id)
          {:ok, identity}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # for idp sync
  def delete_identities_for(%Actors.Actor{} = actor) do
    Identity.Query.not_deleted()
    |> Identity.Query.by_actor_id(actor.id)
    |> Identity.Query.by_account_id(actor.account_id)
    |> Repo.update_all(set: [deleted_at: DateTime.utc_now(), provider_state: %{}])
  end

  def delete_identities_for(%Actors.Actor{} = actor, %Subject{} = subject) do
    Identity.Query.not_deleted()
    |> Identity.Query.by_actor_id(actor.id)
    |> Identity.Query.by_account_id(actor.account_id)
    |> delete_identities(actor, subject)
  end

  def delete_identities_for(%Provider{} = provider, %Subject{} = subject) do
    Identity.Query.not_deleted()
    |> Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.by_account_id(provider.account_id)
    |> delete_identities(provider, subject)
  end

  defp delete_identities(queryable, assoc, subject) do
    with :ok <- ensure_has_permissions(subject, Authorizer.manage_identities_permission()) do
      {:ok, _tokens} = Tokens.delete_tokens_for(assoc, subject)

      {_count, nil} =
        queryable
        |> Authorizer.for_subject(Identity, subject)
        |> Repo.update_all(set: [deleted_at: DateTime.utc_now(), provider_state: %{}])

      {:ok, _groups} = Actors.update_dynamic_group_memberships(assoc.account_id)

      :ok
    end
  end

  def identity_deleted?(%{deleted_at: nil}), do: false
  def identity_deleted?(_identity), do: true

  # Sign Up / In / Off

  @doc """
  Sign In is an exchange of a secret (IdP token or username/password) for a token tied to it's original context.
  """
  def sign_in(
        %Provider{disabled_at: disabled_at},
        _id_or_provider_identifier,
        _token_nonce,
        _secret,
        %Context{}
      )
      when not is_nil(disabled_at) do
    {:error, :unauthorized}
  end

  def sign_in(
        %Provider{deleted_at: deleted_at},
        _id_or_provider_identifier,
        _token_nonce,
        _secret,
        %Context{}
      )
      when not is_nil(deleted_at) do
    {:error, :unauthorized}
  end

  def sign_in(
        %Provider{} = provider,
        id_or_provider_identifier,
        token_nonce,
        secret,
        %Context{} = context
      ) do
    identity_queryable =
      Identity.Query.not_disabled()
      |> Identity.Query.by_account_id(provider.account_id)
      |> Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_id_or_provider_identifier(id_or_provider_identifier)

    with {:ok, identity} <- Repo.fetch(identity_queryable, Identity.Query),
         {:ok, identity, expires_at} <-
           Adapters.verify_secret(provider, identity, context, secret),
         identity = Repo.preload(identity, :actor),
         {:ok, token} <- create_token(identity, context, token_nonce, expires_at) do
      {:ok, identity, Tokens.encode_fragment!(token)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid_secret} -> {:error, :unauthorized}
      {:error, :expired_secret} -> {:error, :unauthorized}
      {:error, %Ecto.Changeset{}} -> {:error, :malformed_request}
    end
  end

  def sign_in(%Provider{disabled_at: disabled_at}, _token_nonce, _payload, %Context{})
      when not is_nil(disabled_at) do
    {:error, :unauthorized}
  end

  def sign_in(%Provider{deleted_at: deleted_at}, _token_nonce, _payload, %Context{})
      when not is_nil(deleted_at) do
    {:error, :unauthorized}
  end

  def sign_in(%Provider{} = provider, token_nonce, payload, %Context{} = context) do
    with {:ok, identity, expires_at} <- Adapters.verify_and_update_identity(provider, payload),
         identity = Repo.preload(identity, :actor),
         {:ok, token} <- create_token(identity, context, token_nonce, expires_at) do
      {:ok, identity, Tokens.encode_fragment!(token)}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, :invalid} -> {:error, :unauthorized}
      {:error, :expired} -> {:error, :unauthorized}
      {:error, :internal_error} -> {:error, :internal_error}
      {:error, %Ecto.Changeset{}} -> {:error, :malformed_request}
    end
  end

  # used in tests and seeds
  @doc false
  def create_token(%Identity{} = identity, %{type: type} = context, nonce, expires_at)
      when type in [:browser, :client] do
    identity = Repo.preload(identity, :actor)
    expires_at = token_expires_at(identity.actor, context, expires_at)

    Tokens.create_token(%{
      type: type,
      secret_nonce: nonce,
      secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
      account_id: identity.account_id,
      actor_id: identity.actor_id,
      identity_id: identity.id,
      expires_at: expires_at,
      created_by_user_agent: context.user_agent,
      created_by_remote_ip: context.remote_ip
    })
  end

  # default expiration is used when IdP/adapter doesn't set the expiration date
  defp token_expires_at(%Actors.Actor{} = actor, %Context{} = context, nil) do
    default_session_duration_hours =
      @default_session_duration_hours
      |> Keyword.fetch!(context.type)
      |> Keyword.fetch!(actor.type)

    DateTime.utc_now() |> DateTime.add(default_session_duration_hours, :hour)
  end

  # For client tokens we extend the expiration to the default one
  # for the sake of user experience, because:
  #
  # - some of the IdPs don't allow to refresh the token without user interaction;
  # - some of the IdPs have short-lived hardcoded tokens
  #
  defp token_expires_at(%Actors.Actor{} = actor, %Context{type: :client}, _expires_at) do
    default_session_duration_hours =
      @default_session_duration_hours
      |> Keyword.fetch!(:client)
      |> Keyword.fetch!(actor.type)

    DateTime.utc_now() |> DateTime.add(default_session_duration_hours, :hour)
  end

  # when IdP sets the expiration we ensure it's not longer than the default session duration
  # to prevent extremely long-lived browser sessions
  defp token_expires_at(%Actors.Actor{} = actor, %Context{type: :browser}, expires_at) do
    max_session_duration_hours =
      @max_session_duration_hours
      |> Keyword.fetch!(:browser)
      |> Keyword.fetch!(actor.type)

    max_expires_at = DateTime.utc_now() |> DateTime.add(max_session_duration_hours, :hour)
    Enum.min([expires_at, max_expires_at], DateTime)
  end

  @doc """
  Revokes the Firezone token used by the given subject and,
  if IdP was used for Sign In, revokes the IdP token too by redirecting user to IdP logout endpoint.
  """
  def sign_out(%Subject{} = subject, redirect_url) do
    {:ok, _token} = Tokens.delete_token_for(subject)
    identity = Repo.preload(subject.identity, :provider)
    Adapters.sign_out(identity.provider, identity, redirect_url)
  end

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

  # used in tests and seeds
  @doc false
  def build_subject(%Tokens.Token{type: type} = token, %Context{} = context)
      when type in [:browser, :client, :api_client] do
    account = Accounts.fetch_account_by_id!(token.account_id)

    with {:ok, actor} <- Actors.fetch_active_actor_by_id(token.actor_id) do
      permissions = fetch_type_permissions!(actor.type)

      %Subject{
        identity: nil,
        actor: actor,
        permissions: permissions,
        account: account,
        expires_at: token.expires_at,
        context: context,
        token_id: token.id
      }
      |> maybe_fetch_subject_identity(token)
    end
  end

  defp maybe_fetch_subject_identity(%{actor: %{type: :service_account}} = subject, _token) do
    {:ok, subject}
  end

  defp maybe_fetch_subject_identity(%{actor: %{type: :api_client}} = subject, _token) do
    {:ok, subject}
  end

  defp maybe_fetch_subject_identity(_subject, %{identity_id: nil}) do
    {:error, :not_found}
  end

  # Maybe we need a NOWAIT here to prevent timeouts when background jobs are updating the identity
  defp maybe_fetch_subject_identity(subject, token) do
    Identity.Query.not_disabled()
    |> Identity.Query.by_id(token.identity_id)
    |> Ecto.Query.select([identities: identities], identities)
    |> Repo.update_all(
      set: [
        last_seen_user_agent: subject.context.user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_remote_ip_location_region: subject.context.remote_ip_location_region,
        last_seen_remote_ip_location_city: subject.context.remote_ip_location_city,
        last_seen_remote_ip_location_lat: subject.context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: subject.context.remote_ip_location_lon,
        last_seen_at: DateTime.utc_now()
      ]
    )
    |> case do
      {1, [identity]} -> {:ok, %{subject | identity: identity}}
      {0, []} -> {:error, :not_found}
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

  def ensure_has_access_to(%Subject{} = subject, %Provider{} = provider) do
    if subject.account.id == provider.account_id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

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

  def valid_email?(email) do
    to_string(email) =~ email_regex()
  end

  def email_regex do
    # Regex to check if string is in the shape of an email
    ~r/^[^\s]+@[^\s]+\.[^\s]+$/
  end

  defp maybe_put_email(params) do
    email =
      params["email"]
      |> to_string
      |> String.trim()

    identifier =
      params["provider_identifier"]
      |> to_string()
      |> String.trim()

    cond do
      valid_email?(email) ->
        params

      valid_email?(identifier) ->
        Map.put(params, "email", identifier)

      true ->
        params
    end
  end

  defp maybe_put_identifier(params) do
    email =
      params["email"]
      |> to_string()
      |> String.trim()

    identifier =
      params["provider_identifier"]
      |> to_string()
      |> String.trim()

    cond do
      identifier != "" ->
        params

      valid_email?(email) ->
        Map.put(params, "provider_identifier", email)
        |> Map.put("provider_identifier_confirmation", email)

      true ->
        params
    end
  end
end
