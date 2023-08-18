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

    {bypass, provider}
  end

  def start_and_create_google_workspace_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_google_workspace_provider()

    {bypass, provider}
  end

  def create_openid_connect_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :openid_connect,
        provisioner: :just_in_time
      }
      |> Map.merge(attrs)
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
      |> Map.merge(attrs)
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
    attrs = provider_attrs(adapter: :userpass)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_token_provider(attrs \\ %{}) do
    attrs = provider_attrs(adapter: :token)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def disable_provider(provider) do
    provider = Repo.preload(provider, :account)
    subject = admin_subject_for_account(provider.account)
    {:ok, group} = Auth.disable_provider(provider, subject)
    group
  end

  def identity_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      provider_virtual_state: %{},
      provider_identifier: Ecto.UUID.generate()
    })
  end

  def create_identity(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

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

    {provider_state, attrs} =
      Map.pop(attrs, :provider_state)

    {actor, _attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        })
        |> Fixtures.Actors.create_actor()
      end)

    attrs =
      attrs
      |> Map.put(:provider_identifier, provider_identifier)
      |> identity_attrs()

    {:ok, identity} = Auth.upsert_identity(actor, provider, attrs)

    if provider_state do
      identity
      |> Ecto.Changeset.change(provider_state: provider_state)
      |> Repo.update!()
    else
      identity
    end
  end

  def delete_identity(identity) do
    update!(identity, deleted_at: DateTime.utc_now())
  end

  def create_subject do
    account = Fixtures.Accounts.create_account()

    {provider, _bypass} =
      start_and_create_openid_connect_provider(account: account)

    actor =
      Fixtures.Actors.create_actor(
        type: :account_admin_user,
        account: account,
        provider: provider
      )

    identity = create_identity(actor: actor, account: account, provider: provider)
    create_subject(identity)
  end

  def create_subject(%Auth.Identity{} = identity) do
    identity = Repo.preload(identity, [:account, :actor])

    %Auth.Subject{
      identity: identity,
      actor: identity.actor,
      permissions: Auth.Roles.build(identity.actor.type).permissions,
      account: identity.account,
      expires_at: DateTime.utc_now() |> DateTime.add(60, :second),
      context: %Auth.Context{remote_ip: remote_ip(), user_agent: user_agent()}
    }
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
