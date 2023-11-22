defmodule Domain.AuthTest do
  use Domain.DataCase
  import Domain.Auth
  alias Domain.Auth
  alias Domain.Auth.Authorizer

  describe "list_provider_adapters/0" do
    test "returns list of enabled adapters for an account" do
      assert {:ok, adapters} = list_provider_adapters()

      assert adapters == %{
               openid_connect: Domain.Auth.Adapters.OpenIDConnect,
               google_workspace: Domain.Auth.Adapters.GoogleWorkspace
             }
    end
  end

  describe "fetch_provider_by_id/1" do
    test "returns error when provider does not exist" do
      assert fetch_provider_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when on invalid UUIDv4" do
      assert fetch_provider_by_id("foo") == {:error, :not_found}
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

      assert fetch_provider_by_id(provider.id) == {:error, :not_found}
    end

    test "returns provider" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider()
      assert {:ok, fetched_provider} = fetch_provider_by_id(provider.id)
      assert fetched_provider.id == provider.id
    end
  end

  describe "fetch_provider_by_id/2" do
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

    test "returns provider", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      assert {:ok, fetched_provider} = fetch_provider_by_id(provider.id, subject)
      assert fetched_provider.id == provider.id
    end
  end

  describe "fetch_active_provider_by_id/2" do
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
      assert fetch_active_provider_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when on invalid UUIDv4", %{subject: subject} do
      assert fetch_active_provider_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns error when provider is disabled", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _provider} = disable_provider(provider, subject)
      assert fetch_active_provider_by_id(provider.id, subject) == {:error, :not_found}
    end

    test "returns error when provider is deleted", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      {:ok, _provider} = delete_provider(provider, subject)

      assert fetch_active_provider_by_id(provider.id, subject) == {:error, :not_found}
    end

    test "returns provider", %{account: account, subject: subject} do
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      assert {:ok, fetched_provider} = fetch_active_provider_by_id(provider.id, subject)
      assert fetched_provider.id == provider.id
    end
  end

  describe "fetch_active_provider_by_id/1" do
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

  describe "list_providers_for_account/2" do
    test "returns all not soft-deleted providers for a given account" do
      account = Fixtures.Accounts.create_account()

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      Fixtures.Auth.create_userpass_provider(account: account)
      email_provider = Fixtures.Auth.create_email_provider(account: account)
      token_provider = Fixtures.Auth.create_token_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: email_provider
        )

      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, _provider} = disable_provider(token_provider, subject)
      {:ok, _provider} = delete_provider(email_provider, subject)

      assert {:ok, providers} = list_providers_for_account(account, subject)
      assert length(providers) == 2
    end

    test "returns error when subject can not manage providers" do
      account = Fixtures.Accounts.create_account()

      identity =
        Fixtures.Auth.create_identity(actor: [type: :account_admin_user], account: account)

      subject = Fixtures.Auth.create_subject(identity: identity)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_providers_for_account(account, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "list_active_providers_for_account/1" do
    test "returns active providers for a given account" do
      account = Fixtures.Accounts.create_account()

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      userpass_provider = Fixtures.Auth.create_userpass_provider(account: account)
      email_provider = Fixtures.Auth.create_email_provider(account: account)
      token_provider = Fixtures.Auth.create_token_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account,
          provider: email_provider
        )

      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, _provider} = disable_provider(token_provider, subject)
      {:ok, _provider} = delete_provider(email_provider, subject)

      assert {:ok, [provider]} = list_active_providers_for_account(account)
      assert provider.id == userpass_provider.id
    end
  end

  describe "list_providers_pending_token_refresh_by_adapter/1" do
    test "returns empty list if there are no providers for an adapter" do
      assert list_providers_pending_token_refresh_by_adapter(:google_workspace) == {:ok, []}
    end

    test "returns empty list if there are no providers with token that will expire soon" do
      Fixtures.Auth.start_and_create_google_workspace_provider()
      assert list_providers_pending_token_refresh_by_adapter(:google_workspace) == {:ok, []}
    end

    test "ignores disabled providers" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        disabled_at: DateTime.utc_now(),
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert list_providers_pending_token_refresh_by_adapter(:google_workspace) == {:ok, []}
    end

    test "ignores non-custom provisioners" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        provisioner: :manual,
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert list_providers_pending_token_refresh_by_adapter(:google_workspace) == {:ok, []}
    end

    test "returns providers with tokens that will expire in ~1 hour" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        adapter_state: %{
          "access_token" => "OIDC_ACCESS_TOKEN",
          "refresh_token" => "OIDC_REFRESH_TOKEN",
          "expires_at" => DateTime.utc_now() |> DateTime.add(28, :minute),
          "claims" => "openid email profile offline_access"
        }
      })

      assert {:ok, [fetched_provider]} =
               list_providers_pending_token_refresh_by_adapter(:google_workspace)

      assert fetched_provider.id == provider.id
    end
  end

  describe "list_providers_pending_sync_by_adapter/1" do
    test "returns empty list if there are no providers for an adapter" do
      assert list_providers_pending_sync_by_adapter(:google_workspace) == {:ok, []}
    end

    test "returns empty list if there are no providers that synced more than 10m ago" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      Domain.Fixture.update!(provider, %{last_synced_at: DateTime.utc_now()})
      assert list_providers_pending_sync_by_adapter(:google_workspace) == {:ok, []}
    end

    test "ignores disabled providers" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        disabled_at: DateTime.utc_now(),
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert list_providers_pending_sync_by_adapter(:google_workspace) == {:ok, []}
    end

    test "ignores non-custom provisioners" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      Domain.Fixture.update!(provider, %{
        provisioner: :manual,
        adapter_state: %{
          "expires_at" => DateTime.utc_now()
        }
      })

      assert list_providers_pending_sync_by_adapter(:google_workspace) == {:ok, []}
    end

    test "returns providers with tokens that synced more than 10m ago" do
      {provider1, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      {provider2, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()

      eleven_minutes_ago = DateTime.utc_now() |> DateTime.add(-11, :minute)
      Domain.Fixture.update!(provider2, %{last_synced_at: eleven_minutes_ago})

      assert {:ok, providers} = list_providers_pending_sync_by_adapter(:google_workspace)

      assert Enum.map(providers, & &1.id) |> Enum.sort() ==
               Enum.sort([provider1.id, provider2.id])
    end

    test "uses 1/2 regular timeout backoff for failed attempts" do
      {provider, _bypass} = Fixtures.Auth.start_and_create_google_workspace_provider()
      # backoff: 10 minutes * (1 + 3 ^ 2) = 100 minutes
      provider = Domain.Fixture.update!(provider, %{last_sync_error: "foo", last_syncs_failed: 3})

      ninety_nine_minute_ago = DateTime.utc_now() |> DateTime.add(-99, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: ninety_nine_minute_ago})
      assert list_providers_pending_sync_by_adapter(:google_workspace) == {:ok, []}

      one_hundred_one_minute_ago = DateTime.utc_now() |> DateTime.add(-101, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: one_hundred_one_minute_ago})
      assert {:ok, [_provider]} = list_providers_pending_sync_by_adapter(:google_workspace)

      # max backoff: 4 hours
      provider = Domain.Fixture.update!(provider, %{last_syncs_failed: 300})

      three_hours_fifty_nine_minutes_ago = DateTime.utc_now() |> DateTime.add(-239, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: three_hours_fifty_nine_minutes_ago})
      assert list_providers_pending_sync_by_adapter(:google_workspace) == {:ok, []}

      four_hours_one_minute_ago = DateTime.utc_now() |> DateTime.add(-241, :minute)
      Domain.Fixture.update!(provider, %{last_synced_at: four_hours_one_minute_ago})
      assert {:ok, [_provider]} = list_providers_pending_sync_by_adapter(:google_workspace)
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

    test "returns error if token provider is already enabled", %{
      account: account
    } do
      Fixtures.Auth.create_token_provider(account: account)
      attrs = Fixtures.Auth.provider_attrs(adapter: :token)
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
          provisioner: :just_in_time
        )

      assert {:error, changeset} = create_provider(account, attrs)
      refute changeset.valid?
      assert errors_on(changeset) == %{base: ["this provider is already connected"]}
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

    test "returns error when subject can not create providers", %{
      account: account
    } do
      subject =
        Fixtures.Auth.create_subject()
        |> Fixtures.Auth.remove_permissions()

      assert create_provider(account, %{}, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
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
          provisioner: :just_in_time,
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

    test "returns error when subject can not manage providers", %{
      provider: provider,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_provider(provider, %{}, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
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

    test "returns error when trying to disable the last provider using a race condition" do
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
              disable_provider(provider, subject)
            end)
          end
          |> Task.await_many()

          queryable =
            Auth.Provider.Query.by_account_id(account.id)
            |> Auth.Provider.Query.not_disabled()

          assert Repo.aggregate(queryable, :count) == 1
        end)
      end
      |> Task.await_many()
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

    test "returns error when subject can not disable providers", %{
      subject: subject,
      provider: provider
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert disable_provider(provider, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
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

    test "returns error when subject can not enable providers", %{
      subject: subject,
      provider: provider
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert enable_provider(provider, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
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

    test "returns error when trying to delete the last provider", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      Fixtures.Auth.create_token_provider(account: account)
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

          assert Repo.aggregate(Auth.Provider.Query.by_account_id(account.id), :count) == 1
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

    test "returns error when subject can not delete providers", %{
      subject: subject,
      provider: provider
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_provider(provider, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
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

  describe "fetch_identity_by_id/1" do
    test "returns error when identity does not exist" do
      assert fetch_identity_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns identity" do
      identity = Fixtures.Auth.create_identity()
      assert {:ok, fetched_identity} = fetch_identity_by_id(identity.id)
      assert fetched_identity.id == identity.id
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
  end

  describe "sync_provider_identities_multi/2" do
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

      multi = sync_provider_identities_multi(provider, attrs_list)

      assert {:ok,
              %{
                identities: [],
                plan_identities: {insert, [], []},
                insert_identities: [_actor1, _actor2],
                delete_identities: {0, nil},
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = Repo.transaction(multi)

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

    test "update to existing actors", %{account: account, provider: provider} do
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

      multi = sync_provider_identities_multi(provider, attrs_list)

      assert {:ok,
              %{
                identities: [_identity1, _identity2],
                plan_identities: {[], update, []},
                delete_identities: {0, nil},
                insert_identities: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = Repo.transaction(multi)

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

    test "deletes removed identities", %{account: account, provider: provider} do
      provider_identifiers = ["USER_ID1", "USER_ID2"]

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_identifier: Enum.at(provider_identifiers, 0)
      )

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_identifier: Enum.at(provider_identifiers, 1)
      )

      attrs_list = []

      multi = sync_provider_identities_multi(provider, attrs_list)

      assert {:ok,
              %{
                identities: [_identity1, _identity2],
                plan_identities: {[], [], delete},
                delete_identities: {2, nil},
                insert_identities: [],
                actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
              }} = Repo.transaction(multi)

      assert Enum.all?(provider_identifiers, &(&1 in delete))
      assert Repo.aggregate(Auth.Identity, :count) == 2
      assert Repo.aggregate(Auth.Identity.Query.not_deleted(), :count) == 0

      assert Enum.empty?(actor_ids_by_provider_identifier)
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

      multi = sync_provider_identities_multi(provider, attrs_list)

      assert Repo.transaction(multi) ==
               {:ok,
                %{
                  identities: [],
                  plan_identities: {[], [], []},
                  delete_identities: {0, nil},
                  insert_identities: [],
                  update_identities_and_actors: [],
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

      multi = sync_provider_identities_multi(provider, attrs_list)

      assert {:error, :insert_identities, changeset, _effects_so_far} = Repo.transaction(multi)

      assert errors_on(changeset) == %{
               actor: %{
                 name: ["can't be blank"],
                 type: ["can't be blank"]
               }
             }

      assert Repo.aggregate(Auth.Identity, :count) == 0
      assert Repo.aggregate(Domain.Actors.Actor, :count) == 0
    end
  end

  describe "upsert_identity/3" do
    test "creates an identity" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:ok, identity} = upsert_identity(actor, provider, attrs)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id

      assert %{"sign_in_token_created_at" => _, "sign_in_token_hash" => _} =
               identity.provider_state

      assert %{sign_in_token: _} = identity.provider_virtual_state
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end

    test "updates existing identity" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)

      identity =
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

      assert {:ok, updated_identity} = upsert_identity(actor, provider, attrs)

      assert Repo.aggregate(Auth.Identity, :count) == 1

      assert updated_identity.provider_state != identity.provider_state
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
    test "creates an identity" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      subject = Fixtures.Auth.create_subject(actor: actor)

      attrs = %{
        provider_identifier: provider_identifier,
        provider_identifier_confirmation: provider_identifier
      }

      assert {:ok, _identity} = create_identity(actor, provider, attrs, subject)
    end

    test "returns error on missing permissions" do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      actor =
        Fixtures.Actors.create_actor(
          type: :account_admin_user,
          account: account,
          provider: provider
        )

      subject =
        Fixtures.Auth.create_subject(actor: actor)
        |> Fixtures.Auth.remove_permissions()

      assert create_identity(actor, provider, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Authorizer.manage_identities_permission()]]}}
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

      assert %Ecto.Changeset{} = identity.provider_virtual_state

      assert %{"password_hash" => _} = identity.provider_state
      assert %{password_hash: _} = identity.provider_virtual_state.changes
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
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

    test "updates existing identity" do
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

    test "replaces existing identity with a new one", %{
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

    test "returns error when provider_identifier is invalid", %{
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

      assert %{"sign_in_token_created_at" => _, "sign_in_token_hash" => _} =
               new_identity.provider_state

      assert %{sign_in_token: _} = new_identity.provider_virtual_state
      assert new_identity.account_id == identity.account_id
      assert is_nil(new_identity.deleted_at)

      assert Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "returns error when subject can not delete identities", %{
      identity: identity,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)
      attrs = %{provider_identifier: Ecto.UUID.generate()}

      assert replace_identity(identity, attrs, subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Authorizer.manage_identities_permission(),
                        Authorizer.manage_own_identities_permission()
                      ]}
                   ]
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

      assert {:ok, deleted_identity} = delete_identity(identity, subject)

      assert deleted_identity.id == identity.id
      assert deleted_identity.deleted_at

      assert Repo.get(Auth.Identity, identity.id).deleted_at
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

    test "returns error when subject can not delete identities", %{subject: subject} do
      identity = Fixtures.Auth.create_identity()

      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_identity(identity, subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     {:one_of,
                      [
                        Authorizer.manage_identities_permission(),
                        Authorizer.manage_own_identities_permission()
                      ]}
                   ]
                 ]}}
    end
  end

  describe "delete_actor_identities/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      %{
        account: account,
        provider: provider
      }
    end

    test "removes all identities that belong to an actor", %{account: account, provider: provider} do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      assert Repo.aggregate(Auth.Identity.Query.all(), :count) == 3
      assert delete_actor_identities(actor) == :ok
      assert Repo.aggregate(Auth.Identity.Query.not_deleted(), :count) == 0
    end

    test "does not remove identities that belong to another actor", %{
      account: account,
      provider: provider
    } do
      actor = Fixtures.Actors.create_actor(account: account, provider: provider)
      Fixtures.Auth.create_identity(account: account, provider: provider)
      assert delete_actor_identities(actor) == :ok
      assert Repo.aggregate(Auth.Identity.Query.all(), :count) == 1
    end
  end

  describe "sign_in/5" do
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
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, Ecto.UUID.generate(), secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when secret is invalid", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      secret = "foo"
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, identity.provider_identifier, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns subject on success using provider identifier", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, identity.provider_identifier, secret, context)

      assert subject.account.id == account.id
      assert subject.actor.id == identity.actor_id
      assert subject.identity.id == identity.id
      assert subject.context.remote_ip == remote_ip
      assert subject.context.user_agent == user_agent
    end

    test "returns subject on success using identity id", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, identity.id, secret, context)

      assert subject.account.id == account.id
      assert subject.actor.id == identity.actor_id
      assert subject.identity.id == identity.id
      assert subject.context.remote_ip == remote_ip
      assert subject.context.user_agent == user_agent
    end

    test "returned subject expiration depends on user type", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      secret = identity.provider_virtual_state.sign_in_token

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, identity.provider_identifier, secret, context)

      one_week = 7 * 24 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week - 60 * 60)

      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      secret = identity.provider_virtual_state.sign_in_token

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, identity.provider_identifier, secret, context)

      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week)
    end

    test "returns error when provider is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _provider} = disable_provider(provider, subject)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, identity.provider_identifier, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when identity is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      secret = identity.provider_virtual_state.sign_in_token
      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, identity} = delete_identity(identity, subject)
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, identity.provider_identifier, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when actor is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.disable()

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      secret = identity.provider_virtual_state.sign_in_token
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, identity.provider_identifier, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when actor is deleted", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.delete()

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      secret = identity.provider_virtual_state.sign_in_token
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, identity.provider_identifier, secret, context) ==
               {:error, :unauthorized}
    end

    test "returns error when provider is deleted", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      {:ok, _provider} = delete_provider(provider, subject)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, identity.provider_identifier, secret, context) ==
               {:error, :unauthorized}
    end

    test "updates last signed in fields for identity on success", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _subject} =
               sign_in(provider, identity.provider_identifier, secret, context)

      assert updated_identity = Repo.one(Auth.Identity)
      assert updated_identity.last_seen_at != identity.last_seen_at
      assert updated_identity.last_seen_remote_ip != identity.last_seen_remote_ip
      assert updated_identity.last_seen_user_agent != identity.last_seen_user_agent
    end
  end

  describe "sign_in/4" do
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
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
    end

    test "returns error when token is invalid", %{
      bypass: bypass,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => "foo"})

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
    end

    test "returns subject on success using sub claim", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      token =
        Mocks.OpenIDConnect.sign_openid_connect_token(%{
          "sub" => identity.provider_identifier,
          "aud" => provider.adapter_config["client_id"],
          "exp" => DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.to_unix()
        })

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} = sign_in(provider, payload, context)

      assert subject.account.id == account.id
      assert subject.actor.id == identity.actor_id
      assert subject.identity.id == identity.id
      assert subject.context.remote_ip == remote_ip
      assert subject.context.user_agent == user_agent
    end

    test "returned expiration duration is capped at one week for account users", %{
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

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, payload, context)

      one_week = 7 * 24 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week)
    end

    test "returned expiration duration is capped at 1 week for account admin users", %{
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

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, payload, context)

      one_week = 7 * 24 * 60 * 60
      assert_datetime_diff(subject.expires_at, DateTime.utc_now(), one_week - 60 * 60)
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
      {:ok, _provider} = disable_provider(provider, subject)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
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
      {:ok, identity} = delete_identity(identity, subject)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
    end

    test "returns error when actor is disabled", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.disable()

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
    end

    test "returns error when actor is deleted", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.delete()

      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
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
      {:ok, _provider} = delete_provider(provider, subject)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}
      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert sign_in(provider, payload, context) ==
               {:error, :unauthorized}
    end

    test "updates last signed in fields for identity on success", %{
      bypass: bypass,
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      code_verifier = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_verifier()
      redirect_uri = "https://example.com/"
      payload = {redirect_uri, code_verifier, "MyFakeCode"}

      context = %Auth.Context{user_agent: user_agent, remote_ip: remote_ip}

      assert {:ok, _subject} = sign_in(provider, payload, context)

      assert updated_identity = Repo.one(Auth.Identity)
      assert updated_identity.last_seen_at != identity.last_seen_at
      assert updated_identity.last_seen_remote_ip != identity.last_seen_remote_ip
      assert updated_identity.last_seen_user_agent != identity.last_seen_user_agent
    end
  end

  describe "sign_in/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      user_agent = Fixtures.Auth.user_agent()
      remote_ip = Fixtures.Auth.remote_ip()

      identity =
        Fixtures.Auth.create_identity(
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
          remote_ip: remote_ip,
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.4501,
          remote_ip_location_lon: 30.5234,
          user_agent: user_agent
        }
      }
    end

    test "returns error when token is invalid", %{context: context} do
      assert sign_in(Ecto.UUID.generate(), context) ==
               {:error, :unauthorized}
    end

    test "returns subject on success for session token", %{
      subject: subject,
      context: context
    } do
      {:ok, token} = create_session_token_from_subject(subject)

      assert {:ok, reconstructed_subject} = sign_in(token, context)
      assert reconstructed_subject.identity.id == subject.identity.id
      assert reconstructed_subject.actor.id == subject.actor.id
      assert reconstructed_subject.account.id == subject.account.id
      assert reconstructed_subject.permissions == subject.permissions
      assert reconstructed_subject.context.remote_ip == subject.context.remote_ip
      assert reconstructed_subject.context.user_agent == subject.context.user_agent
      assert DateTime.diff(reconstructed_subject.expires_at, subject.expires_at) <= 1
    end

    test "returns subject on success for client token", %{
      subject: subject,
      context: context
    } do
      {:ok, token} = create_client_token_from_subject(subject)

      # Client sessions are not binded to a specific user agent or remote ip
      remote_ip = Domain.Fixture.unique_ipv4()
      user_agent = context.user_agent <> "+b1"
      context = %{context | remote_ip: remote_ip, user_agent: user_agent}

      assert {:ok, reconstructed_subject} = sign_in(token, context)

      assert reconstructed_subject.identity.id == subject.identity.id
      assert reconstructed_subject.actor.id == subject.actor.id
      assert reconstructed_subject.account.id == subject.account.id
      assert reconstructed_subject.permissions == subject.permissions
      assert reconstructed_subject.context != subject.context
      assert reconstructed_subject.context.user_agent == user_agent
      assert reconstructed_subject.context.remote_ip == remote_ip
      assert DateTime.diff(reconstructed_subject.expires_at, subject.expires_at) <= 1
    end

    test "returns subject on success for service account token", %{
      account: account,
      context: context,
      subject: subject
    } do
      one_day = DateTime.utc_now() |> DateTime.add(1, :day)
      provider = Fixtures.Auth.create_token_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          user_agent: context.user_agent,
          remote_ip: context.remote_ip,
          provider_virtual_state: %{
            "expires_at" => one_day
          }
        )

      {:ok, token} = create_access_token_for_identity(identity)

      assert {:ok, reconstructed_subject} = sign_in(token, context)
      assert reconstructed_subject.identity.id == identity.id
      assert reconstructed_subject.actor.id == identity.actor_id
      assert reconstructed_subject.account.id == identity.account_id
      assert reconstructed_subject.permissions == subject.permissions
      assert reconstructed_subject.context.remote_ip == subject.context.remote_ip
      assert reconstructed_subject.context.user_agent == subject.context.user_agent
      assert DateTime.diff(reconstructed_subject.expires_at, one_day) <= 1
    end

    test "updates last signed in fields for identity on success", %{
      identity: identity,
      subject: subject,
      context: context
    } do
      {:ok, token} = create_session_token_from_subject(subject)

      assert {:ok, _subject} = sign_in(token, context)

      assert updated_identity = Repo.one(Auth.Identity)
      assert updated_identity.last_seen_at != identity.last_seen_at
      assert updated_identity.last_seen_remote_ip != identity.last_seen_remote_ip
      assert updated_identity.last_seen_user_agent != identity.last_seen_user_agent
    end

    # XXX: Use different params to pin the session token on as these are likely to change
    # over the lifetime of the session token.
    # test "returns error when session token is created with a different remote ip", %{
    #   subject: subject,
    #   user_agent: user_agent
    # } do
    #   {:ok, token} = create_session_token_from_subject(subject)
    #   assert sign_in(token, user_agent, {127, 0, 0, 1}) == {:error, :unauthorized}
    # end
    #
    # test "returns error when session token is created with a different user agent", %{
    #   subject: subject,
    #   remote_ip: remote_ip
    # } do
    #   user_agent = "iOS/12.6 (iPhone) connlib/0.7.412"
    #   {:ok, token} = create_session_token_from_subject(subject)
    #   assert sign_in(token, context) == {:error, :unauthorized}
    # end

    test "returns error when token is created for a deleted identity", %{
      identity: identity,
      subject: subject,
      context: context
    } do
      {:ok, _identity} = delete_identity(identity, subject)

      {:ok, token} = create_session_token_from_subject(subject)
      assert sign_in(token, context) == {:error, :unauthorized}
    end
  end

  describe "sign_out/2" do
    test "redirects to post logout redirect url for OpenID Connect providers" do
      account = Fixtures.Accounts.create_account()

      {provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      assert {:ok, %Auth.Identity{}, redirect_url} = sign_out(identity, "https://fz.d/sign_out")

      post_redirect_url = URI.encode_www_form("https://fz.d/sign_out")

      assert redirect_url =~ "https://example.com"
      assert redirect_url =~ "id_token_hint="
      assert redirect_url =~ "client_id=#{provider.adapter_config["client_id"]}"
      assert redirect_url =~ "post_logout_redirect_uri=#{post_redirect_url}"
    end

    test "returns identity and url without changes for other providers" do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      assert {:ok, %Auth.Identity{}, "https://fz.d/sign_out"} =
               sign_out(identity, "https://fz.d/sign_out")
    end
  end

  describe "create_session_token_from_subject/1" do
    test "returns valid session token for a given subject" do
      subject = Fixtures.Auth.create_subject()
      assert {:ok, _token} = create_session_token_from_subject(subject)
    end
  end

  describe "create_client_token_from_subject/1" do
    test "returns valid client token for a given subject" do
      subject = Fixtures.Auth.create_subject()
      assert {:ok, _token} = create_client_token_from_subject(subject)
    end
  end

  describe "fetch_session_token_expires_at/2" do
    test "returns datetime when the token expires" do
      subject = Fixtures.Auth.create_subject()
      {:ok, token} = create_session_token_from_subject(subject)

      assert {:ok, expires_at} = fetch_session_token_expires_at(token)
      assert_datetime_diff(expires_at, DateTime.utc_now(), 60)
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
               {:error, {:unauthorized, [missing_permissions: required_permissions]}}

      required_permissions = [{:one_of, [Authorizer.manage_providers_permission()]}]

      assert ensure_has_permissions(subject, required_permissions) ==
               {:error, {:unauthorized, [missing_permissions: required_permissions]}}
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

  defp allow_child_sandbox_access(parent_pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
    # Allow is async call we need to break current process execution
    # to allow sandbox to be enabled
    :timer.sleep(10)
  end
end
