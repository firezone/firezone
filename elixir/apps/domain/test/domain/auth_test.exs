defmodule Domain.AuthTest do
  use Domain.DataCase, async: true
  import Domain.Auth
  alias Domain.{Auth, Tokens}
  alias Domain.Auth.Authorizer

  # Providers

  describe "all_user_provisioned_provider_adapters!/1" do
    test "returns list of enabled adapters for an account" do
      account = Fixtures.Accounts.create_account(features: %{idp_sync: true})

      assert Enum.sort(all_user_provisioned_provider_adapters!(account)) == [
               google_workspace: [enabled: true, sync: true],
               jumpcloud: [enabled: true, sync: true],
               microsoft_entra: [enabled: true, sync: true],
               mock: [enabled: true, sync: true],
               okta: [enabled: true, sync: true],
               openid_connect: [enabled: true, sync: false]
             ]

      account = Fixtures.Accounts.create_account(features: %{idp_sync: false})

      assert Enum.sort(all_user_provisioned_provider_adapters!(account)) == [
               google_workspace: [enabled: false, sync: true],
               jumpcloud: [enabled: false, sync: true],
               microsoft_entra: [enabled: false, sync: true],
               mock: [enabled: false, sync: true],
               okta: [enabled: false, sync: true],
               openid_connect: [enabled: true, sync: false]
             ]
    end
  end

  describe "fetch_provider_by_id/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error when provider does not exist", %{subject: subject} do
      assert fetch_provider_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when on invalid UUIDv4", %{subject: subject} do
      assert fetch_provider_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns deleted provider", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _provider} = delete_provider(provider, subject)

      assert {:ok, fetched_provider} = fetch_provider_by_id(provider.id, subject)
      assert fetched_provider.id == provider.id
    end

    test "does not return provider from other accounts", %{subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider()
      assert fetch_provider_by_id(provider.id, subject) == {:error, :not_found}
    end

    test "returns provider", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      assert {:ok, fetched_provider} = fetch_provider_by_id(provider.id, subject)
      assert fetched_provider.id == provider.id
    end

    test "returns error when subject cannot view providers", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_provider_by_id("foo", subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end
  end

  describe "fetch_active_provider_by_id/2" do
    test "returns error when provider does not exist" do
      assert fetch_active_provider_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when provider is disabled" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_userpass_provider(account: account)
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [
            type: :account_admin_user
          ],
          account: account,
          provider: provider
        )

      subject =
        Fixtures.Auth.create_subject(
          account: account,
          identity: identity,
          actor: [type: :account_admin_user]
        )

      {:ok, _provider} = disable_provider(provider, subject)

      assert fetch_active_provider_by_id(provider.id) == {:error, :not_found}
    end

    test "returns error when provider is deleted" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_userpass_provider(account: account)
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider
        )

      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _provider} = delete_provider(provider, subject)

      assert fetch_active_provider_by_id(provider.id) == {:error, :not_found}
    end

    test "returns provider" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider()
      assert {:ok, fetched_provider} = fetch_active_provider_by_id(provider.id)
      assert fetched_provider.id == provider.id
    end
  end

  describe "fetch_active_provider_by_adapter/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error when provider does not exist", %{subject: subject} do
      assert fetch_active_provider_by_adapter(:email, subject) == {:error, :not_found}
      assert fetch_active_provider_by_adapter(:userpass, subject) == {:error, :not_found}
    end

    test "raises when invalid adapter is used", %{subject: subject} do
      for adapter <- [:foo, :openid_connect, :google_workspace] do
        assert_raise FunctionClauseError, fn ->
          fetch_active_provider_by_adapter(adapter, subject)
        end
      end
    end

    test "returns error when provider is disabled", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _provider} = disable_provider(provider, subject)

      assert fetch_active_provider_by_adapter(:userpass, subject) == {:error, :not_found}
    end

    test "returns error when provider is deleted", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _provider} = delete_provider(provider, subject)

      assert fetch_active_provider_by_adapter(:userpass, subject) == {:error, :not_found}
    end

    test "returns provider and preloads", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      assert {:ok, fetched_provider} =
               fetch_active_provider_by_adapter(:userpass, subject, preload: [:account])

      assert fetched_provider.id == provider.id
      assert Ecto.assoc_loaded?(fetched_provider.account)
    end

    test "does not return providers from other account", %{subject: subject} do
      Fixtures.Auth.create_userpass_provider()
      assert fetch_active_provider_by_adapter(:userpass, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot view providers", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_active_provider_by_adapter(:email, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end
  end

  describe "list_providers/2" do
    test "returns all not soft-deleted providers for a given account" do
      account = Fixtures.Accounts.create_account()

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      Fixtures.Auth.create_userpass_provider(account: account)
      email_provider = Fixtures.Auth.create_email_provider(account: account)

      {oidc_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      Fixtures.Auth.create_email_provider()

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: email_provider
        )

      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, _provider} = disable_provider(oidc_provider, subject)
      {:ok, _provider} = delete_provider(email_provider, subject)

      assert {:ok, providers, _metadata} = list_providers(subject)
      assert length(providers) == 2
    end

    test "doesn't return providers from other accounts" do
      Fixtures.Auth.create_userpass_provider()

      subject = Fixtures.Auth.create_subject()
      assert {:ok, [provider], _metadata} = list_providers(subject)
      assert provider.account_id == subject.account.id
    end

    test "returns error when subject cannot manage providers" do
      account = Fixtures.Accounts.create_account()

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account
        )

      subject = Fixtures.Auth.create_subject(identity: identity)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_providers(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end
  end

  describe "all_active_providers_for_account!/1" do
    test "returns active providers for a given account" do
      account = Fixtures.Accounts.create_account()

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      userpass_provider = Fixtures.Auth.create_userpass_provider(account: account)
      email_provider = Fixtures.Auth.create_email_provider(account: account)

      {oidc_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: email_provider
        )

      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, _provider} = disable_provider(oidc_provider, subject)
      {:ok, _provider} = delete_provider(email_provider, subject)

      assert [provider] = all_active_providers_for_account!(account)
      assert provider.id == userpass_provider.id
    end

    test "doesn't return providers from other accounts" do
      Fixtures.Auth.create_userpass_provider()

      account = Fixtures.Accounts.create_account()
      assert all_active_providers_for_account!(account) == []
    end
  end

  describe "all_providers_pending_token_refresh_by_adapter!/1" do
    test "returns empty list if there are no providers for an adapter" do
      assert all_providers_pending_token_refresh_by_adapter!(:google_workspace) == []
    end

    test "returns empty list if there are no providers with token that will expire soon" do
      Fixtures.Auth.start_and_create_google_workspace_provider()
      assert all_providers_pending_token_refresh_by_adapter!(:google_workspace) == []
    end

    test "ignores disabled providers" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        disabled_at: DateTime.utc_now(),
        adapter_state: %{
          "access_token" => "OIDC_ACCESS_TOKEN",
          "refresh_token" => "OIDC_REFRESH_TOKEN",
          "expires_at" => DateTime.utc_now()
        }
      })

      assert all_providers_pending_token_refresh_by_adapter!(:google_workspace) == []
    end

    test "ignores deleted providers" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        deleted_at: DateTime.utc_now(),
        adapter_state: %{
          "access_token" => "OIDC_ACCESS_TOKEN",
          "refresh_token" => "OIDC_REFRESH_TOKEN",
          "expires_at" => DateTime.utc_now()
        }
      })

      assert all_providers_pending_token_refresh_by_adapter!(:google_workspace) == []
    end

    test "ignores non-custom provisioners" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        provisioner: :manual,
        adapter_state: %{
          "access_token" => "OIDC_ACCESS_TOKEN",
          "refresh_token" => "OIDC_REFRESH_TOKEN",
          "claims" => "openid email profile offline_access",
          "expires_at" => DateTime.utc_now()
        }
      })

      assert all_providers_pending_token_refresh_by_adapter!(:google_workspace) == []
    end

    test "returns providers with tokens that will expire in ~30 minutes" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        adapter_state: %{
          "access_token" => "OIDC_ACCESS_TOKEN",
          "refresh_token" => "OIDC_REFRESH_TOKEN",
          "expires_at" => DateTime.utc_now() |> DateTime.add(28, :minute),
          "claims" => "openid email profile offline_access"
        }
      })

      assert [fetched_provider] =
               all_providers_pending_token_refresh_by_adapter!(:google_workspace)

      assert fetched_provider.id == provider.id
    end

    test "doesn't return providers that don't have refresh tokens" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        adapter_state: %{
          "access_token" => "OIDC_ACCESS_TOKEN",
          "refresh_token" => nil,
          "expires_at" => DateTime.utc_now() |> DateTime.add(28, :minute),
          "claims" => "openid email profile offline_access"
        }
      })

      assert all_providers_pending_token_refresh_by_adapter!(:google_workspace) == []
    end
  end

  describe "all_providers_pending_sync_by_adapter!/1" do
    test "returns empty list if there are no providers for an adapter" do
      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []
    end

    test "returns empty list if there are no providers that synced more than 10m ago" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      Domain.Fixture.update!(provider, %{last_synced_at: DateTime.utc_now()})
      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []
    end

    test "ignores disabled providers" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        disabled_at: DateTime.utc_now(),
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []
    end

    test "ignores deleted providers" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        deleted_at: DateTime.utc_now(),
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []
    end

    test "ignores non-custom provisioners" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        provisioner: :manual,
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []
    end

    test "returns providers that synced more than 10m ago" do
      {provider1, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      {provider2, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      eleven_minutes_ago = DateTime.utc_now() |> DateTime.add(-11, :minute)
      Domain.Fixture.update!(provider2, %{last_synced_at: eleven_minutes_ago})

      providers = all_providers_pending_sync_by_adapter!(:google_workspace)

      assert Enum.map(providers, & &1.id) |> Enum.sort() ==
               Enum.sort([provider1.id, provider2.id])
    end

    test "uses 1/2 regular timeout backoff for failed attempts" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      # backoff: 10 minutes * (1 + 3 ^ 2) = 100 minutes
      provider = Domain.Fixture.update!(provider, %{last_sync_error: "foo", last_syncs_failed: 3})

      ninety_nine_minute_ago = DateTime.utc_now() |> DateTime.add(-99, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: ninety_nine_minute_ago})
      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []

      one_hundred_one_minute_ago = DateTime.utc_now() |> DateTime.add(-101, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: one_hundred_one_minute_ago})
      assert [_provider] = all_providers_pending_sync_by_adapter!(:google_workspace)

      # max backoff: 4 hours
      provider = Domain.Fixture.update!(provider, %{last_syncs_failed: 300})

      three_hours_fifty_nine_minutes_ago = DateTime.utc_now() |> DateTime.add(-239, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: three_hours_fifty_nine_minutes_ago})
      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []

      four_hours_one_minute_ago = DateTime.utc_now() |> DateTime.add(-241, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: four_hours_one_minute_ago})
      assert [_provider] = all_providers_pending_sync_by_adapter!(:google_workspace)
    end

    test "ignores providers with disabled sync" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      eleven_minutes_ago = DateTime.utc_now() |> DateTime.add(-11, :minute)

      Domain.Fixture.update!(provider, %{
        last_synced_at: eleven_minutes_ago,
        sync_disabled_at: DateTime.utc_now()
      })

      assert all_providers_pending_sync_by_adapter!(:google_workspace) == []
    end
  end

  describe "new_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

      provider_adapter_config =
        Fixtures.Auth.openid_connect_adapter_config(
          discovery_document_uri:
            "http://localhost:#{bypass.port}/.well-known/openid-configuration"
        )

      %{
        account: account,
        provider_adapter_config: provider_adapter_config,
        bypass: bypass
      }
    end

    test "returns changeset with given changes", %{
      account: account,
      provider_adapter_config: provider_adapter_config
    } do
      assert changeset = new_provider(account)
      assert %Ecto.Changeset{data: %Domain.Auth.Provider{}} = changeset
      assert changeset.changes == %{account_id: account.id, created_by: :system}

      provider_attrs =
        Fixtures.Auth.provider_attrs(
          adapter: :openid_connect,
          adapter_config: provider_adapter_config
        )

      assert changeset = new_provider(account, provider_attrs)
      assert %Ecto.Changeset{data: %Domain.Auth.Provider{}} = changeset
      assert changeset.changes.name == provider_attrs.name
      assert changeset.changes.provisioner == provider_attrs.provisioner
      assert changeset.changes.adapter == provider_attrs.adapter

      assert changeset.changes.adapter_config.changes.client_id ==
               provider_attrs.adapter_config["client_id"]
    end
  end

  describe "create_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{
        account: account
      }
    end

    test "returns changeset error when required attrs are missing", %{
      account: account
    } do
      assert {:error, changeset} = create_provider(account, %{})
      refute changeset.valid?

      assert errors_on(changeset) == %{
               adapter: ["can't be blank"],
               adapter_config: ["can't be blank"],
               name: ["can't be blank"],
               provisioner: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{
      account: account
    } do
      attrs =
        Fixtures.Auth.provider_attrs(
          name: String.duplicate("A", 256),
          adapter: :foo,
          adapter_config: :bar
        )

      assert {:error, changeset} = create_provider(account, attrs)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               adapter: ["is invalid"],
               adapter_config: ["is invalid"]
             }
    end

    test "returns error if email provider is already enabled", %{
      account: account
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      Fixtures.Auth.create_email_provider(account: account)
      attrs = Fixtures.Auth.provider_attrs(adapter: :email)
      assert {:error, changeset} = create_provider(account, attrs)
      refute changeset.valid?
      assert errors_on(changeset) == %{base: ["this provider is already enabled"]}
    end

    test "returns error if userpass provider is already enabled", %{
      account: account
    } do
      Fixtures.Auth.create_userpass_provider(account: account)
      attrs = Fixtures.Auth.provider_attrs(adapter: :userpass)
      assert {:error, changeset} = create_provider(account, attrs)
      refute changeset.valid?
      assert errors_on(changeset) == %{base: ["this provider is already enabled"]}
    end

    test "returns error if openid connect provider is already enabled", %{
      account: account
    } do
      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      attrs =
        Fixtures.Auth.provider_attrs(
          adapter: :openid_connect,
          adapter_config: provider.adapter_config,
          provisioner: :manual
        )

      assert {:error, changeset} = create_provider(account, attrs)
      refute changeset.valid?
      assert errors_on(changeset) == %{base: ["this provider is already connected"]}
    end

    test "returns error if provider is disabled by account feature flag", %{
      account: account
    } do
      {:ok, account} = Domain.Accounts.update_account(account, %{features: %{idp_sync: false}})

      attrs =
        Fixtures.Auth.provider_attrs(
          adapter: :google_workspace,
          adapter_config: %{client_id: "foo", client_secret: "bar"},
          provisioner: :custom
        )

      assert {:error, changeset} = create_provider(account, attrs)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               adapter: ["is invalid"],
               adapter_config: %{service_account_json_key: ["can't be blank"]}
             }
    end

    test "creates a provider", %{
      account: account
    } do
      attrs = Fixtures.Auth.provider_attrs()

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      assert {:ok, provider} = create_provider(account, attrs)

      assert provider.name == attrs.name
      assert provider.adapter == attrs.adapter
      assert provider.adapter_config == attrs.adapter_config
      assert provider.account_id == account.id

      assert provider.created_by == :system
      assert is_nil(provider.created_by_identity_id)

      assert is_nil(provider.disabled_at)
      assert is_nil(provider.deleted_at)
    end

    test "returns error when email provider is disabled", %{
      account: account
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, false)
      attrs = Fixtures.Auth.provider_attrs()

      assert {:error, changeset} = create_provider(account, attrs)
      assert errors_on(changeset) == %{adapter: ["email adapter is not configured"]}
    end
  end

  describe "create_provider/3" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{
        account: account
      }
    end

    test "returns error when subject cannot create providers", %{
      account: account
    } do
      subject =
        Fixtures.Auth.create_subject()
        |> Fixtures.Auth.remove_permissions()

      assert create_provider(account, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end

    test "returns error when subject tries to create a provider in another account", %{
      account: other_account
    } do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert create_provider(other_account, %{}, subject) == {:error, :unauthorized}
    end

    test "persists identity that created the provider", %{account: account} do
      attrs = Fixtures.Auth.provider_attrs()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert {:ok, provider} = create_provider(account, attrs, subject)

      assert provider.created_by == :identity
      assert provider.created_by_identity_id == subject.identity.id
    end
  end

  describe "change_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      %{
        account: account,
        provider: provider,
        bypass: bypass
      }
    end

    test "returns changeset with given changes", %{provider: provider} do
      provider_attrs = Fixtures.Auth.provider_attrs()

      assert changeset = change_provider(provider, provider_attrs)
      assert %Ecto.Changeset{data: %Domain.Auth.Provider{}} = changeset

      assert changeset.changes.name == provider_attrs.name
    end
  end

  describe "update_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      %{
        account: account,
        actor: actor,
        identity: identity,
        provider: provider,
        bypass: bypass,
        subject: subject
      }
    end

    test "returns changeset error when required attrs are missing", %{
      provider: provider,
      subject: subject
    } do
      attrs = %{name: nil, adapter: nil, adapter_config: nil}
      assert {:error, changeset} = update_provider(provider, attrs, subject)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               adapter_config: ["can't be blank"],
               name: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{
      provider: provider,
      subject: subject
    } do
      attrs =
        Fixtures.Auth.provider_attrs(
          name: String.duplicate("A", 256),
          adapter: :foo,
          adapter_config: :bar,
          provisioner: :foo
        )

      assert {:error, changeset} = update_provider(provider, attrs, subject)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               name: ["should be at most 255 character(s)"],
               adapter_config: ["is invalid"],
               provisioner: ["is invalid"]
             }
    end

    test "updates a provider", %{
      provider: provider,
      subject: subject
    } do
      attrs =
        Fixtures.Auth.provider_attrs(
          provisioner: :manual,
          adapter: :foobar,
          adapter_config: %{
            client_id: "foo"
          }
        )

      assert {:ok, provider} = update_provider(provider, attrs, subject)

      assert provider.name == attrs.name
      assert provider.adapter == provider.adapter
      assert provider.adapter_config["client_id"] == attrs.adapter_config.client_id
      assert provider.account_id == subject.account.id

      assert is_nil(provider.disabled_at)
      assert is_nil(provider.deleted_at)
    end

    test "returns error when subject cannot manage providers", %{
      provider: provider,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_provider(provider, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end

    test "returns error when subject tries to update an account in another account", %{
      provider: provider
    } do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      assert update_provider(provider, %{}, subject) == {:error, :not_found}
    end
  end

  describe "disable_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject,
        provider: provider
      }
    end

    test "disables a given provider", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      other_provider = Fixtures.Auth.create_userpass_provider(account: account)

      assert {:ok, provider} = disable_provider(provider, subject)
      assert provider.disabled_at

      assert provider = Repo.get(Auth.Provider, provider.id)
      assert provider.disabled_at

      assert other_provider = Repo.get(Auth.Provider, other_provider.id)
      assert is_nil(other_provider.disabled_at)
    end

    test "deletes tokens issues for provider identities", %{
      account: account,
      subject: subject
    } do
      password = "Firezone1234!"
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      token = Fixtures.Tokens.create_token(account: account, identity: identity)

      assert {:ok, _provider} = disable_provider(provider, subject)

      assert token = Repo.get(Tokens.Token, token.id)
      assert token.deleted_at
    end

    test "expires provider flows", %{
      account: account,
      provider: provider,
      identity: identity,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      Fixtures.Flows.create_flow(
        account: account,
        subject: subject,
        client: client
      )

      assert {:ok, _provider} = disable_provider(provider, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
    end

    test "returns error when trying to disable the last provider", %{
      subject: subject,
      provider: provider
    } do
      assert disable_provider(provider, subject) == {:error, :cant_disable_the_last_provider}
    end

    test "last provider check ignores providers in other accounts", %{
      subject: subject,
      provider: provider
    } do
      Fixtures.Auth.create_email_provider()

      assert disable_provider(provider, subject) == {:error, :cant_disable_the_last_provider}
    end

    test "last provider check ignores disabled providers", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      other_provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _other_provider} = disable_provider(other_provider, subject)

      assert disable_provider(provider, subject) == {:error, :cant_disable_the_last_provider}
    end

    test "does not do anything when an provider is disabled twice", %{
      subject: subject,
      account: account
    } do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      assert {:ok, _provider} = disable_provider(provider, subject)
      assert {:ok, provider} = disable_provider(provider, subject)
      assert {:ok, _provider} = disable_provider(provider, subject)
    end

    test "does not allow to disable providers in other accounts", %{
      subject: subject
    } do
      provider = Fixtures.Auth.create_userpass_provider()
      assert disable_provider(provider, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot disable providers", %{
      subject: subject,
      provider: provider
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert disable_provider(provider, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end
  end

  describe "enable_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      {:ok, provider} = disable_provider(provider, subject)

      %{
        account: account,
        actor: actor,
        subject: subject,
        provider: provider
      }
    end

    test "enables a given provider", %{
      subject: subject,
      provider: provider
    } do
      assert provider.disabled_at
      assert {:ok, provider} = enable_provider(provider, subject)
      assert is_nil(provider.disabled_at)

      assert provider = Repo.get(Auth.Provider, provider.id)
      assert is_nil(provider.disabled_at)
    end

    test "does not do anything when an provider is enabled twice", %{
      subject: subject,
      provider: provider
    } do
      assert {:ok, _provider} = enable_provider(provider, subject)
      assert {:ok, provider} = enable_provider(provider, subject)
      assert {:ok, _provider} = enable_provider(provider, subject)
    end

    test "does not allow to enable providers in other accounts", %{
      subject: subject
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider()
      assert enable_provider(provider, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot enable providers", %{
      subject: subject,
      provider: provider
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert enable_provider(provider, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end
  end

  describe "delete_provider/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject,
        provider: provider
      }
    end

    test "deletes a given provider", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      other_provider = Fixtures.Auth.create_userpass_provider(account: account)

      assert {:ok, provider} = delete_provider(provider, subject)
      assert provider.deleted_at

      assert provider = Repo.get(Auth.Provider, provider.id)
      assert provider.deleted_at

      assert other_provider = Repo.get(Auth.Provider, other_provider.id)
      assert is_nil(other_provider.deleted_at)
    end

    test "deletes provider identities and tokens", %{
      account: account,
      subject: subject
    } do
      password = "Firezone1234!"
      provider = Fixtures.Auth.create_userpass_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      token = Fixtures.Tokens.create_token(account: account, identity: identity)

      assert {:ok, _provider} = delete_provider(provider, subject)

      assert identity = Repo.get(Auth.Identity, identity.id)
      assert identity.deleted_at

      assert token = Repo.get(Tokens.Token, token.id)
      assert token.deleted_at
    end

    test "deletes provider actor groups", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      actor_group = Fixtures.Actors.create_group(account: account, provider: provider)

      assert {:ok, _provider} = delete_provider(provider, subject)

      assert actor_group = Repo.get(Domain.Actors.Group, actor_group.id)
      assert actor_group.deleted_at
    end

    test "expires provider flows", %{
      account: account,
      provider: provider,
      identity: identity,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      Fixtures.Flows.create_flow(
        account: account,
        subject: subject,
        client: client
      )

      assert {:ok, _provider} = delete_provider(provider, subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
    end

    test "returns error when trying to delete the last provider", %{
      subject: subject,
      provider: provider
    } do
      assert delete_provider(provider, subject) == {:error, :cant_delete_the_last_provider}
    end

    test "last provider check ignores providers in other accounts", %{
      subject: subject,
      provider: provider
    } do
      Fixtures.Auth.create_email_provider()

      assert delete_provider(provider, subject) == {:error, :cant_delete_the_last_provider}
    end

    test "last provider check ignores deleted providers", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      other_provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _other_provider} = delete_provider(other_provider, subject)

      assert delete_provider(provider, subject) == {:error, :cant_delete_the_last_provider}
    end

    test "returns error when trying to delete the last provider using a race condition" do
      for _ <- 0..50 do
        test_pid = self()

        Task.async(fn ->
          allow_child_sandbox_access(test_pid)

          account = Fixtures.Accounts.create_account()

          provider_one = Fixtures.Auth.create_email_provider(account: account)
          provider_two = Fixtures.Auth.create_userpass_provider(account: account)

          actor =
            Fixtures.Actors.create_actor(
              type: :account_admin_user,
              account: account,
              provider: provider_one
            )

          identity =
            Fixtures.Auth.create_identity(
              account: account,
              actor: actor,
              provider: provider_one
            )

          subject = Fixtures.Auth.create_subject(identity: identity)

          for provider <- [provider_two, provider_one] do
            Task.async(fn ->
              allow_child_sandbox_access(test_pid)
              delete_provider(provider, subject)
            end)
          end
          |> Task.await_many()

          assert Auth.Provider.Query.not_deleted()
                 |> Auth.Provider.Query.by_account_id(account.id)
                 |> Repo.aggregate(:count) == 1
        end)
      end
      |> Task.await_many()
    end

    test "returns error when provider is already deleted", %{
      subject: subject,
      account: account
    } do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      assert {:ok, deleted_provider} = delete_provider(provider, subject)
      assert delete_provider(provider, subject) == {:error, :not_found}
      assert delete_provider(deleted_provider, subject) == {:error, :not_found}
    end

    test "does not allow to delete providers in other accounts", %{
      subject: subject
    } do
      provider = Fixtures.Auth.create_userpass_provider()
      assert delete_provider(provider, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot delete providers", %{
      subject: subject,
      provider: provider
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_provider(provider, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_providers_permission()]}}
    end
  end

  describe "fetch_provider_capabilities!/1" do
    test "returns provider capabilities" do
      provider = Fixtures.Auth.create_userpass_provider()

      assert fetch_provider_capabilities!(provider) == [
               provisioners: [:manual],
               default_provisioner: :manual,
               parent_adapter: nil
             ]
    end
  end

  # Identities

  describe "max_last_seen_at_by_actor_ids/1" do
    test "returns maximum last seen at for given actor ids" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account)
      now = DateTime.utc_now()

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor,
          last_seen_at: now
        )

      Fixtures.Auth.create_identity(
        account: account,
        actor: actor,
        last_seen_at: DateTime.add(now, -1, :hour)
      )

      assert max_last_seen_at_by_actor_ids([actor.id]) == %{actor.id => identity.last_seen_at}
    end
  end

  describe "fetch_active_identity_by_provider_and_identifier/3" do
    test "returns nothing when identity doesn't exist" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      assert fetch_active_identity_by_provider_and_identifier(provider, provider_identifier) ==
               {:error, :not_found}
    end

    test "returns error when identity actor is deleted" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: provider_identifier
      )

      assert {:ok, _} =
               fetch_active_identity_by_provider_and_identifier(provider, provider_identifier)

      Fixtures.Actors.delete(actor)

      assert fetch_active_identity_by_provider_and_identifier(provider, provider_identifier) ==
               {:error, :not_found}
    end

    test "returns error when identity actor is disabled" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: provider_identifier
      )

      assert {:ok, _} =
               fetch_active_identity_by_provider_and_identifier(provider, provider_identifier)

      Fixtures.Actors.disable(actor)

      assert fetch_active_identity_by_provider_and_identifier(provider, provider_identifier) ==
               {:error, :not_found}
    end

    test "returns error when identity provider is deleted" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: provider_identifier
      )

      assert {:ok, _} =
               fetch_active_identity_by_provider_and_identifier(provider, provider_identifier)

      Fixtures.Auth.delete_provider(provider)

      assert fetch_active_identity_by_provider_and_identifier(provider, provider_identifier) ==
               {:error, :not_found}
    end

    test "returns error when identity provider is disabled" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: provider_identifier
      )

      assert {:ok, _} =
               fetch_active_identity_by_provider_and_identifier(provider, provider_identifier)

      Fixtures.Auth.disable_provider(provider)

      assert fetch_active_identity_by_provider_and_identifier(provider, provider_identifier) ==
               {:error, :not_found}
    end

    test "returns identity by provider identifier" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        )

      assert {:ok, fetched_identity} =
               fetch_active_identity_by_provider_and_identifier(provider, provider_identifier,
                 preload: [:account]
               )

      assert fetched_identity.id == identity.id
      assert Ecto.assoc_loaded?(fetched_identity.account)
    end
  end

  describe "fetch_identity_by_id/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error when identity does not exist", %{subject: subject} do
      assert fetch_identity_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
      assert fetch_identity_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns error when identity is deleted", %{account: account, subject: subject} do
      identity = Fixtures.Auth.create_identity(account: account)
      {:ok, _identity} = delete_identity(identity, subject)

      assert fetch_identity_by_id(identity.id, subject) == {:error, :not_found}
    end

    test "returns identity", %{account: account, subject: subject} do
      identity = Fixtures.Auth.create_identity(account: account)
      assert {:ok, fetched_identity} = fetch_identity_by_id(identity.id, subject)
      assert fetched_identity.id == identity.id
    end

    test "does not return identities from other account", %{subject: subject} do
      identity = Fixtures.Auth.create_identity()
      assert fetch_identity_by_id(identity.id, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot view identities", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_identity_by_id("foo", subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_identities_permission()]}}
    end
  end

  describe "fetch_identities_count_grouped_by_provider_id/1" do
    test "returns count of actor identities by provider id" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {google_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account, name: "google")

      {vault_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account, name: "vault")

      Fixtures.Auth.create_identity(account: account, provider: google_provider)
      Fixtures.Auth.create_identity(account: account, provider: vault_provider)
      Fixtures.Auth.create_identity(account: account, provider: vault_provider)

      assert fetch_identities_count_grouped_by_provider_id(subject) ==
               {:ok,
                %{
                  identity.provider_id => 1,
                  google_provider.id => 1,
                  vault_provider.id => 2
                }}
    end

    test "doesn't count identities in other accounts" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      Fixtures.Auth.create_identity()

      assert fetch_identities_count_grouped_by_provider_id(subject) ==
               {:ok, %{identity.provider_id => 1}}
    end
  end

  describe "sync_provider_identities/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      %{account: account, provider: provider, bypass: bypass}
    end

    test "upserts new identities and actors", %{provider: provider} do
      attrs_list = [
        %{
          "actor" => %{
            "name" => "Brian Manifold",
            "type" => "account_user"
          },
          "provider_identifier" => "USER_ID1"
        },
        %{
          "actor" => %{
            "name" => "Jennie Smith",
            "type" => "account_user"
          },
          "provider_identifier" => "USER_ID2"
        }
      ]

      provider_identifiers = Enum.map(attrs_list, & &1["provider_identifier"])
      actor_names = Enum.map(attrs_list, & &1["actor"]["name"])

      assert {:ok,
              %{
                identities: [],
                plan: {insert, [], []},
                inserted: [_actor1, _actor2],
                updated: [],
                deleted: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = sync_provider_identities(provider, attrs_list)

      assert Enum.all?(provider_identifiers, &(&1 in insert))

      identities = Auth.Identity |> Repo.all() |> Repo.preload(:actor)
      assert length(identities) == 2

      for identity <- identities do
        assert identity.inserted_at
        assert identity.created_by == :provider
        assert identity.provider_id == provider.id
        assert identity.provider_identifier in provider_identifiers
        assert identity.actor.name in actor_names
        assert identity.actor.last_synced_at

        assert Map.get(actor_ids_by_provider_identifier, identity.provider_identifier) ==
                 identity.actor_id
      end

      assert Enum.count(actor_ids_by_provider_identifier) == 2
    end

    test "updates existing actors", %{account: account, provider: provider} do
      identity1 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID1",
          actor: [type: :account_admin_user]
        )

      identity2 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID2"
        )

      attrs_list = [
        %{
          "actor" => %{
            "name" => "Brian Manifold",
            "type" => "account_user"
          },
          "provider_identifier" => "USER_ID1"
        },
        %{
          "actor" => %{
            "name" => "Jennie Smith",
            "type" => "account_user"
          },
          "provider_identifier" => "USER_ID2"
        }
      ]

      assert {:ok,
              %{
                identities: [_identity1, _identity2],
                plan: {[], update, []},
                deleted: [],
                updated: [_updated_identity1, _updated_identity2],
                inserted: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = sync_provider_identities(provider, attrs_list)

      assert length(update) == 2
      assert identity1.provider_identifier in update
      assert identity2.provider_identifier in update

      actor = Repo.get(Domain.Actors.Actor, identity1.actor_id)
      assert actor.type == :account_admin_user
      assert actor.name == "Brian Manifold"
      assert Map.get(actor_ids_by_provider_identifier, identity1.provider_identifier) == actor.id

      actor = Repo.get(Domain.Actors.Actor, identity2.actor_id)
      assert actor.type == :account_user
      assert actor.name == "Jennie Smith"
      assert Map.get(actor_ids_by_provider_identifier, identity2.provider_identifier) == actor.id

      assert Enum.count(actor_ids_by_provider_identifier) == 2
    end

    test "does not re-create actors for deleted identities", %{
      account: account,
      provider: provider
    } do
      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID1",
          actor: [type: :account_admin_user]
        )
        |> Fixtures.Auth.delete_identity()

      attrs_list = [
        %{
          "actor" => %{
            "name" => "Brian Manifold",
            "type" => "account_user"
          },
          "provider_identifier" => "USER_ID1"
        }
      ]

      assert {:ok,
              %{
                identities: [fetched_identity],
                plan: {[], ["USER_ID1"], []},
                deleted: [],
                inserted: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = sync_provider_identities(provider, attrs_list)

      assert fetched_identity.actor_id == identity.actor_id
      assert actor_ids_by_provider_identifier == %{"USER_ID1" => identity.actor_id}

      identity = Repo.get(Auth.Identity, identity.id)
      assert identity.actor_id == identity.actor_id
      refute identity.deleted_at

      actor = Repo.get(Domain.Actors.Actor, identity.actor_id)
      assert actor.name == "Brian Manifold"
    end

    test "does not attempt to delete identities that are already deleted", %{
      account: account,
      provider: provider
    } do
      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID1",
          actor: [type: :account_admin_user]
        )
        |> Fixtures.Auth.delete_identity()

      attrs_list = []

      assert {:ok,
              %{
                identities: [fetched_identity],
                plan: {[], [], []},
                deleted: [],
                inserted: [],
                actor_ids_by_provider_identifier: %{}
              }} = sync_provider_identities(provider, attrs_list)

      assert fetched_identity.id == identity.id

      identity = Repo.get(Auth.Identity, identity.id)
      assert identity.deleted_at
    end

    test "deletes removed identities", %{account: account, provider: provider} do
      provider_identifiers = ["USER_ID1", "USER_ID2"]

      deleted_identity_actor = Fixtures.Actors.create_actor(account: account)

      deleted_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: deleted_identity_actor,
          provider_identifier: Enum.at(provider_identifiers, 0)
        )

      deleted_identity_token =
        Fixtures.Tokens.create_token(
          account: account,
          actor: deleted_identity_actor,
          identity: deleted_identity
        )

      deleted_identity_client =
        Fixtures.Clients.create_client(
          account: account,
          actor: deleted_identity_actor,
          identity: deleted_identity
        )

      deleted_identity_flow =
        Fixtures.Flows.create_flow(
          account: account,
          client: deleted_identity_client,
          token_id: deleted_identity_token.id
        )

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_identifier: Enum.at(provider_identifiers, 1)
      )

      :ok = Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{deleted_identity_token.id}")
      :ok = Domain.Flows.subscribe_to_flow_expiration_events(deleted_identity_flow)

      attrs_list = []

      assert {:ok,
              %{
                identities: [_identity1, _identity2],
                plan: {[], [], delete},
                deleted: [deleted_identity1, deleted_identity2],
                inserted: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = sync_provider_identities(provider, attrs_list)

      assert Enum.all?(provider_identifiers, &(&1 in delete))
      assert deleted_identity1.provider_identifier in delete
      assert deleted_identity2.provider_identifier in delete
      assert Repo.aggregate(Auth.Identity, :count) == 9
      assert Repo.aggregate(Auth.Identity.Query.not_deleted(), :count) == 7

      assert Enum.empty?(actor_ids_by_provider_identifier)

      # Signs out users which identity has been deleted
      topic = "sessions:#{deleted_identity_token.id}"
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: nil}

      # Expires flows for signed out user
      flow_id = deleted_identity_flow.id
      assert_receive {:expire_flow, ^flow_id, _client_id, _resource_id}
    end

    test "ignores identities that are not synced from the provider", %{
      account: account,
      provider: provider
    } do
      {other_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: other_provider,
        provider_identifier: "USER_ID1"
      )

      Fixtures.Auth.create_identity(
        account: account,
        provider_identifier: "USER_ID2"
      )

      attrs_list = []

      assert sync_provider_identities(provider, attrs_list) ==
               {:ok,
                %{
                  identities: [],
                  plan: {[], [], []},
                  deleted: [],
                  updated: [],
                  inserted: [],
                  actor_ids_by_provider_identifier: %{}
                }}
    end

    test "returns error on invalid attrs", %{
      provider: provider
    } do
      attrs_list = [
        %{
          "actor" => %{},
          "provider_identifier" => "USER_ID2"
        }
      ]

      assert {:error, changeset} = sync_provider_identities(provider, attrs_list)

      assert errors_on(changeset) == %{
               actor: %{
                 name: ["can't be blank"],
                 type: ["can't be blank"]
               }
             }

      assert Repo.aggregate(Auth.Identity, :count) == 0
      assert Repo.aggregate(Domain.Actors.Actor, :count) == 0
    end

    test "resolves provider identifier conflicts across actors", %{
      account: account,
      provider: provider
    } do
      identity1 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID1",
          actor: [type: :account_admin_user]
        )
        |> Fixtures.Auth.delete_identity()

      identity2 =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          provider_identifier: "USER_ID1",
          actor: [type: :account_admin_user]
        )

      attrs_list = [
        %{
          "actor" => %{
            "name" => "Brian Manifold",
            "type" => "account_user"
          },
          "provider_identifier" => "USER_ID1"
        }
      ]

      assert {:ok,
              %{
                identities: [_identity1, _identity2],
                plan: {[], update, []},
                deleted: [],
                inserted: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = sync_provider_identities(provider, attrs_list)

      assert length(update) == 2
      assert update == ["USER_ID1", "USER_ID1"]

      identity1 = Repo.get(Domain.Auth.Identity, identity1.id) |> Repo.preload(:actor)
      assert identity1.deleted_at
      assert identity1.actor.name != "Brian Manifold"

      identity2 = Repo.get(Domain.Auth.Identity, identity2.id) |> Repo.preload(:actor)
      refute identity2.deleted_at
      assert identity2.actor.name == "Brian Manifold"

      assert Map.get(actor_ids_by_provider_identifier, identity2.provider_identifier) ==
               identity2.actor.id

      assert Enum.count(actor_ids_by_provider_identifier) == 1
    end
  end

  describe "all_actor_ids_by_membership_rules!/2" do
    test "returns actor ids by evaluating membership rules" do
      account = Fixtures.Accounts.create_account()
      identity = Fixtures.Auth.create_identity(account: account)

      rules = [%{operator: true}]

      assert [actor_id] = all_actor_ids_by_membership_rules!(account.id, rules)
      assert actor_id == identity.actor_id
    end

    test "does return identities from other accounts" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_identity()

      rules = [%{operator: true}]

      assert all_actor_ids_by_membership_rules!(account.id, rules) == []
    end

    test "does not return identities for deleted actors" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Auth.create_identity(account: account, actor: actor)
      Fixtures.Actors.delete(actor)

      rules = [%{operator: true}]

      assert all_actor_ids_by_membership_rules!(account.id, rules) == []
    end

    test "does not return identities for disabled actors" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(account: account)
      Fixtures.Auth.create_identity(account: account, actor: actor)
      Fixtures.Actors.disable(actor)

      rules = [%{operator: true}]

      assert all_actor_ids_by_membership_rules!(account.id, rules) == []
    end

    test "allows to use is_in operator" do
      account = Fixtures.Accounts.create_account()

      rules = [%{path: ["claims", "group"], operator: :is_in, values: ["admin"]}]

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      Fixtures.Auth.create_identity(account: account)
      |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "user"}})
      |> Repo.update!()

      assert [actor_id] = all_actor_ids_by_membership_rules!(account.id, rules)
      assert actor_id == identity.actor_id
    end

    test "allows to use is_not_in operator" do
      account = Fixtures.Accounts.create_account()

      rules = [%{path: ["claims", "group"], operator: :is_not_in, values: ["user"]}]

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      Fixtures.Auth.create_identity(account: account)
      |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "user"}})
      |> Repo.update!()

      assert [actor_id] = all_actor_ids_by_membership_rules!(account.id, rules)
      assert actor_id == identity.actor_id
    end

    test "allows to use contains operator" do
      account = Fixtures.Accounts.create_account()

      rules = [%{path: ["claims", "group"], operator: :contains, values: ["ad"]}]

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      Fixtures.Auth.create_identity(account: account)
      |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "foo"}})
      |> Repo.update!()

      assert [actor_id] = all_actor_ids_by_membership_rules!(account.id, rules)
      assert actor_id == identity.actor_id
    end

    test "allows to use does_not_contain operator" do
      account = Fixtures.Accounts.create_account()

      rules = [
        %{path: ["claims", "group"], operator: :does_not_contain, values: ["use"]}
      ]

      identity =
        Fixtures.Auth.create_identity(account: account)
        |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "admin"}})
        |> Repo.update!()

      Fixtures.Auth.create_identity(account: account)
      |> Ecto.Changeset.change(provider_state: %{"claims" => %{"group" => "user"}})
      |> Repo.update!()

      assert [actor_id] = all_actor_ids_by_membership_rules!(account.id, rules)
      assert actor_id == identity.actor_id
    end
  end

  describe "upsert_identity/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      %{account: account, provider: provider, actor: actor}
    end

    test "returns changeset error when required attrs are missing", %{
      provider: provider,
      actor: actor
    } do
      attrs = %{}

      assert {:error, changeset} = upsert_identity(actor, provider, attrs)

      assert errors_on(changeset) == %{
               provider_identifier: ["can't be blank"],
               provider_identifier_confirmation: ["email does not match"]
             }
    end

    test "creates an identity", %{
      provider: provider,
      actor: actor
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:ok, identity} = upsert_identity(actor, provider, attrs)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id

      assert identity.provider_state == %{}
      assert identity.provider_virtual_state == %{}
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end

    test "updates existing identity", %{
      account: account,
      provider: provider,
      actor: actor
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier,
        actor: actor,
        provider_virtual_state: %{"foo" => "bar"}
      )

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:ok, updated_identity} = upsert_identity(actor, provider, attrs)

      assert Repo.one(Auth.Identity).id == updated_identity.id

      assert updated_identity.provider_virtual_state == %{}
      assert updated_identity.provider_state == %{}
    end

    test "updates dynamic group memberships", %{
      account: account,
      provider: provider,
      actor: actor
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      group = Fixtures.Actors.create_managed_group(account: account)

      assert {:ok, _identity} = upsert_identity(actor, provider, attrs)

      group = Repo.preload(group, :memberships, force: true)
      assert [membership] = group.memberships
      assert membership.actor_id == actor.id
    end

    test "returns error when identifier is invalid", %{
      provider: provider,
      actor: actor
    } do
      provider_identifier = Ecto.UUID.generate()

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:error, changeset} = upsert_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier: ["is an invalid email address"]}

      attrs = %{provider_identifier: nil, provider_identifier_confirmation: nil}
      assert {:error, changeset} = upsert_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier: ["can't be blank"]}

      attrs = %{provider_identifier: Fixtures.Auth.email()}
      assert {:error, changeset} = upsert_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier_confirmation: ["email does not match"]}
    end
  end

  describe "new_identity/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)

      %{
        account: account,
        provider: provider,
        actor: actor
      }
    end

    test "returns changeset with given changes", %{
      account: account,
      provider: provider,
      actor: actor
    } do
      account_id = account.id
      actor_id = actor.id
      provider_id = provider.id

      assert changeset = new_identity(actor, provider, %{})
      assert %Ecto.Changeset{data: %Domain.Auth.Identity{}} = changeset

      assert %{
               account_id: ^account_id,
               actor_id: ^actor_id,
               provider_id: ^provider_id,
               provider_state: %{},
               provider_virtual_state: %{}
             } = changeset.changes

      identity_attrs = Fixtures.Auth.identity_attrs()

      assert changeset = new_identity(actor, provider, identity_attrs)
      assert %Ecto.Changeset{data: %Domain.Auth.Identity{}} = changeset

      assert %{
               account_id: ^account_id,
               actor_id: ^actor_id,
               provider_id: ^provider_id,
               provider_state: %{},
               provider_virtual_state: %{},
               created_by: :system
             } = changeset.changes
    end
  end

  describe "create_identity/4" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      subject = Fixtures.Auth.create_subject(actor: actor)

      %{account: account, provider: provider, actor: actor, subject: subject}
    end

    test "returns changeset error when required attrs are missing", %{
      provider: provider,
      actor: actor,
      subject: subject
    } do
      attrs = %{}

      assert {:error, changeset} = create_identity(actor, provider, attrs, subject)

      assert errors_on(changeset) == %{
               provider_identifier: ["can't be blank"],
               provider_identifier_confirmation: ["email does not match"]
             }
    end

    test "creates an identity", %{
      provider: provider,
      actor: actor,
      subject: subject
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:ok, identity} = create_identity(actor, provider, attrs, subject)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id

      assert identity.provider_state == %{}
      assert identity.provider_virtual_state == %{}
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end

    test "updates dynamic group memberships", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      group = Fixtures.Actors.create_managed_group(account: account)

      assert {:ok, _identity} = create_identity(actor, provider, attrs, subject)

      group = Repo.preload(group, :memberships, force: true)
      assert [membership] = group.memberships
      assert membership.actor_id == actor.id
      assert membership.group_id == group.id
    end

    test "returns error when identity already exists", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier,
        actor: actor
      )

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:error, changeset} = create_identity(actor, provider, attrs, subject)
      assert "has already been taken" in errors_on(changeset).provider_identifier
    end

    test "returns error when identifier is invalid", %{
      provider: provider,
      actor: actor,
      subject: subject
    } do
      provider_identifier = Ecto.UUID.generate()

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:error, changeset} = create_identity(actor, provider, attrs, subject)
      assert errors_on(changeset) == %{provider_identifier: ["is an invalid email address"]}

      attrs = %{provider_identifier: nil, provider_identifier_confirmation: nil}
      assert {:error, changeset} = create_identity(actor, provider, attrs, subject)
      assert errors_on(changeset) == %{provider_identifier: ["can't be blank"]}

      attrs = %{provider_identifier: Fixtures.Auth.email()}
      assert {:error, changeset} = create_identity(actor, provider, attrs, subject)
      assert errors_on(changeset) == %{provider_identifier_confirmation: ["email does not match"]}
    end

    test "returns error on missing permissions", %{
      provider: provider,
      actor: actor,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_identity(actor, provider, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_identities_permission()]}}
    end
  end

  describe "create_identity/3" do
    test "creates an identity" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      password = "Firezone1234"

      attrs = %{
        provider_identifier: provider_identifier,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      }

      assert {:ok, identity} = create_identity(actor, provider, attrs)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id
      assert identity.email == nil

      assert %Ecto.Changeset{} = identity.provider_virtual_state

      assert %{"password_hash" => _} = identity.provider_state
      assert %{password_hash: _} = identity.provider_virtual_state.changes
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end

    test "creates an identity when provider_identifier is an email address" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      provider_identifier = Fixtures.Auth.email()

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      password = "Firezone1234"

      attrs = %{
        "provider_identifier" => provider_identifier,
        "provider_virtual_state" => %{"password" => password, "password_confirmation" => password}
      }

      assert {:ok, identity} = create_identity(actor, provider, attrs)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id
      assert identity.email == provider_identifier

      assert %Ecto.Changeset{} = identity.provider_virtual_state

      assert %{"password_hash" => _} = identity.provider_state
      assert %{password_hash: _} = identity.provider_virtual_state.changes
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end

    test "updates dynamic group memberships" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      password = "Firezone1234"

      attrs = %{
        provider_identifier: provider_identifier,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      }

      group = Fixtures.Actors.create_managed_group(account: account)

      assert {:ok, _identity} = create_identity(actor, provider, attrs)

      group = Repo.preload(group, :memberships, force: true)
      assert [membership] = group.memberships
      assert membership.actor_id == actor.id
    end

    test "returns error when identifier is invalid" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      provider_identifier = Ecto.UUID.generate()

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:error, changeset} = create_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier: ["is an invalid email address"]}

      attrs = %{provider_identifier: nil, provider_identifier_confirmation: nil}
      assert {:error, changeset} = create_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier: ["can't be blank"]}

      attrs = %{provider_identifier: Fixtures.Auth.email()}
      assert {:error, changeset} = create_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier_confirmation: ["email does not match"]}
    end

    test "returns error when identity already exists" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier,
        actor: actor,
        provider_state: %{"foo" => "bar"}
      )

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:error, changeset} = create_identity(actor, provider, attrs)
      assert errors_on(changeset) == %{provider_identifier: ["has already been taken"]}
    end
  end

  describe "replace_identity/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject,
        provider: provider
      }
    end

    test "returns error when identity is deleted", %{identity: identity, subject: subject} do
      {:ok, _identity} = delete_identity(identity, subject)
      attrs = %{provider_identifier: Ecto.UUID.generate()}

      assert replace_identity(identity, attrs, subject) == {:error, :not_found}
    end

    test "returns error when provider_identifier is invalid", %{
      identity: identity,
      subject: subject
    } do
      provider_identifier = Ecto.UUID.generate()

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:error, changeset} = replace_identity(identity, attrs, subject)
      assert errors_on(changeset) == %{provider_identifier: ["is an invalid email address"]}

      attrs = %{provider_identifier: nil, provider_identifier_confirmation: nil}
      assert {:error, changeset} = replace_identity(identity, attrs, subject)
      assert errors_on(changeset) == %{provider_identifier: ["can't be blank"]}

      attrs = %{provider_identifier: Fixtures.Auth.email()}
      assert {:error, changeset} = replace_identity(identity, attrs, subject)
      assert errors_on(changeset) == %{provider_identifier_confirmation: ["email does not match"]}

      refute Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "replaces existing identity with a new one", %{
      identity: identity,
      provider: provider,
      subject: subject
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:ok, new_identity} = replace_identity(identity, attrs, subject)

      assert new_identity.provider_identifier == attrs.provider_identifier
      assert new_identity.provider_id == identity.provider_id
      assert new_identity.actor_id == identity.actor_id

      assert new_identity.provider_state == %{}
      assert new_identity.provider_virtual_state == %{}
      assert new_identity.account_id == identity.account_id
      assert is_nil(new_identity.deleted_at)

      assert Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "updates dynamic group memberships", %{
      account: account,
      identity: identity,
      provider: provider,
      subject: subject
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      group = Fixtures.Actors.create_managed_group(account: account)

      assert {:ok, identity} = replace_identity(identity, attrs, subject)

      group = Repo.preload(group, :memberships, force: true)
      assert [membership] = group.memberships
      assert membership.actor_id == identity.actor_id
      assert membership.group_id == group.id
    end

    test "deletes tokens of replaced identity and broadcasts disconnect message", %{
      account: account,
      identity: identity,
      provider: provider,
      subject: subject
    } do
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      token = Fixtures.Tokens.create_token(account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, _new_identity} = replace_identity(identity, attrs, subject)

      assert token = Repo.get(Domain.Tokens.Token, token.id)
      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "returns error when subject cannot delete identities", %{
      identity: identity,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)
      attrs = %{provider_identifier: Ecto.UUID.generate()}

      assert replace_identity(identity, attrs, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Authorizer.manage_identities_permission(),
                      Authorizer.manage_own_identities_permission()
                    ]}
                 ]}}
    end
  end

  describe "delete_identity/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        subject: subject,
        provider: provider
      }
    end

    test "returns error when trying to delete a synced identity", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
          created_by: :provider
        )

      assert delete_identity(identity, subject) == {:error, :cant_delete_synced_identity}
    end

    test "deletes the identity that belongs to a subject actor", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      assert {:ok, deleted_identity} = delete_identity(identity, subject)

      assert deleted_identity.id == identity.id
      assert deleted_identity.deleted_at

      assert Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "updates dynamic group memberships", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      group = Fixtures.Actors.create_managed_group(account: account)

      assert {:ok, _identity} = delete_identity(identity, subject)

      group = Repo.preload(group, :memberships, force: true)
      assert [membership] = group.memberships
      assert membership.actor_id == actor.id
      assert membership.group_id == group.id
    end

    test "deletes identity that belongs to another actor with manage permission", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Authorizer.manage_own_identities_permission())
        |> Fixtures.Auth.add_permission(Authorizer.manage_identities_permission())
        |> Fixtures.Auth.add_permission(Tokens.Authorizer.manage_tokens_permission())
        |> Fixtures.Auth.add_permission(Domain.Flows.Authorizer.create_flows_permission())

      assert {:ok, deleted_identity} = delete_identity(identity, subject)

      assert deleted_identity.id == identity.id
      assert deleted_identity.deleted_at

      assert Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "deletes token and broadcasts message to disconnect the identity sessions", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      token = Fixtures.Tokens.create_token(account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, _deleted_identity} = delete_identity(identity, subject)

      assert token = Repo.get(Domain.Tokens.Token, token.id)
      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "does not delete identity that belongs to another actor with manage_own permission", %{
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity()

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Authorizer.manage_own_identities_permission())

      assert delete_identity(identity, subject) == {:error, :not_found}
    end

    test "does not delete identity that belongs to another actor with just view permission", %{
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity()

      subject =
        subject
        |> Fixtures.Auth.remove_permissions()
        |> Fixtures.Auth.add_permission(Authorizer.manage_own_identities_permission())

      assert delete_identity(identity, subject) == {:error, :not_found}
    end

    test "returns error when identity does not exist", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      assert {:ok, _identity} = delete_identity(identity, subject)
      assert delete_identity(identity, subject) == {:error, :not_found}
    end

    test "returns error when subject cannot delete identities", %{subject: subject} do
      identity = Fixtures.Auth.create_identity()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_identity(identity, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Authorizer.manage_identities_permission(),
                      Authorizer.manage_own_identities_permission()
                    ]}
                 ]}}
    end
  end

  describe "delete_identities_for/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          account: account,
          provider: provider,
          type: :account_admin_user
        )

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        provider: provider,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "removes all identities and flows that belong to an actor", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      all_identities_query = Auth.Identity.Query.all()
      assert Repo.aggregate(all_identities_query, :count) == 4
      assert delete_identities_for(actor, subject) == :ok

      assert Repo.aggregate(all_identities_query, :count) == 4

      by_actor_id_query =
        Auth.Identity.Query.not_deleted()
        |> Auth.Identity.Query.by_actor_id(actor.id)

      assert Repo.aggregate(by_actor_id_query, :count) == 0
    end

    test "removes all identities and flows that belong to a provider", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      all_identities_query = Auth.Identity.Query.all()
      assert Repo.aggregate(all_identities_query, :count) == 4
      assert delete_identities_for(provider, subject) == :ok

      assert Repo.aggregate(all_identities_query, :count) == 4

      by_provider_id_query =
        Auth.Identity.Query.not_deleted()
        |> Auth.Identity.Query.by_provider_id(provider.id)

      assert Repo.aggregate(by_provider_id_query, :count) == 0
    end

    test "deletes tokens and broadcasts message to disconnect the actor sessions", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      token = Fixtures.Tokens.create_token(account: account, identity: identity)

      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert delete_identities_for(actor, subject) == :ok

      assert token = Repo.get(Domain.Tokens.Token, token.id)
      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "expires all flows created using deleted tokens", %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    } do
      client = Fixtures.Clients.create_client(account: account, identity: identity)

      Fixtures.Flows.create_flow(
        account: account,
        identity: identity,
        actor: actor,
        subject: subject,
        client: client
      )

      assert delete_identities_for(actor, subject) == :ok

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
    end

    test "updates dynamic group memberships", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      group = Fixtures.Actors.create_managed_group(account: account)

      assert delete_identities_for(actor, subject) == :ok

      group = Repo.preload(group, :memberships, force: true)
      assert length(group.memberships) == 1
      refute Enum.any?(group.memberships, &(&1.actor_id == actor.id))
    end

    test "does not remove identities that belong to another actor", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider)
      assert delete_identities_for(actor, subject) == :ok
      assert Repo.aggregate(Auth.Identity.Query.all(), :count) == 2
    end

    test "doesn't allow regular users to delete other users identities", %{
      account: account,
      provider: provider
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      subject = Fixtures.Auth.create_subject(identity: identity)

      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider)

      assert delete_identities_for(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   Authorizer.manage_identities_permission()
                 ]}}

      assert Repo.aggregate(Auth.Identity.Query.all(), :count) == 3
    end
  end

  describe "identity_deleted?/1" do
    test "returns true when identity is deleted" do
      identity =
        Fixtures.Auth.create_identity()
        |> Fixtures.Auth.delete_identity()

      assert identity_deleted?(identity) == true
    end

    test "returns false when identity is not deleted" do
      identity = Fixtures.Auth.create_identity()
      assert identity_deleted?(identity) == false
    end
  end

  # Authentication

  describe "sign_in/4" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        account: account,
        provider: provider,
        user_agent: user_agent,
        remote_ip: remote_ip
      }
    end

    test "returns error when provider_identifier does not exist", %{
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      secret = "foo"
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, Ecto.UUID.generate(), nonce, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when secret is invalid", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)

      assert sign_in(provider, identity.provider_identifier, nonce, "foo", context) ==
               {:error, :unauthorized}
    end

    test "returns error when secret belongs to a different identity invalid", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)

      identity2 = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity2} = Domain.Auth.Adapters.Email.request_sign_in_token(identity2, context)
      secret = identity2.provider_virtual_state.nonce <> identity2.provider_virtual_state.fragment

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when nonce is invalid", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)

      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment
      nonce = "!.="

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :malformed_request}
    end

    test "returns encoded token on success using provider identifier", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, token_identity, fragment} =
               sign_in(provider, identity.provider_identifier, nonce, secret, context)

      refute fragment =~ nonce

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.account.id == account.id
      assert subject.actor.id == identity.actor_id
      assert subject.identity.id == identity.id
      assert subject.identity.id == token_identity.id
      assert subject.expires_at
      assert subject.context.type == context.type

      assert token = Repo.get(Tokens.Token, subject.token_id)
      assert token.type == context.type
      assert token.expires_at
      assert token.account_id == account.id
      assert token.identity_id == identity.id
      assert token.created_by == :system
      assert token.created_by_user_agent == context.user_agent
      assert token.created_by_remote_ip.address == context.remote_ip
    end

    test "provider identifier is not case sensitive", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, _token_identity, _fragment} =
               sign_in(
                 provider,
                 String.upcase(identity.provider_identifier),
                 nonce,
                 secret,
                 context
               )
    end

    test "allows using identity id", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, _token_identity, _fragment} =
               sign_in(provider, identity.id, nonce, secret, context)
    end

    test "allows using client context", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      context = %Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip}

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, token_identity, fragment} =
               sign_in(provider, identity.id, nonce, secret, context)

      {:ok, {_account_id, id, _nonce, _secret}} = Tokens.peek_token(fragment, context)
      assert token = Repo.get(Domain.Tokens.Token, id)
      assert token.type == context.type
      assert token.identity_id == token_identity.id
    end

    test "raises when relay, gateway or api_client context is used", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"

      for type <- [:relay, :gateway, :api_client, :email] do
        context = %Auth.Context{type: type, user_agent: user_agent, remote_ip: remote_ip}

        identity = Fixtures.Auth.create_identity(account: account, provider: provider)
        {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
        secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

        assert_raise FunctionClauseError, fn ->
          sign_in(provider, identity.id, nonce, secret, context)
        end
      end
    end

    test "returned token expiration depends on context type and user role", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"

      # Browser session
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
      ten_hours = 10 * 60 * 60

      ## Admin
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, identity, fragment} =
               sign_in(provider, identity.provider_identifier, nonce, secret, context)

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.identity.id == identity.id

      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), ten_hours)

      ## Regular user
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, identity, fragment} =
               sign_in(provider, identity.provider_identifier, nonce, secret, context)

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.identity.id == identity.id
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), ten_hours)

      # Client session
      context = %Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip}
      one_week = 7 * 24 * 60 * 60

      ## Admin
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, identity, fragment} =
               sign_in(provider, identity.provider_identifier, nonce, secret, context)

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.identity.id == identity.id
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week)

      ## Regular user
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert {:ok, identity, fragment} =
               sign_in(provider, identity.provider_identifier, nonce, secret, context)

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.identity.id == identity.id
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week)
    end

    test "returns error when provider is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _provider} = disable_provider(provider, subject)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)

      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when identity is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _identity} = delete_identity(identity, subject)

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when actor is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"

      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.disable()

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)

      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when actor is deleted", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"

      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.delete()

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)

      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when provider is deleted", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      nonce = "test_nonce_for_firezone"

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _provider} = delete_provider(provider, subject)

      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
      {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
      secret = identity.provider_virtual_state.nonce <> identity.provider_virtual_state.fragment

      assert sign_in(provider, identity.provider_identifier, nonce, secret, context) ==
               {:error, :unauthorized}
    end
  end

  describe "sign_in/3" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        user_agent: user_agent,
        remote_ip: remote_ip
      }
    end

    test "returns error when provider_identifier does not exist", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      {token, _claims} =
        Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity, %{
          "sub" => "foo@bar.com"
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end

    test "returns error when payload is invalid", %{
      bypass: bypass,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => "foo"})

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end

    test "returns encoded token on success", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      expires_at = DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.truncate(:second)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.to_unix(expires_at)
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"

      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, token_identity, fragment} = sign_in(provider, nonce, payload, context)

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.account.id == account.id
      assert subject.actor.id == identity.actor_id
      assert subject.identity.id == identity.id
      assert subject.identity.id == token_identity.id
      assert subject.context.type == context.type

      assert token = Repo.get(Tokens.Token, subject.token_id)
      assert token.type == context.type
      assert token.account_id == account.id
      assert token.identity_id == identity.id
      assert token.created_by == :system
      assert token.created_by_user_agent == context.user_agent
      assert token.created_by_remote_ip.address == context.remote_ip

      assert subject.expires_at == token.expires_at
      assert DateTime.truncate(subject.expires_at, :second) == expires_at
    end

    test "allows using client context", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      expires_at = DateTime.utc_now() |> DateTime.add(10, :second)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.to_unix(expires_at)
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"

      context = %Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, token_identity, fragment} = sign_in(provider, nonce, payload, context)

      {:ok, {_account_id, id, _nonce, _secret}} = Tokens.peek_token(fragment, context)
      assert token = Repo.get(Domain.Tokens.Token, id)
      assert token.type == context.type
      assert token.identity_id == token_identity.id
    end

    test "raises when relay, gateway or api_client context is used", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      expires_at = DateTime.utc_now() |> DateTime.add(10, :second)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.to_unix(expires_at)
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"

      for type <- [:relay, :gateway, :api_client] do
        context = %Auth.Context{type: type, user_agent: user_agent, remote_ip: remote_ip}

        assert_raise FunctionClauseError, fn ->
          sign_in(provider, nonce, payload, context)
        end
      end
    end

    test "returned expiration duration is capped at 2 weeks for admins using clients", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(1_000_000, :second) |> DateTime.to_unix()
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"

      context = %Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, fragment} = sign_in(provider, nonce, payload, context)
      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      one_week = 7 * 24 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week)
    end

    test "returned expiration duration is capped at 10 hours for admins browser session", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(1_000_000, :second) |> DateTime.to_unix()
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"

      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, fragment} = sign_in(provider, nonce, payload, context)
      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      ten_hours = 10 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), ten_hours)
    end

    test "returned expiration duration is capped at 2 weeks for users using clients", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(1_000_000, :second) |> DateTime.to_unix()
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, fragment} = sign_in(provider, nonce, payload, context)
      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      one_week = 7 * 24 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week)
    end

    test "returned expiration duration is capped at 10 hours for users browser session", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(1_000_000, :second) |> DateTime.to_unix()
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"

      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, fragment} = sign_in(provider, nonce, payload, context)
      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      ten_hours = 10 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), ten_hours)
    end

    test "returns error when provider is disabled", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, _fragment} = sign_in(provider, nonce, payload, context)
      {:ok, _provider} = disable_provider(provider, subject)
      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end

    test "returns error when identity is disabled", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, _fragment} = sign_in(provider, nonce, payload, context)
      {:ok, _identity} = delete_identity(identity, subject)
      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end

    test "returns error when actor is disabled", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, _fragment} = sign_in(provider, nonce, payload, context)
      Fixtures.Actors.disable(actor)
      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end

    test "returns error when actor is deleted", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, _fragment} = sign_in(provider, nonce, payload, context)
      Fixtures.Actors.delete(actor)
      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end

    test "returns error when provider is deleted", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      nonce = "nonce"
      context = %Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _token_identity, _fragment} = sign_in(provider, nonce, payload, context)
      {:ok, _provider} = delete_provider(provider, subject)
      assert sign_in(provider, nonce, payload, context) == {:error, :unauthorized}
    end
  end

  describe "sign_out/2" do
    test "redirects to post logout redirect url for OpenID Connect providers" do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      subject = Fixtures.Auth.create_subject(account: account, identity: identity)

      assert {:ok, %Auth.Identity{}, redirect_url} = sign_out(subject, "https://fz.d/sign_out")

      post_redirect_url = URI.encode_www_form("https://fz.d/sign_out")

      assert redirect_url =~ "https://example.com"
      assert redirect_url =~ "id_token_hint="
      assert redirect_url =~ "client_id=#{provider.adapter_config["client_id"]}"
      assert redirect_url =~ "post_logout_redirect_uri=#{post_redirect_url}"

      assert Repo.get(Tokens.Token, subject.token_id).deleted_at
    end

    test "returns identity and url without changes for other providers" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      subject = Fixtures.Auth.create_subject(account: account, identity: identity)

      assert {:ok, %Auth.Identity{}, "https://fz.d/sign_out"} =
               sign_out(subject, "https://fz.d/sign_out")

      assert Repo.get(Tokens.Token, subject.token_id).deleted_at
    end
  end

  describe "create_service_account_token/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        provider: provider,
        identity: identity,
        subject: subject,
        user_agent: user_agent,
        remote_ip: remote_ip,
        context: %Auth.Context{
          type: :client,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns valid client token for a given service account identity", %{
      account: account,
      context: context,
      subject: subject
    } do
      one_day = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)

      assert {:ok, encoded_token} =
               create_service_account_token(
                 actor,
                 %{
                   "name" => "foo",
                   "expires_at" => one_day
                 },
                 subject
               )

      assert {:ok, sa_subject} = authenticate(encoded_token, context)
      assert sa_subject.account.id == account.id
      assert sa_subject.actor.id == actor.id
      refute sa_subject.identity
      assert sa_subject.context.type == context.type
      assert sa_subject.permissions == fetch_type_permissions!(:service_account)

      assert token = Repo.get(Tokens.Token, sa_subject.token_id)
      assert token.name == "foo"
      assert token.type == context.type
      assert token.account_id == account.id
      refute token.identity_id
      assert token.actor_id == actor.id
      assert token.created_by == :identity
      assert token.created_by_identity_id == subject.identity.id
      assert token.created_by_user_agent == context.user_agent
      assert token.created_by_remote_ip.address == context.remote_ip

      assert sa_subject.expires_at == token.expires_at
      assert DateTime.truncate(sa_subject.expires_at, :second) == one_day
    end

    test "raises an error when trying to create a token for a different account", %{
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account)

      assert_raise FunctionClauseError, fn ->
        create_service_account_token(actor, %{}, subject)
      end
    end

    test "raises an error when trying to create a token not for a service account", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

      assert_raise FunctionClauseError, fn ->
        create_service_account_token(actor, %{}, subject)
      end
    end

    test "returns error on missing permissions", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_service_account_token(actor, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_service_accounts_permission()]}}
    end
  end

  describe "create_api_client_token/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: provider,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        provider: provider,
        identity: identity,
        subject: subject,
        user_agent: user_agent,
        remote_ip: remote_ip,
        context: %Auth.Context{
          type: :api_client,
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns valid client token for a given service account identity", %{
      account: account,
      context: context,
      subject: subject
    } do
      one_day = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
      actor = Fixtures.Actors.create_actor(type: :api_client, account: account)

      assert {:ok, encoded_token} =
               create_api_client_token(
                 actor,
                 %{
                   "name" => "foo",
                   "expires_at" => one_day
                 },
                 subject
               )

      assert {:ok, api_subject} = authenticate(encoded_token, context)
      assert api_subject.account.id == account.id
      assert api_subject.actor.id == actor.id
      refute api_subject.identity
      assert api_subject.context.type == context.type
      assert api_subject.permissions == fetch_type_permissions!(:api_client)

      assert token = Repo.get(Tokens.Token, api_subject.token_id)
      assert token.name == "foo"
      assert token.type == context.type
      assert token.account_id == account.id
      refute token.identity_id
      assert token.actor_id == actor.id
      assert token.created_by == :identity
      assert token.created_by_identity_id == subject.identity.id
      assert token.created_by_user_agent == context.user_agent
      assert token.created_by_remote_ip.address == context.remote_ip

      assert api_subject.expires_at == token.expires_at
      assert DateTime.truncate(api_subject.expires_at, :second) == one_day
    end

    test "raises an error when trying to create a token for a different account", %{
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :api_client)

      assert_raise FunctionClauseError, fn ->
        create_api_client_token(actor, %{}, subject)
      end
    end

    test "raises an error when trying to create a token not for a service account", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)

      assert_raise FunctionClauseError, fn ->
        create_api_client_token(actor, %{}, subject)
      end
    end

    test "returns error on missing permissions", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert create_api_client_token(actor, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Authorizer.manage_api_clients_permission()]}}
    end
  end

  describe "authenticate/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      browser_context =
        Fixtures.Auth.build_context(
          type: :browser,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      browser_subject =
        Fixtures.Auth.create_subject(
          account: account,
          identity: identity,
          context: browser_context
        )

      nonce = "nonce"

      {:ok, browser_token} = create_token(identity, browser_context, nonce, nil)

      browser_fragment = Tokens.encode_fragment!(browser_token)

      client_context =
        Fixtures.Auth.build_context(
          type: :client,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      client_subject =
        Fixtures.Auth.create_subject(
          account: account,
          identity: identity,
          context: client_context
        )

      {:ok, client_token} = create_token(identity, client_context, nonce, nil)
      client_fragment = Tokens.encode_fragment!(client_token)

      %{
        account: account,
        provider: provider,
        actor: actor,
        identity: identity,
        user_agent: user_agent,
        remote_ip: remote_ip,
        nonce: nonce,
        browser_context: browser_context,
        browser_subject: browser_subject,
        browser_token: browser_token,
        browser_fragment: browser_fragment,
        client_context: client_context,
        client_subject: client_subject,
        client_token: client_token,
        client_fragment: client_fragment
      }
    end

    test "returns error when token is invalid", %{
      nonce: nonce,
      browser_context: browser_context,
      client_context: client_context
    } do
      assert authenticate(nonce <> ".foo", browser_context) == {:error, :unauthorized}
      assert authenticate("foo", browser_context) == {:error, :unauthorized}
      assert authenticate(nonce <> ".foo", client_context) == {:error, :unauthorized}
      assert authenticate("foo", client_context) == {:error, :unauthorized}
    end

    test "returns error when token is issued for a different context type", %{
      nonce: nonce,
      browser_context: browser_context,
      browser_fragment: browser_fragment,
      client_context: client_context,
      client_fragment: client_fragment
    } do
      assert authenticate(nonce <> client_fragment, browser_context) == {:error, :unauthorized}
      assert authenticate(nonce <> browser_fragment, client_context) == {:error, :unauthorized}
    end

    test "returns error when nonce is invalid", %{
      browser_context: browser_context,
      browser_fragment: browser_fragment,
      client_context: client_context,
      client_fragment: client_fragment
    } do
      assert authenticate("foo" <> client_fragment, browser_context) == {:error, :unauthorized}
      assert authenticate("foo" <> browser_fragment, client_context) == {:error, :unauthorized}
    end

    test "returns subject for browser token", %{
      account: account,
      actor: actor,
      identity: identity,
      nonce: nonce,
      browser_context: context,
      browser_token: token,
      browser_fragment: fragment
    } do
      assert {:ok, reconstructed_subject} = authenticate(nonce <> fragment, context)
      assert reconstructed_subject.identity.id == identity.id
      assert reconstructed_subject.actor.id == actor.id
      assert reconstructed_subject.account.id == account.id
      assert reconstructed_subject.permissions == fetch_type_permissions!(actor.type)
      assert reconstructed_subject.context.remote_ip == context.remote_ip
      assert reconstructed_subject.context.user_agent == context.user_agent

      assert reconstructed_subject.expires_at == token.expires_at
    end

    test "returns an error when browser user agent is changed", %{
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      context = %{context | user_agent: context.user_agent <> "+b1"}
      assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    end

    # test "returns an error when browser ip address is changed", %{
    #   nonce: nonce,
    #   browser_context: context,
    #   browser_fragment: fragment
    # } do
    #   context = %{context | remote_ip: Domain.Fixture.unique_ipv4()}
    #   assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    # end

    test "returns subject for client token", %{
      account: account,
      actor: actor,
      identity: identity,
      nonce: nonce,
      client_context: context,
      client_token: token,
      client_fragment: fragment
    } do
      assert {:ok, reconstructed_subject} = authenticate(nonce <> fragment, context)
      assert reconstructed_subject.identity.id == identity.id
      assert reconstructed_subject.actor.id == actor.id
      assert reconstructed_subject.account.id == account.id
      assert reconstructed_subject.permissions == fetch_type_permissions!(actor.type)
      assert reconstructed_subject.context.remote_ip == context.remote_ip
      assert reconstructed_subject.context.user_agent == context.user_agent
      assert reconstructed_subject.expires_at == token.expires_at
    end

    test "returns subject for client service account token", %{
      account: account,
      client_context: context,
      client_subject: subject
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)

      assert {:ok, encoded_token} = create_service_account_token(actor, %{}, subject)

      assert {:ok, reconstructed_subject} = authenticate(encoded_token, context)
      refute reconstructed_subject.identity
      assert reconstructed_subject.actor.id == actor.id
      assert reconstructed_subject.account.id == account.id
      assert reconstructed_subject.permissions != subject.permissions
      assert reconstructed_subject.permissions == fetch_type_permissions!(:service_account)
      assert reconstructed_subject.context.remote_ip == context.remote_ip
      assert reconstructed_subject.context.user_agent == context.user_agent
      refute reconstructed_subject.expires_at
    end

    test "client token is not bound to remote ip and user agent", %{
      nonce: nonce,
      client_context: context,
      client_fragment: fragment
    } do
      context = %{
        context
        | user_agent: context.user_agent <> "+b1",
          remote_ip: Domain.Fixture.unique_ipv4()
      }

      assert {:ok, subject} = authenticate(nonce <> fragment, context)
      assert subject.context.remote_ip == context.remote_ip
      assert subject.context.user_agent == context.user_agent
    end

    test "updates last signed in fields for identity on success", %{
      identity: identity,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      assert {:ok, subject} = authenticate(nonce <> fragment, context)

      assert subject.identity.last_seen_at != identity.last_seen_at
      assert subject.identity.last_seen_remote_ip != identity.last_seen_remote_ip
      assert subject.identity.last_seen_remote_ip.address == context.remote_ip

      assert subject.identity.last_seen_remote_ip_location_region ==
               context.remote_ip_location_region

      assert subject.identity.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert subject.identity.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert subject.identity.last_seen_remote_ip_location_lon == context.remote_ip_location_lon

      assert subject.identity.last_seen_user_agent != identity.last_seen_user_agent
      assert subject.identity.last_seen_user_agent == context.user_agent

      assert identity = Repo.get(Auth.Identity, subject.identity.id)
      assert identity.last_seen_at == subject.identity.last_seen_at
    end

    test "updates last signed in fields for token on success", %{
      identity: identity,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      assert {:ok, subject} = authenticate(nonce <> fragment, context)

      assert token = Repo.get(Tokens.Token, subject.token_id)
      assert token.last_seen_at != identity.last_seen_at
      assert token.last_seen_remote_ip != identity.last_seen_remote_ip
      assert token.last_seen_remote_ip.address == context.remote_ip
      assert token.last_seen_remote_ip_location_region == context.remote_ip_location_region
      assert token.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert token.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert token.last_seen_remote_ip_location_lon == context.remote_ip_location_lon
      assert token.last_seen_user_agent != identity.last_seen_user_agent
      assert token.last_seen_user_agent == context.user_agent
    end

    test "returns error when token identity is deleted", %{
      identity: identity,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment,
      browser_subject: subject
    } do
      {:ok, _identity} = delete_identity(identity, subject)

      assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    end

    test "returns error when token identity actor is deleted", %{
      actor: actor,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      Fixtures.Actors.delete(actor)

      assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    end

    test "returns error when token identity actor is disabled", %{
      actor: actor,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      Fixtures.Actors.disable(actor)

      assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    end

    test "returns error when token identity provider is deleted", %{
      provider: provider,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      Fixtures.Auth.delete_provider(provider)

      assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    end

    test "returns error when token identity provider is disabled", %{
      provider: provider,
      nonce: nonce,
      browser_context: context,
      browser_fragment: fragment
    } do
      Fixtures.Auth.disable_provider(provider)

      assert authenticate(nonce <> fragment, context) == {:error, :unauthorized}
    end
  end

  describe "has_permission?/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{account: account, actor: actor, subject: subject}
    end

    test "returns true when subject has given permission", %{subject: subject} do
      subject =
        Fixtures.Auth.set_permissions(subject, [
          Authorizer.manage_providers_permission()
        ])

      assert has_permission?(subject, Authorizer.manage_providers_permission())
    end

    test "returns true when subject has one of given permission", %{subject: subject} do
      subject =
        Fixtures.Auth.set_permissions(subject, [
          Authorizer.manage_providers_permission()
        ])

      assert has_permission?(
               subject,
               {:one_of,
                [
                  %Auth.Permission{resource: :boo, action: :bar},
                  Authorizer.manage_providers_permission()
                ]}
             )
    end

    test "returns false when subject has no given permission", %{subject: subject} do
      subject = Fixtures.Auth.set_permissions(subject, [])
      refute has_permission?(subject, Authorizer.manage_providers_permission())
    end
  end

  describe "fetch_type_permissions!/1" do
    test "returns permissions for given type" do
      permissions = fetch_type_permissions!(:account_admin_user)
      assert Enum.count(permissions) > 0
    end
  end

  describe "ensure_type/2" do
    test "returns :ok if subject actor has given type" do
      subject = Fixtures.Auth.create_subject()
      assert ensure_type(subject, subject.actor.type) == :ok
    end

    test "returns error if subject actor has given type" do
      subject = Fixtures.Auth.create_subject()
      assert ensure_type(subject, :foo) == {:error, :unauthorized}
    end
  end

  describe "ensure_has_access_to/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "returns error when subject has no access to given provider", %{
      subject: subject
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider()
      assert ensure_has_access_to(subject, provider) == {:error, :unauthorized}
    end

    test "returns ok when subject has access to given provider", %{
      subject: subject,
      account: account
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      assert ensure_has_access_to(subject, provider) == :ok
    end
  end

  describe "ensure_has_permissions/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "returns error when subject has no given permissions", %{
      subject: subject
    } do
      subject = Fixtures.Auth.set_permissions(subject, [])

      required_permissions = [Authorizer.manage_providers_permission()]

      assert ensure_has_permissions(subject, required_permissions) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions, missing_permissions: required_permissions}}

      required_permissions = [{:one_of, [Authorizer.manage_providers_permission()]}]

      assert ensure_has_permissions(subject, required_permissions) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions, missing_permissions: required_permissions}}
    end

    test "returns error when subject is expired", %{subject: subject} do
      subject = %{subject | expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)}

      assert ensure_has_permissions(subject, []) ==
               {:error, {:unauthorized, reason: :subject_expired}}
    end

    test "returns ok when subject has given permissions", %{
      subject: subject
    } do
      subject =
        Fixtures.Auth.set_permissions(subject, [
          Authorizer.manage_providers_permission()
        ])

      assert ensure_has_permissions(subject, [Authorizer.manage_providers_permission()]) ==
               :ok

      assert ensure_has_permissions(
               subject,
               [{:one_of, [Authorizer.manage_providers_permission()]}]
             ) == :ok
    end
  end

  describe "can_grant_role?/2" do
    test "returns true if granted role requires a subset of permissions of the subject" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      assert can_grant_role?(subject, :account_admin_user)
    end

    test "returns false when granted role requires more permissions than the subject" do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      refute can_grant_role?(subject, :account_admin_user)
    end
  end

  defp allow_child_sandbox_access(parent_pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
    # Allow is async call we need to break current process execution
    # to allow sandbox to be enabled
    :timer.sleep(10)
  end
end
