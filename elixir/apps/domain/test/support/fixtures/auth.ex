defmodule Domain.Fixtures.Auth do
  use Domain.Fixture
  alias Domain.Auth

  def user_password, do: "Hello w0rld!"
  def remote_ip, do: {100, 64, 100, 58}
  def user_agent, do: "iOS/12.5 (iPhone) connlib/0.7.412"
  def email, do: "user-#{unique_integer()}@example.com"

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :email, name: name}) do
    "user-#{unique_integer()}@#{String.downcase(name)}.com"
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :openid_connect}) do
    Ecto.UUID.generate()
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :google_workspace}) do
    Ecto.UUID.generate()
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :token}) do
    Ecto.UUID.generate()
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :userpass, name: name}) do
    "user-#{unique_integer()}@#{String.downcase(name)}.com"
  end

  def provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "provider-#{unique_integer()}",
      adapter: :email,
      adapter_config: %{},
      created_by: :system,
      provisioner: :manual
    })
  end

  def openid_connect_adapter_config(overrides \\ %{}) do
    for {k, v} <- overrides,
        into: %{
          "discovery_document_uri" =>
            "https://firezone.example.com/.well-known/openid-configuration",
          "client_id" => "client-id-#{unique_integer()}",
          "client_secret" => "client-secret-#{unique_integer()}",
          "response_type" => "code",
          "scope" => "openid email profile"
        } do
      {to_string(k), v}
    end
  end

  def create_email_provider(attrs \\ %{}) do
    attrs = provider_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def start_and_create_openid_connect_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_openid_connect_provider()

    {provider, bypass}
  end

  def start_and_create_google_workspace_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri:
          "http://localhost:#{bypass.port}/.well-known/openid-configuration",
        scope: Domain.Auth.Adapters.GoogleWorkspace.Settings.scope() |> Enum.join(" ")
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_google_workspace_provider()

    {provider, bypass}
  end

  def create_openid_connect_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :openid_connect,
        provisioner: :just_in_time
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)

    provider =
      provider
      |> Ecto.Changeset.change(
        disabled_at: nil,
        adapter_state: %{}
      )
      |> Repo.update!()

    provider
  end

  def create_google_workspace_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :google_workspace,
        provisioner: :custom
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)

    update!(provider,
      disabled_at: nil,
      adapter_state: %{
        "access_token" => "OIDC_ACCESS_TOKEN",
        "refresh_token" => "OIDC_REFRESH_TOKEN",
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :day),
        "claims" => "openid email profile offline_access"
      }
    )
  end

  def create_userpass_provider(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{adapter: :userpass})
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_token_provider(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{adapter: :token})
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def disable_provider(provider) do
    provider = Repo.preload(provider, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: provider.account,
        actor: [type: :account_admin_user]
      )

    {:ok, group} = Auth.disable_provider(provider, subject)
    group
  end

  def delete_provider(provider) do
    update!(provider, deleted_at: DateTime.utc_now())
  end

  def fail_provider_sync(provider) do
    update!(provider, last_sync_error: "Message from fixture", last_syncs_failed: 3)
  end

  def finish_provider_sync(provider) do
    update!(provider,
      last_synced_at: DateTime.utc_now(),
      last_sync_error: nil,
      last_syncs_failed: 0
    )
  end

  def identity_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      provider_virtual_state: %{}
    })
  end

  def create_identity(attrs \\ %{}) do
    attrs = identity_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        {provider, _bypass} =
          assoc_attrs
          |> Enum.into(%{account: account})
          |> start_and_create_openid_connect_provider()

        provider
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        })
        |> Fixtures.Actors.create_actor()
      end)

    attrs = Map.put(attrs, :provider_identifier, provider_identifier)
    attrs = Map.put(attrs, :provider_identifier_confirmation, provider_identifier)

    {:ok, identity} = Auth.upsert_identity(actor, provider, attrs)

    attrs = Map.take(attrs, [:provider_state, :created_by])

    identity
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  def delete_identity(identity) do
    update!(identity, deleted_at: DateTime.utc_now())
  end

  def build_context(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {type, attrs} = Map.pop(attrs, :type, :browser)

    {user_agent, attrs} =
      Map.pop_lazy(attrs, :user_agent, fn ->
        user_agent()
      end)

    {remote_ip, attrs} =
      Map.pop_lazy(attrs, :remote_ip, fn ->
        remote_ip()
      end)

    {remote_ip_location_region, attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_region, fn ->
        Enum.random(["US", "UA"])
      end)

    {remote_ip_location_city, attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_city, fn ->
        Enum.random(["Odessa", "New York"])
      end)

    {remote_ip_location_lat, attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_city, fn ->
        Enum.random([37.7758, 40.7128])
      end)

    {remote_ip_location_lon, _attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_city, fn ->
        Enum.random([-122.4128, -74.0060])
      end)

    %Auth.Context{
      type: type,
      remote_ip: remote_ip,
      remote_ip_location_region: remote_ip_location_region,
      remote_ip_location_city: remote_ip_location_city,
      remote_ip_location_lat: remote_ip_location_lat,
      remote_ip_location_lon: remote_ip_location_lon,
      user_agent: user_agent
    }
  end

  def create_subject(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        relation = attrs[:provider] || attrs[:actor] || attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Accounts.Account, relation.account_id)
        else
          Fixtures.Accounts.create_account(assoc_attrs)
        end
      end)

    {provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Auth.Provider, relation.provider_id)
        else
          {provider, _bypass} =
            assoc_attrs
            |> Enum.into(%{account: account})
            |> start_and_create_openid_connect_provider()

          provider
        end
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Actors.Actor, relation.actor_id)
        else
          assoc_attrs
          |> Enum.into(%{
            type: :account_admin_user,
            account: account,
            provider: provider,
            provider_identifier: provider_identifier
          })
          |> Fixtures.Actors.create_actor()
        end
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          actor: actor,
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        })
        |> create_identity()
      end)

    {expires_at, attrs} =
      Map.pop_lazy(attrs, :expires_at, fn ->
        DateTime.utc_now() |> DateTime.add(60, :second)
      end)

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        build_context(assoc_attrs)
      end)

    {token, _attrs} =
      pop_assoc_fixture(attrs, :token, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          type: context.type,
          identity_id: identity.id,
          expires_at: expires_at
        })
        |> Fixtures.Tokens.create_token()
      end)

    Auth.build_subject(token, identity, context)
  end

  def remove_permissions(%Auth.Subject{} = subject) do
    %{subject | permissions: MapSet.new()}
  end

  def set_permissions(%Auth.Subject{} = subject, permissions) do
    %{subject | permissions: MapSet.new(permissions)}
  end

  def add_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.put(subject.permissions, permission)}
  end
end
