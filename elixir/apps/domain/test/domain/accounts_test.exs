defmodule Domain.AccountsTest do
  use Domain.DataCase, async: true
  import Domain.Accounts
  alias Domain.Accounts

  describe "all_active_accounts!/0" do
    test "returns all active accounts" do
      Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()
      Fixtures.Accounts.create_account() |> Fixtures.Accounts.delete_account()

      accounts = all_active_accounts!()
      assert length(accounts) == 1
    end
  end

  describe "all_accounts_by_ids!/1" do
    test "returns empty list when ids are empty" do
      accounts = all_accounts_by_ids!([])
      assert length(accounts) == 0
    end

    test "returns empty list when ids are invalid" do
      accounts = all_accounts_by_ids!(["foo", "bar"])
      assert length(accounts) == 0
    end

    test "returns accounts when they exist" do
      account1 = Fixtures.Accounts.create_account()
      account2 = Fixtures.Accounts.create_account()
      account3 = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()

      accounts = all_accounts_by_ids!([account1.id, account2.id, account3.id])
      assert length(accounts) == 3
    end

    test "does not return deleted accounts" do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.delete_account()
      accounts = all_accounts_by_ids!([account.id])
      assert length(accounts) == 0
    end
  end

  describe "all_active_paid_accounts_pending_notification!/0" do
    test "returns paid and active accounts" do
      attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: true,
              last_notified: nil
            }
          }
        }
      }

      Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account(attrs) |> Fixtures.Accounts.change_to_enterprise()
      Fixtures.Accounts.create_account(attrs) |> Fixtures.Accounts.change_to_team()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_team()
      |> Fixtures.Accounts.disable_account()

      accounts = all_active_paid_accounts_pending_notification!()
      assert length(accounts) == 2
    end

    test "returns empty list when no paid accounts exist" do
      Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account() |> Fixtures.Accounts.change_to_starter()

      accounts = all_active_paid_accounts_pending_notification!()
      assert length(accounts) == 0
    end

    test "does not return accounts with notification disabled" do
      enabled_attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: true,
              last_notified: nil
            }
          }
        }
      }

      disabled_attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: false,
              last_notified: nil
            }
          }
        }
      }

      Fixtures.Accounts.create_account(enabled_attrs)
      |> Fixtures.Accounts.change_to_enterprise()

      Fixtures.Accounts.create_account(disabled_attrs)
      |> Fixtures.Accounts.change_to_enterprise()

      Fixtures.Accounts.create_account(enabled_attrs)
      |> Fixtures.Accounts.change_to_team()

      Fixtures.Accounts.create_account(disabled_attrs)
      |> Fixtures.Accounts.change_to_team()

      accounts = all_active_paid_accounts_pending_notification!()
      assert length(accounts) == 2
    end

    test "does not return accounts that have been notified within 24 hours" do
      attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: true,
              last_notified: DateTime.utc_now() |> DateTime.add(-(60 * 60 * 12))
            }
          }
        }
      }

      Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_enterprise()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_team()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_team()
      |> Fixtures.Accounts.disable_account()

      accounts = all_active_paid_accounts_pending_notification!()
      assert length(accounts) == 0
    end

    test "returns accounts that have been notified more than 24 hours ago" do
      attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: true,
              last_notified: DateTime.utc_now() |> DateTime.add(-(60 * 60 * 36))
            }
          }
        }
      }

      Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_enterprise()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_team()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_team()
      |> Fixtures.Accounts.disable_account()

      accounts = all_active_paid_accounts_pending_notification!()
      assert length(accounts) == 2
    end
  end

  describe "all_active_accounts_by_subscription_name_pending_notification!/1" do
    test "returns all active accounts for given subscription name" do
      attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: true,
              last_notified: nil
            }
          }
        }
      }

      Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account(attrs) |> Fixtures.Accounts.change_to_team()

      Fixtures.Accounts.create_account(attrs)
      |> Fixtures.Accounts.change_to_team()
      |> Fixtures.Accounts.disable_account()

      accounts = all_active_accounts_by_subscription_name_pending_notification!("Team")
      assert length(accounts) == 1
    end

    test "returns an empty list when no active accounts with type" do
      Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_account()
      |> Fixtures.Accounts.change_to_team()
      |> Fixtures.Accounts.disable_account()

      accounts = all_active_accounts_by_subscription_name_pending_notification!("Team")
      assert length(accounts) == 0
    end
  end

  describe "fetch_account_by_id/3" do
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

    test "allows to preload assocs", %{account: account, subject: subject} do
      assert {:ok, account} =
               fetch_account_by_id(account.id, subject, preload: [actors: [:identities]])

      assert Ecto.assoc_loaded?(account.actors)
      assert Enum.all?(account.actors, &Ecto.assoc_loaded?(&1.identities))
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
    test "returns error when account does not exist" do
      assert fetch_account_by_id_or_slug(Ecto.UUID.generate()) == {:error, :not_found}
      assert fetch_account_by_id_or_slug("foo") == {:error, :not_found}
    end

    test "returns account when account exists" do
      slug = generate_unique_slug()
      account = Fixtures.Accounts.create_account(slug: slug)

      assert {:ok, fetched_account} = fetch_account_by_id_or_slug(account.id)
      assert fetched_account.id == account.id

      assert {:ok, fetched_account} = fetch_account_by_id_or_slug(slug)
      assert fetched_account.id == account.id
    end
  end

  describe "fetch_account_by_id!/1" do
    test "returns account when account exists" do
      account = Fixtures.Accounts.create_account()
      assert fetch_account_by_id!(account.id) == account
    end

    test "raises error when account does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        fetch_account_by_id!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_account/1" do
    test "creates account given valid attrs" do
      slug = generate_unique_slug()
      assert {:ok, account} = create_account(%{name: "foo", slug: slug})
      assert account.name == "foo"
      assert account.slug == slug
    end

    test "returns error on empty attrs" do
      assert {:error, changeset} = create_account(%{})

      assert errors_on(changeset) == %{
               name: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs" do
      assert {:error, changeset} =
               create_account(%{
                 name: String.duplicate("A", 65),
                 slug: "admin"
               })

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"],
               slug: ["is reserved"]
             }
    end

    test "returns error when account name is too long" do
      assert {:error, changeset} = create_account(%{name: String.duplicate("A", 65)})
      assert errors_on(changeset) == %{name: ["should be at most 64 character(s)"]}
    end

    test "returns error when account name is too short" do
      assert {:error, changeset} = create_account(%{name: "a"})
      assert errors_on(changeset) == %{name: ["should be at least 3 character(s)"]}
    end

    test "returns error when slug contains invalid characters" do
      assert {:error, changeset} = create_account(%{slug: "foo-bar"})
      assert "can only contain letters, numbers, and underscores" in errors_on(changeset).slug
    end

    test "returns error when slug already exists" do
      assert {:ok, _account} = create_account(%{name: "foo", slug: "foo"})
      assert {:error, changeset} = create_account(%{name: "bar", slug: "foo"})
      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "change_account/2" do
    test "returns account changeset" do
      account = Fixtures.Accounts.create_account()
      assert changeset = change_account(account, %{})
      assert changeset.valid?
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
          monthly_active_users_count: -1
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
          monthly_active_users_count: 999
        },
        metadata: %{
          stripe: %{
            customer_id: "cus_1234567890",
            subscription_id: "sub_1234567890",
            billing_email: "foo@example.com"
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

      assert account.limits.monthly_active_users_count !=
               attrs.limits.monthly_active_users_count

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

    test "returns error when subject cannot manage account", %{
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
    test "updates account" do
      account = Fixtures.Accounts.create_account()
      assert {:ok, account} = update_account(account, %{name: "new_name"})
      assert account.name == "new_name"
    end
  end

  describe "update_account_by_id/2.id" do
    setup do
      account =
        Fixtures.Accounts.create_account(
          config: %{},
          metadata: %{stripe: %{customer_id: "cus_1234567890"}}
        )

      %{account: account}
    end

    test "returns error when changeset is invalid", %{account: account} do
      attrs = %{
        name: String.duplicate("a", 65),
        features: %{
          idp_sync: 1
        },
        limits: %{
          monthly_active_users_count: -1
        },
        config: %{
          clients_upstream_dns: [%{protocol: "ip_port", address: "!!!"}]
        }
      }

      assert {:error, changeset} = update_account_by_id(account.id, attrs)

      assert errors_on(changeset) == %{
               name: ["should be at most 64 character(s)"],
               features: %{
                 idp_sync: ["is invalid"]
               },
               limits: %{
                 monthly_active_users_count: ["must be greater than or equal to 0"]
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

      assert {:ok, account} = update_account_by_id(account.id, attrs)

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

      assert {:error, changeset} = update_account_by_id(account.id, attrs)

      assert errors_on(changeset) == %{
               config: %{
                 clients_upstream_dns: ["all addresses must be unique"]
               }
             }
    end

    test "returns error on dns config address in IPv4 sentinel range", %{account: account} do
      attrs = %{
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "100.64.10.1"}
          ]
        }
      }

      assert {:error, changeset} = update_account_by_id(account.id, attrs)

      assert errors_on(changeset) == %{
               config: %{
                 clients_upstream_dns: [
                   %{address: ["cannot be in the CIDR 100.64.0.0/10"]}
                 ]
               }
             }
    end

    test "returns error on dns config address in IPv6 sentinel range", %{account: account} do
      attrs = %{
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "fd00:2021:1111:10::"}
          ]
        }
      }

      assert {:error, changeset} = update_account_by_id(account.id, attrs)

      assert errors_on(changeset) == %{
               config: %{
                 clients_upstream_dns: [
                   %{address: ["cannot be in the CIDR fd00:2021:1111::/48"]}
                 ]
               }
             }
    end

    test "updates account and broadcasts a message", %{account: account} do
      Bypass.open()
      |> Domain.Mocks.Stripe.mock_update_customer_endpoint(account)

      attrs = %{
        name: Ecto.UUID.generate(),
        features: %{
          idp_sync: true,
          self_hosted_relays: false
        },
        limits: %{
          monthly_active_users_count: 999
        },
        metadata: %{
          stripe: %{
            customer_id: "cus_1234567890",
            subscription_id: "sub_1234567890",
            billing_email: Fixtures.Auth.email()
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

      assert {:ok, account} = update_account_by_id(account.id, attrs)

      assert account.name == attrs.name

      assert account.features.idp_sync == attrs.features.idp_sync
      assert account.features.self_hosted_relays == attrs.features.self_hosted_relays

      assert account.limits.monthly_active_users_count ==
               attrs.limits.monthly_active_users_count

      assert account.metadata.stripe.customer_id ==
               attrs.metadata.stripe.customer_id

      assert account.metadata.stripe.subscription_id ==
               attrs.metadata.stripe.subscription_id

      assert account.metadata.stripe.billing_email ==
               attrs.metadata.stripe.billing_email

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

    test "broadcasts disconnect message for the clients when account is disabled", %{
      account: account
    } do
      attrs = %{
        disabled_at: DateTime.utc_now()
      }

      :ok = Domain.PubSub.subscribe("account_clients:#{account.id}")

      assert {:ok, _account} = update_account_by_id(account.id, attrs)

      assert_receive "disconnect"
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

  describe "account_active?/1" do
    test "returns true when account is active" do
      account = Fixtures.Accounts.create_account()
      assert account_active?(account) == true
    end

    test "returns false when account is deleted" do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.delete_account()
      assert account_active?(account) == false
    end

    test "returns false when account is disabled" do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()
      assert account_active?(account) == false
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

  describe "generate_unique_slug/0" do
    test "returns unique slug" do
      assert slug = generate_unique_slug()
      assert is_binary(slug)
    end
  end
end
