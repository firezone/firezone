defmodule Domain.AuthTest do
  use Domain.DataCase
  import Domain.Auth
  alias Domain.ActorsFixtures
  alias Domain.Auth
  alias Domain.Auth.Authorizer
  alias Domain.{AccountsFixtures, AuthFixtures}

  describe "create_provider/2" do
    setup do
      account = AccountsFixtures.create_account()

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
               name: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs", %{
      account: account
    } do
      attrs =
        AuthFixtures.provider_attrs(
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

    test "creates a provider", %{
      account: account
    } do
      attrs = AuthFixtures.provider_attrs()

      assert {:ok, provider} = create_provider(account, attrs)

      assert provider.name == attrs.name
      assert provider.adapter == attrs.adapter
      assert provider.adapter_config == attrs.adapter_config
      assert provider.account_id == account.id
      assert is_nil(provider.disabled_at)
      assert is_nil(provider.deleted_at)
    end

    # test "returns error when email provider is disabled", %{
    #   account: account
    # } do
    #   Domain.Config.put_system_env_override(:outbound_email_adapter, Domain.Mailer.NoopAdapter)
    #   attrs = AuthFixtures.provider_attrs()

    #   assert {:error, changeset} = create_provider(account, attrs)
    #   assert errors_on(changeset) == %{adapter: ["email adapter is not configured"]}
    # end
  end

  describe "create_provider/3" do
    setup do
      account = AccountsFixtures.create_account()

      %{
        account: account
      }
    end

    test "returns error when subject can not create providers", %{
      account: account
    } do
      subject =
        AuthFixtures.create_subject()
        |> AuthFixtures.remove_permissions()

      assert create_provider(account, %{}, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
    end

    test "returns error when subject tries to create an account in another account", %{
      account: other_account
    } do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(account: account, role: :admin)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      assert create_provider(other_account, %{}, subject) == {:error, :unauthorized}
    end
  end

  describe "disable_provider/2" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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
      other_provider = AuthFixtures.create_email_provider(account: account)

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
      AuthFixtures.create_email_provider()

      assert disable_provider(provider, subject) == {:error, :cant_disable_the_last_provider}
    end

    test "last provider check ignores disabled providers", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      other_provider = AuthFixtures.create_email_provider(account: account)
      {:ok, _other_provider} = disable_provider(other_provider, subject)

      assert disable_provider(provider, subject) == {:error, :cant_disable_the_last_provider}
    end

    test "returns error when trying to disable the last provider using a race condition" do
      for _ <- 0..50 do
        test_pid = self()

        spawn(fn ->
          allow_child_sandbox_access(test_pid)

          account = AccountsFixtures.create_account()
          actor = ActorsFixtures.create_actor(account: account)

          identity = AuthFixtures.create_identity(account: account, actor: actor)
          subject = AuthFixtures.create_subject(identity)

          provider_one = AuthFixtures.create_email_provider(account: account)
          provider_two = AuthFixtures.create_email_provider(account: account)

          for provider <- [provider_two, provider_one] do
            spawn(fn ->
              allow_child_sandbox_access(test_pid)

              assert disable_provider(provider, subject) ==
                       {:error, :cant_disable_the_last_provider}
            end)
          end
        end)
      end
    end

    test "does not do anything when an provider is disabled twice", %{
      subject: subject,
      account: account
    } do
      provider = AuthFixtures.create_email_provider(account: account)
      assert {:ok, _provider} = disable_provider(provider, subject)
      assert {:ok, provider} = disable_provider(provider, subject)
      assert {:ok, _provider} = disable_provider(provider, subject)
    end

    test "does not allow to disable providers in other accounts", %{
      subject: subject
    } do
      provider = AuthFixtures.create_email_provider()
      assert disable_provider(provider, subject) == {:error, :not_found}
    end

    test "returns error when subject can not disable providers", %{
      subject: subject,
      provider: provider
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert disable_provider(provider, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "enable_provider/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      provider = AuthFixtures.create_email_provider(account: account)
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
      assert {:ok, provider} = enable_provider(provider, subject)
      assert provider.disabled_at

      assert provider = Repo.get(Auth.Provider, provider.id)
      assert provider.disabled_at
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
      provider = AuthFixtures.create_email_provider()
      assert enable_provider(provider, subject) == {:error, :not_found}
    end

    test "returns error when subject can not enable providers", %{
      subject: subject,
      provider: provider
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert enable_provider(provider, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "delete_provider/2" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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
      other_provider = AuthFixtures.create_email_provider(account: account)

      assert {:ok, provider} = delete_provider(provider, subject)
      assert provider.deleted_at

      assert provider = Repo.get(Auth.Provider, provider.id)
      assert provider.deleted_at

      assert other_provider = Repo.get(Auth.Provider, other_provider.id)
      assert is_nil(other_provider.deleted_at)
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
      AuthFixtures.create_email_provider()

      assert delete_provider(provider, subject) == {:error, :cant_delete_the_last_provider}
    end

    test "last provider check ignores deleted providers", %{
      account: account,
      subject: subject,
      provider: provider
    } do
      other_provider = AuthFixtures.create_email_provider(account: account)
      {:ok, _other_provider} = delete_provider(other_provider, subject)

      assert delete_provider(provider, subject) == {:error, :cant_delete_the_last_provider}
    end

    test "returns error when trying to delete the last provider using a race condition" do
      for _ <- 0..50 do
        test_pid = self()

        spawn(fn ->
          allow_child_sandbox_access(test_pid)

          account = AccountsFixtures.create_account()
          actor = ActorsFixtures.create_actor(account: account)

          identity = AuthFixtures.create_identity(account: account, actor: actor)
          subject = AuthFixtures.create_subject(identity)

          provider_one = AuthFixtures.create_email_provider(account: account)
          provider_two = AuthFixtures.create_email_provider(account: account)

          for provider <- [provider_two, provider_one] do
            spawn(fn ->
              allow_child_sandbox_access(test_pid)

              assert delete_provider(provider, subject) ==
                       {:error, :cant_delete_the_last_provider}
            end)
          end
        end)
      end
    end

    test "returns error when provider is already deleted", %{
      subject: subject,
      account: account
    } do
      provider = AuthFixtures.create_email_provider(account: account)
      assert {:ok, deleted_provider} = delete_provider(provider, subject)
      assert delete_provider(provider, subject) == {:error, :not_found}
      assert delete_provider(deleted_provider, subject) == {:error, :not_found}
    end

    test "does not allow to delete providers in other accounts", %{
      subject: subject
    } do
      provider = AuthFixtures.create_email_provider()
      assert delete_provider(provider, subject) == {:error, :not_found}
    end

    test "returns error when subject can not delete providers", %{
      subject: subject,
      provider: provider
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert delete_provider(provider, subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "fetch_identity_by_id/1" do
    test "returns error when identity does not exist" do
      assert fetch_identity_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns identity" do
      identity = AuthFixtures.create_identity()
      assert {:ok, fetched_identity} = fetch_identity_by_id(identity.id)
      assert fetched_identity.id == identity.id
    end
  end

  describe "create_identity/3" do
    test "creates an identity" do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      provider_identifier = AuthFixtures.random_provider_identifier(provider)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)

      assert {:ok, identity} = create_identity(actor, provider, provider_identifier)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id
      assert %{sign_in_token_created_at: _, sign_in_token_hash: _} = identity.provider_state
      assert %{sign_in_token: _} = identity.provider_virtual_state
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end

    test "returns error when identifier is invalid" do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)

      provider_identifier = Ecto.UUID.generate()
      assert {:error, changeset} = create_identity(actor, provider, provider_identifier)
      assert errors_on(changeset) == %{provider_identifier: ["is invalid email address"]}

      provider_identifier = nil
      assert {:error, changeset} = create_identity(actor, provider, provider_identifier)
      assert errors_on(changeset) == %{provider_identifier: ["can't be blank"]}
    end
  end

  describe "replace_identity/3" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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

      assert replace_identity(identity, Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "replaces existing identity with a new one", %{
      identity: identity,
      subject: subject
    } do
      provider_identifier = Ecto.UUID.generate()
      assert {:error, changeset} = replace_identity(identity, provider_identifier, subject)
      assert errors_on(changeset) == %{provider_identifier: ["is invalid email address"]}

      provider_identifier = nil
      assert {:error, changeset} = replace_identity(identity, provider_identifier, subject)
      assert errors_on(changeset) == %{provider_identifier: ["can't be blank"]}

      refute Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "returns error when provider_identifier is invalid", %{
      identity: identity,
      provider: provider,
      subject: subject
    } do
      provider_identifier = AuthFixtures.random_provider_identifier(provider)

      assert {:ok, new_identity} = replace_identity(identity, provider_identifier, subject)

      assert new_identity.provider_identifier == provider_identifier
      assert new_identity.provider_id == identity.provider_id
      assert new_identity.actor_id == identity.actor_id
      assert %{sign_in_token_created_at: _, sign_in_token_hash: _} = new_identity.provider_state
      assert %{sign_in_token: _} = new_identity.provider_virtual_state
      assert new_identity.account_id == identity.account_id
      assert is_nil(new_identity.deleted_at)

      assert Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "returns error when subject can not delete identities", %{
      identity: identity,
      subject: subject
    } do
      subject = AuthFixtures.remove_permissions(subject)

      assert replace_identity(identity, Ecto.UUID.generate(), subject) ==
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
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)
      subject = AuthFixtures.create_subject(identity)

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
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)

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
      identity = AuthFixtures.create_identity(account: account, provider: provider)

      subject =
        subject
        |> AuthFixtures.remove_permissions()
        |> AuthFixtures.add_permission(Authorizer.manage_own_identities_permission())
        |> AuthFixtures.add_permission(Authorizer.manage_identities_permission())

      assert {:ok, deleted_identity} = delete_identity(identity, subject)

      assert deleted_identity.id == identity.id
      assert deleted_identity.deleted_at

      assert Repo.get(Auth.Identity, identity.id).deleted_at
    end

    test "does not delete identity that belongs to another actor with manage_own permission", %{
      subject: subject
    } do
      identity = AuthFixtures.create_identity()

      subject =
        subject
        |> AuthFixtures.remove_permissions()
        |> AuthFixtures.add_permission(Authorizer.manage_own_identities_permission())

      assert delete_identity(identity, subject) == {:error, :not_found}
    end

    test "does not delete identity that belongs to another actor with just view permission", %{
      subject: subject
    } do
      identity = AuthFixtures.create_identity()

      subject =
        subject
        |> AuthFixtures.remove_permissions()
        |> AuthFixtures.add_permission(Authorizer.manage_own_identities_permission())

      assert delete_identity(identity, subject) == {:error, :not_found}
    end

    test "returns error when identity does not exist", %{
      account: account,
      provider: provider,
      actor: actor,
      subject: subject
    } do
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)

      assert {:ok, _identity} = delete_identity(identity, subject)
      assert delete_identity(identity, subject) == {:error, :not_found}
    end

    test "returns error when subject can not delete identities", %{subject: subject} do
      identity = AuthFixtures.create_identity()

      subject = AuthFixtures.remove_permissions(subject)

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

  describe "sign_in/5" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      user_agent = AuthFixtures.user_agent()
      remote_ip = AuthFixtures.remote_ip()

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

      assert sign_in(provider, Ecto.UUID.generate(), secret, user_agent, remote_ip) ==
               {:error, :unauthorized}
    end

    test "returns error when secret is invalid", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = AuthFixtures.create_identity(account: account, provider: provider)
      secret = "foo"

      assert sign_in(provider, identity.provider_identifier, secret, user_agent, remote_ip) ==
               {:error, :unauthorized}
    end

    test "returns subject on success", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = AuthFixtures.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      assert {:ok, %Auth.Subject{} = subject} =
               sign_in(provider, identity.provider_identifier, secret, user_agent, remote_ip)

      assert subject.account.id == account.id
      assert subject.actor.id == identity.actor_id
      assert subject.identity.id == identity.id
      assert subject.context.remote_ip == remote_ip
      assert subject.context.user_agent == user_agent
    end

    test "returns error when provider is disabled", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)
      subject = AuthFixtures.create_subject(identity)
      {:ok, _provider} = disable_provider(provider, subject)

      identity = AuthFixtures.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      assert sign_in(provider, identity.provider_identifier, secret, user_agent, remote_ip) ==
               {:error, :unauthorized}
    end

    test "returns error when provider is deleted", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      identity = AuthFixtures.create_identity(account: account, provider: provider, actor: actor)
      subject = AuthFixtures.create_subject(identity)
      {:ok, _provider} = delete_provider(provider, subject)

      identity = AuthFixtures.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      assert sign_in(provider, identity.provider_identifier, secret, user_agent, remote_ip) ==
               {:error, :unauthorized}
    end

    test "updates last signed in fields for identity on success", %{
      account: account,
      provider: provider,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      identity = AuthFixtures.create_identity(account: account, provider: provider)
      secret = identity.provider_virtual_state.sign_in_token

      assert {:ok, _subject} =
               sign_in(provider, identity.provider_identifier, secret, user_agent, remote_ip)

      assert updated_identity = Repo.one(Auth.Identity)
      assert updated_identity.last_seen_at != identity.last_seen_at
      assert updated_identity.last_seen_remote_ip != identity.last_seen_remote_ip
      assert updated_identity.last_seen_user_agent != identity.last_seen_user_agent
    end
  end

  describe "sign_in/3" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      user_agent = AuthFixtures.user_agent()
      remote_ip = AuthFixtures.remote_ip()

      identity =
        AuthFixtures.create_identity(
          account: account,
          provider: provider,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      subject = AuthFixtures.create_subject(identity)

      %{
        account: account,
        provider: provider,
        identity: identity,
        subject: subject,
        user_agent: user_agent,
        remote_ip: remote_ip
      }
    end

    test "returns error when token is invalid", %{user_agent: user_agent, remote_ip: remote_ip} do
      assert sign_in(Ecto.UUID.generate(), user_agent, remote_ip) ==
               {:error, :unauthorized}
    end

    test "returns subject on success", %{
      subject: subject,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      {:ok, token} = create_session_token_from_subject(subject)

      assert {:ok, reconstructed_subject} = sign_in(token, user_agent, remote_ip)
      assert reconstructed_subject.identity.id == subject.identity.id
      assert reconstructed_subject.actor.id == subject.actor.id
      assert reconstructed_subject.account.id == subject.account.id
      assert reconstructed_subject.permissions == subject.permissions
      assert reconstructed_subject.context == subject.context
    end

    test "updates last signed in fields for identity on success", %{
      identity: identity,
      subject: subject,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      {:ok, token} = create_session_token_from_subject(subject)

      assert {:ok, _subject} = sign_in(token, user_agent, remote_ip)

      assert updated_identity = Repo.one(Auth.Identity)
      assert updated_identity.last_seen_at != identity.last_seen_at
      assert updated_identity.last_seen_remote_ip != identity.last_seen_remote_ip
      assert updated_identity.last_seen_user_agent != identity.last_seen_user_agent
    end

    test "returns error when token is created with a different remote ip", %{
      subject: subject,
      user_agent: user_agent
    } do
      {:ok, token} = create_session_token_from_subject(subject)
      assert sign_in(token, user_agent, {127, 0, 0, 1}) == {:error, :unauthorized}
    end

    test "returns error when token is created with a different user agent", %{
      subject: subject,
      remote_ip: remote_ip
    } do
      user_agent = "iOS/12.6 (iPhone) connlib/0.7.412"
      {:ok, token} = create_session_token_from_subject(subject)
      assert sign_in(token, user_agent, remote_ip) == {:error, :unauthorized}
    end

    test "returns error when token is created for a deleted identity", %{
      identity: identity,
      subject: subject,
      user_agent: user_agent,
      remote_ip: remote_ip
    } do
      {:ok, _identity} = delete_identity(identity, subject)

      {:ok, token} = create_session_token_from_subject(subject)
      assert sign_in(token, user_agent, remote_ip) == {:error, :unauthorized}
    end
  end

  describe "create_session_token_from_subject/1" do
    test "returns valid session token for a given subject" do
      identity = AuthFixtures.create_identity()
      subject = AuthFixtures.create_subject(identity)
      assert {:ok, _token} = create_session_token_from_subject(subject)
    end
  end

  describe "has_permission?/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      %{account: account, actor: actor, subject: subject}
    end

    test "returns true when subject has given permission", %{subject: subject} do
      subject =
        AuthFixtures.set_permissions(subject, [
          Authorizer.manage_providers_permission()
        ])

      assert has_permission?(subject, Authorizer.manage_providers_permission())
    end

    test "returns true when subject has one of given permission", %{subject: subject} do
      subject =
        AuthFixtures.set_permissions(subject, [
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
      subject = AuthFixtures.set_permissions(subject, [])
      refute has_permission?(subject, Authorizer.manage_providers_permission())
    end
  end

  describe "fetch_role_permissions!/1" do
    test "returns permissions for given role" do
      permissions = fetch_role_permissions!(:admin)
      assert Enum.count(permissions) > 0
    end
  end

  describe "ensure_type/2" do
    test "returns :ok if subject actor has given type" do
      subject = AuthFixtures.create_subject()
      assert ensure_type(subject, subject.actor.type) == :ok
    end

    test "returns error if subject actor has given type" do
      subject = AuthFixtures.create_subject()
      assert ensure_type(subject, :foo) == {:error, :unauthorized}
    end
  end

  describe "ensure_has_access_to/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "returns error when subject has no access to given provider", %{
      subject: subject
    } do
      provider = AuthFixtures.create_email_provider()
      assert ensure_has_access_to(subject, provider) == {:error, :unauthorized}
    end

    test "returns ok when subject has access to given provider", %{
      subject: subject,
      account: account
    } do
      provider = AuthFixtures.create_email_provider(account: account)
      assert ensure_has_access_to(subject, provider) == :ok
    end
  end

  describe "ensure_has_permissions/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      identity = AuthFixtures.create_identity(account: account, actor: actor)
      subject = AuthFixtures.create_subject(identity)

      %{
        account: account,
        actor: actor,
        subject: subject
      }
    end

    test "returns error when subject has no given permissions", %{
      subject: subject
    } do
      subject = AuthFixtures.set_permissions(subject, [])

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
        AuthFixtures.set_permissions(subject, [
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
