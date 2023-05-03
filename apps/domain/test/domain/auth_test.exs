defmodule Domain.AuthTest do
  use Domain.DataCase
  import Domain.Auth
  alias Domain.ActorsFixtures
  alias Domain.Auth
  alias Domain.{AccountsFixtures, AuthFixtures, ConfigFixtures}

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
                {:unauthorized,
                 [missing_permissions: [Auth.Authorizer.manage_providers_permission()]]}}
    end

    test "returns error when subject tries to create an account in another account", %{
      account: account
    } do
      subject = AuthFixtures.create_subject()
      assert create_provider(account, %{}, subject) == {:error, :unauthorized}
    end
  end

  describe "disable_provider/2" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)
      subject = AuthFixtures.create_subject(actor)

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
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())

          account = AccountsFixtures.create_account()
          actor = ActorsFixtures.create_actor(account: account)
          subject = AuthFixtures.create_subject(actor)

          provider_one = AuthFixtures.create_email_provider(account: account)
          provider_two = AuthFixtures.create_email_provider(account: account)

          for provider <- [provider_two, provider_one] do
            spawn(fn ->
              Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())

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
                {:unauthorized,
                 [missing_permissions: [Auth.Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "enable_provider/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      subject = AuthFixtures.create_subject(actor)

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
                {:unauthorized,
                 [missing_permissions: [Auth.Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "delete_provider/2" do
    setup do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)
      subject = AuthFixtures.create_subject(actor)

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
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())

          account = AccountsFixtures.create_account()
          actor = ActorsFixtures.create_actor(account: account)
          subject = AuthFixtures.create_subject(actor)

          provider_one = AuthFixtures.create_email_provider(account: account)
          provider_two = AuthFixtures.create_email_provider(account: account)

          for provider <- [provider_two, provider_one] do
            spawn(fn ->
              Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())

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
                {:unauthorized,
                 [missing_permissions: [Auth.Authorizer.manage_providers_permission()]]}}
    end
  end

  describe "link_identity/3" do
    test "creates an identity" do
      account = AccountsFixtures.create_account()
      provider = AuthFixtures.create_email_provider(account: account)
      provider_identifier = AuthFixtures.random_provider_identifier(provider)
      actor = ActorsFixtures.create_actor(role: :admin, account: account, provider: provider)

      assert {:ok, identity} = link_identity(actor, provider, provider_identifier)

      assert identity.provider_id == provider.id
      assert identity.provider_identifier == provider_identifier
      assert identity.actor_id == actor.id
      assert identity.provider_state == %{}
      assert identity.provider_virtual_state == %{}
      assert identity.account_id == provider.account_id
      assert is_nil(identity.deleted_at)
    end
  end

  describe "has_permission?/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      subject = AuthFixtures.build_subject(actor)

      %{account: account, actor: actor, subject: subject}
    end

    test "returns true when subject has given permission", %{subject: subject} do
      subject =
        AuthFixtures.set_permissions(subject, [
          Auth.Authorizer.manage_providers_permission()
        ])

      assert has_permission?(subject, Auth.Authorizer.manage_providers_permission())
    end

    test "returns true when subject has one of given permission", %{subject: subject} do
      subject =
        AuthFixtures.set_permissions(subject, [
          Auth.Authorizer.manage_providers_permission()
        ])

      assert has_permission?(
               subject,
               {:one_of,
                [
                  %Auth.Permission{resource: :boo, action: :bar},
                  Auth.Authorizer.manage_providers_permission()
                ]}
             )
    end

    test "returns false when subject has no given permission", %{subject: subject} do
      subject = AuthFixtures.set_permissions(subject, [])
      refute has_permission?(subject, Auth.Authorizer.manage_providers_permission())
    end
  end

  describe "fetch_role_permissions!/1" do
    test "returns permissions for given role" do
      permissions = fetch_role_permissions!(:admin)
      assert Enum.count(permissions) > 0
    end
  end

  describe "ensure_has_access_to/2" do
    setup do
      account = AccountsFixtures.create_account()
      actor = ActorsFixtures.create_actor(role: :admin, account: account)
      subject = AuthFixtures.create_subject(actor)

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
      subject = AuthFixtures.create_subject(actor)

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

      required_permissions = [Auth.Authorizer.manage_providers_permission()]

      assert ensure_has_permissions(subject, required_permissions) ==
               {:error, {:unauthorized, [missing_permissions: required_permissions]}}

      required_permissions = [{:one_of, [Auth.Authorizer.manage_providers_permission()]}]

      assert ensure_has_permissions(subject, required_permissions) ==
               {:error, {:unauthorized, [missing_permissions: required_permissions]}}
    end

    test "returns ok when subject has given permissions", %{
      subject: subject
    } do
      subject =
        AuthFixtures.set_permissions(subject, [
          Auth.Authorizer.manage_providers_permission()
        ])

      assert ensure_has_permissions(subject, [Auth.Authorizer.manage_providers_permission()]) ==
               :ok

      assert ensure_has_permissions(
               subject,
               [{:one_of, [Auth.Authorizer.manage_providers_permission()]}]
             ) == :ok
    end
  end

  ##############################################

  describe "fetch_oidc_provider_config/1" do
    test "returns error when provider does not exist" do
      assert fetch_oidc_provider_config(Ecto.UUID.generate()) == {:error, :not_found}
      assert fetch_oidc_provider_config("foo") == {:error, :not_found}
    end

    test "returns openid connect provider" do
      {_bypass, [attrs]} = ConfigFixtures.start_openid_providers(["google"])

      assert fetch_oidc_provider_config(attrs["id"]) ==
               {:ok,
                %{
                  client_id: attrs["client_id"],
                  client_secret: attrs["client_secret"],
                  discovery_document_uri: attrs["discovery_document_uri"],
                  redirect_uri: attrs["redirect_uri"],
                  response_type: attrs["response_type"],
                  scope: attrs["scope"]
                }}
    end

    test "puts default redirect_uri" do
      Domain.Config.put_env_override(:web, :external_url, "http://foo.bar.com/")

      {_bypass, [attrs]} =
        ConfigFixtures.start_openid_providers(["google"], %{"redirect_uri" => nil})

      assert fetch_oidc_provider_config(attrs["id"]) ==
               {:ok,
                %{
                  client_id: attrs["client_id"],
                  client_secret: attrs["client_secret"],
                  discovery_document_uri: attrs["discovery_document_uri"],
                  redirect_uri: "http://foo.bar.com/auth/oidc/google/callback/",
                  response_type: attrs["response_type"],
                  scope: attrs["scope"]
                }}
    end
  end

  describe "auto_create_users?/2" do
    test "raises if provider_id not found" do
      assert_raise(RuntimeError, "Unknown provider foobar", fn ->
        auto_create_users?(:openid_connect_providers, "foobar")
      end)
    end

    test "returns true if auto_create_users is true" do
      ConfigFixtures.configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => ConfigFixtures.saml_metadata(),
            "auto_create_users" => true,
            "label" => "SAML"
          }
        ]
      })

      assert auto_create_users?(:saml_identity_providers, "test")
    end

    test "returns false if auto_create_users is false" do
      ConfigFixtures.configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => ConfigFixtures.saml_metadata(),
            "auto_create_users" => false,
            "label" => "SAML"
          }
        ]
      })

      refute auto_create_users?(:saml_identity_providers, "test")
    end
  end
end
