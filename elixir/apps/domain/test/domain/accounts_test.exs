defmodule Domain.AccountsTest do
  use Domain.DataCase, async: true
  import Domain.Accounts
  alias Domain.Accounts

  describe "fetch_account_by_id/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error when account does not exist", %{subject: subject} do
      assert fetch_account_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_account_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns account when account exists", %{account: account, subject: subject} do
      assert {:ok, fetched_account} = fetch_account_by_id(account.id, subject)
      assert fetched_account.id == account.id
    end

    test "returns error when subject has no permission to view accounts", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_account_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Accounts.Authorizer.manage_own_account_permission()]}}
    end
  end

  describe "fetch_account_by_id_or_slug/2" do
    setup do
      account =
        Fixtures.Accounts.create_account(slug: "follow_the_#{System.unique_integer([:positive])}")

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns error when account does not exist", %{subject: subject} do
      assert fetch_account_by_id_or_slug(Ecto.UUID.generate(), subject) == {:error, :not_found}
      assert fetch_account_by_id_or_slug("foo", subject) == {:error, :not_found}
    end

    test "returns account when account exists", %{account: account, subject: subject} do
      assert {:ok, fetched_account} = fetch_account_by_id_or_slug(account.id, subject)
      assert fetched_account.id == account.id
    end

    test "returns error when subject has no permission to view accounts", %{subject: subject} do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_account_by_id_or_slug(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Accounts.Authorizer.manage_own_account_permission()]}}
    end
  end

  describe "fetch_account_by_id_or_slug/1" do
    test "returns error when account does not exist" do
      assert fetch_account_by_id_or_slug(Ecto.UUID.generate()) == {:error, :not_found}
      assert fetch_account_by_id_or_slug("foo") == {:error, :not_found}
    end

    test "returns account when account exists" do
      account =
        Fixtures.Accounts.create_account(slug: "follow_the_#{System.unique_integer([:positive])}")

      assert {:ok, fetched_account} = fetch_account_by_id_or_slug(account.id)
      assert fetched_account.id == account.id

      assert {:ok, fetched_account} = fetch_account_by_id_or_slug(account.slug)
      assert fetched_account.id == account.id
    end
  end

  describe "fetch_account_by_id/1" do
    test "returns error when account is not found" do
      assert fetch_account_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert fetch_account_by_id("foo") == {:error, :not_found}
    end

    test "returns account" do
      account = Fixtures.Accounts.create_account()
      assert {:ok, returned_account} = fetch_account_by_id(account.id)
      assert returned_account.id == account.id
    end
  end

  describe "update_account/3" do
    setup do
      account = Fixtures.Accounts.create_account(config: %{})
      subject = Fixtures.Auth.create_subject(account: account)
      %{account: account, subject: subject}
    end

    test "returns error when changeset is invalid", %{account: account, subject: subject} do
      attrs = %{
        name: String.duplicate("a", 65),
        features: %{
          idp_sync: 1
        },
        limits: %{
          monthly_active_actors_count: -1
        },
        config: %{
          clients_upstream_dns: [%{protocol: "ip_port", address: "!!!"}]
        }
      }

      assert {:error, changeset} = update_account(account, attrs, subject)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"],
               config: %{
                 clients_upstream_dns: [
                   %{address: ["must be a valid IP address"]}
                 ]
               }
             }
    end

    test "updates account and broadcasts a message", %{account: account, subject: subject} do
      attrs = %{
        name: Ecto.UUID.generate(),
        features: %{
          idp_sync: false
        },
        limits: %{
          monthly_active_actors_count: 999
        },
        metadata: %{
          stripe: %{
            customer_id: "cus_1234567890",
            subscription_id: "sub_1234567890"
          }
        },
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.1.1.1"},
            %{protocol: "ip_port", address: "8.8.8.8"}
          ]
        }
      }

      :ok = subscribe_to_events_in_account(account)

      assert {:ok, account} = update_account(account, attrs, subject)

      assert account.name == attrs.name

      # doesn't update features, filters, metadata or settings
      assert account.features.idp_sync

      assert account.limits.monthly_active_actors_count !=
               attrs.limits.monthly_active_actors_count

      assert is_nil(account.metadata.stripe.customer_id)

      assert account.config.clients_upstream_dns == [
               %Domain.Accounts.Config.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "1.1.1.1"
               },
               %Domain.Accounts.Config.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.8.8"
               }
             ]

      assert_receive :config_changed
    end

    test "returns an error when trying to update other account", %{
      subject: subject
    } do
      other_account = Fixtures.Accounts.create_account()
      assert update_account(other_account, %{}, subject) == {:error, :not_found}
    end

    test "returns error when subject can not manage account", %{
      account: account,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert update_account(account, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Accounts.Authorizer.manage_own_account_permission()]}}
    end
  end

  describe "update_account/2" do
    setup do
      account = Fixtures.Accounts.create_account(config: %{})
      %{account: account}
    end

    test "returns error when changeset is invalid", %{account: account} do
      attrs = %{
        name: String.duplicate("a", 65),
        features: %{
          idp_sync: 1
        },
        limits: %{
          monthly_active_actors_count: -1
        },
        config: %{
          clients_upstream_dns: [%{protocol: "ip_port", address: "!!!"}]
        }
      }

      assert {:error, changeset} = update_account(account, attrs)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"],
               features: %{
                 idp_sync: ["is invalid"]
               },
               limits: %{
                 monthly_active_actors_count: ["must be greater than or equal to 0"]
               },
               config: %{
                 clients_upstream_dns: [
                   %{address: ["must be a valid IP address"]}
                 ]
               }
             }
    end

    test "trims client upstream dns config address fields", %{account: account} do
      attrs = %{
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "   1.1.1.1"},
            %{protocol: "ip_port", address: "8.8.8.8   "}
          ]
        }
      }

      assert {:ok, account} = update_account(account, attrs)

      assert account.config.clients_upstream_dns == [
               %Domain.Accounts.Config.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "1.1.1.1"
               },
               %Domain.Accounts.Config.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.8.8"
               }
             ]
    end

    test "returns error on duplicate upstream dns config addresses", %{account: account} do
      attrs = %{
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.1.1.1:53"},
            %{protocol: "ip_port", address: "1.1.1.1   "}
          ]
        }
      }

      assert {:error, changeset} = update_account(account, attrs)

      assert errors_on(changeset) == %{
               config: %{
                 clients_upstream_dns: ["all addresses must be unique"]
               }
             }
    end

    test "updates account and broadcasts a message", %{account: account} do
      attrs = %{
        name: Ecto.UUID.generate(),
        features: %{
          idp_sync: true,
          self_hosted_relays: false
        },
        limits: %{
          monthly_active_actors_count: 999
        },
        metadata: %{
          stripe: %{
            customer_id: "cus_1234567890",
            subscription_id: "sub_1234567890"
          }
        },
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.1.1.1"},
            %{protocol: "ip_port", address: "8.8.8.8"}
          ]
        }
      }

      :ok = subscribe_to_events_in_account(account)

      assert {:ok, account} = update_account(account, attrs)

      assert account.name == attrs.name

      assert account.features.idp_sync == attrs.features.idp_sync
      assert account.features.self_hosted_relays == attrs.features.self_hosted_relays

      assert account.limits.monthly_active_actors_count ==
               attrs.limits.monthly_active_actors_count

      assert account.metadata.stripe.customer_id ==
               attrs.metadata.stripe.customer_id

      assert account.metadata.stripe.subscription_id ==
               attrs.metadata.stripe.subscription_id

      assert account.config.clients_upstream_dns == [
               %Domain.Accounts.Config.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "1.1.1.1"
               },
               %Domain.Accounts.Config.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.8.8"
               }
             ]

      assert_receive :config_changed
    end
  end

  for feature <- Accounts.Features.__schema__(:fields) do
    describe "#{:"#{feature}_enabled?"}/1" do
      test "returns true when feature is enabled for account" do
        account = Fixtures.Accounts.create_account(features: %{unquote(feature) => true})
        assert unquote(:"#{feature}_enabled?")(account) == true
      end

      test "returns false when feature is disabled for account" do
        account = Fixtures.Accounts.create_account(features: %{unquote(feature) => false})
        assert unquote(:"#{feature}_enabled?")(account) == false
      end

      test "returns false when feature is disabled globally" do
        Domain.Config.feature_flag_override(unquote(feature), false)
        account = Fixtures.Accounts.create_account(features: %{unquote(feature) => true})
        assert unquote(:"#{feature}_enabled?")(account) == false
      end
    end
  end

  describe "ensure_has_access_to/2" do
    test "returns :ok if subject has access to the account" do
      subject = Fixtures.Auth.create_subject()

      assert ensure_has_access_to(subject, subject.account) == :ok
    end

    test "returns :error if subject has no access to the account" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Auth.create_subject()

      assert ensure_has_access_to(subject, account) == {:error, :unauthorized}
    end
  end

  describe "create_account/1" do
    test "creates account given a valid name" do
      assert {:ok, account} = create_account(%{name: "foo"})
      assert account.name == "foo"
    end

    test "creates account given a valid name and valid slug" do
      assert {:ok, account1} = create_account(%{name: "foobar", slug: "foobar"})
      assert account1.slug == "foobar"

      assert {:ok, account2} = create_account(%{name: "foo1", slug: "foo1"})
      assert account2.slug == "foo1"

      assert {:ok, account3} = create_account(%{name: "foo_bar", slug: "foo_bar"})
      assert account3.slug == "foo_bar"
    end

    test "returns error when account name is blank" do
      assert {:error, changeset} = create_account(%{name: ""})
      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "returns error when account name is too long" do
      max_name_length = 64
      assert {:ok, _account} = create_account(%{name: String.duplicate("a", max_name_length)})

      assert {:error, changeset} =
               create_account(%{name: String.duplicate("b", max_name_length + 1)})

      assert errors_on(changeset) == %{name: ["should be at most 64 character(s)"]}
    end

    test "returns error when account name is too short" do
      assert {:error, changeset} = create_account(%{name: "a"})
      assert errors_on(changeset) == %{name: ["should be at least 3 character(s)"]}
    end

    test "returns error when slug contains invalid characters" do
      assert {:error, changeset} = create_account(%{name: "foo-bar", slug: "foo-bar"})

      assert errors_on(changeset) == %{
               slug: ["can only contain letters, numbers, and underscores"]
             }
    end

    test "returns error when slug already exists" do
      assert {:ok, _account} = create_account(%{name: "foo", slug: "foo"})

      assert {:error, changeset} = create_account(%{name: "bar", slug: "foo"})

      assert errors_on(changeset) == %{slug: ["has already been taken"]}
    end
  end
end
