defmodule Domain.DirectoriesTest do
  use Domain.DataCase, async: true
  import Domain.Directories

  setup do
    %{account: Fixtures.Accounts.create_account()}
  end

  describe "fetch_provider_by_id/1" do
    test "returns the provider with the given id", %{account: account} do
      account_id = account.id

      provider_id = Fixtures.Directories.create_okta_provider(account: account).id

      assert {:ok, provider} = fetch_provider_by_id(provider_id)

      assert %{
               id: ^provider_id,
               sync_state: %{
                 "full_user_sync_started_at" => nil,
                 "full_user_sync_finished_at" => nil,
                 "full_group_sync_started_at" => nil,
                 "full_group_sync_finished_at" => nil,
                 "full_member_sync_started_at" => nil,
                 "full_member_sync_finished_at" => nil,
                 "delta_user_sync_started_at" => nil,
                 "delta_user_sync_finished_at" => nil,
                 "delta_group_sync_started_at" => nil,
                 "delta_group_sync_finished_at" => nil,
                 "delta_member_sync_started_at" => nil,
                 "delta_member_sync_finished_at" => nil
               },
               config: %{
                 "client_id" => "test_client_id",
                 "private_key" => "test_private_key",
                 "okta_domain" => "test"
               },
               type: :okta,
               account_id: ^account_id,
               disabled_at: nil
             } = provider
    end

    test "returns {:error, :not_found} if the provider does not exist" do
      assert {:error, :not_found} = fetch_provider_by_id(Ecto.UUID.generate())
    end
  end

  describe "list_providers_for_account/1" do
    test "returns the providers for the given account", %{account: account} do
      provider = Fixtures.Directories.create_okta_provider(account: account)

      assert {:ok, providers, _paginator} = list_providers_for_account(account)

      assert Enum.count(providers) == 1

      assert Enum.any?(providers, &(&1.id == provider.id))
    end

    test "returns an empty list if the account has no providers", %{account: account} do
      assert {:ok, [], _paginator} = list_providers_for_account(account)
    end
  end

  describe "create_provider/2" do
    test "creates a provider with valid attributes", %{account: account} do
      attrs = %{
        type: :okta,
        config: %{
          client_id: "test_client_id",
          private_key: "test_private_key",
          okta_domain: "test"
        }
      }

      assert {:ok, _provider} = create_provider(account, attrs)
    end

    test "returns {:error, changeset} with error when type is missing", %{account: account} do
      attrs = %{
        config: %{
          client_id: "test_client_id",
          private_key: "test_private_key",
          okta_domain: "test"
        }
      }

      assert {:error, changeset} = create_provider(account, attrs)
      assert changeset.valid? == false
      assert changeset.errors[:type] == {"can't be blank", [validation: :required]}
    end

    test "returns {:error, changeset} with error when config are missing", %{
      account: account
    } do
      attrs = %{
        type: :okta
      }

      assert {:error, changeset} = create_provider(account, attrs)
      assert changeset.valid? == false
      assert changeset.errors == [config: {"can't be blank", [validation: :required]}]
    end

    test "returns {:error, changeset} with error when config are provided but nil", %{
      account: account
    } do
      attrs = %{
        type: :okta,
        config: %{
          client_id: nil,
          private_key: nil,
          okta_domain: nil
        }
      }

      assert {:error, changeset} = create_provider(account, attrs)
      assert changeset.valid? == false

      assert changeset.changes.config.errors == [
               client_id: {"can't be blank", [validation: :required]},
               private_key: {"can't be blank", [validation: :required]},
               okta_domain: {"can't be blank", [validation: :required]}
             ]
    end

    test "returns {:error, changeset} with error when config are provided but empty", %{
      account: account
    } do
      attrs = %{
        type: :okta,
        config: %{
          client_id: "",
          private_key: "",
          okta_domain: ""
        }
      }

      assert {:error, changeset} = create_provider(account, attrs)
      assert changeset.valid? == false

      assert changeset.changes.config.errors == [
               client_id: {"can't be blank", [validation: :required]},
               private_key: {"can't be blank", [validation: :required]},
               okta_domain: {"can't be blank", [validation: :required]}
             ]
    end

    test "returns {:error, changeset} with error when account doesn't exist", %{
      account: account
    } do
      attrs = %{
        type: :okta,
        config: %{
          client_id: "test_client_id",
          private_key: "test_private_key",
          okta_domain: "test"
        }
      }

      assert {:error, changeset} = create_provider(%{account | id: Ecto.UUID.generate()}, attrs)
      assert changeset.valid? == false

      assert changeset.errors[:account] ==
               {"does not exist",
                [
                  {:constraint, :foreign},
                  {:constraint_name, "directory_providers_account_id_fkey"}
                ]}
    end
  end

  describe "disable_provider/1" do
    test "disables the provider", %{account: account} do
      provider = Fixtures.Directories.create_okta_provider(account: account)

      assert provider.disabled_at == nil

      assert {:ok, provider} = disable_provider(provider)

      provider_id = provider.id

      assert %{
               id: ^provider_id,
               disabled_at: disabled_at
             } = provider

      assert %DateTime{} = disabled_at
    end
  end

  describe "enable_provider/1" do
    test "enables the provider", %{account: account} do
      provider =
        Fixtures.Directories.create_okta_provider(
          account: account,
          disabled_at: DateTime.utc_now()
        )

      assert %DateTime{} = provider.disabled_at

      assert {:ok, provider} = enable_provider(provider)

      provider_id = provider.id

      assert %{
               id: ^provider_id,
               disabled_at: nil
             } = provider
    end
  end

  describe "update_provider_config/2" do
    test "update the provider config", %{account: account} do
      provider = Fixtures.Directories.create_okta_provider(account: account)

      assert {:ok, provider} =
               update_provider_config(provider, %{
                 config: %{
                   client_id: "new_client_id",
                   private_key: "new_private_key",
                   okta_domain: "new_okta_domain"
                 }
               })

      provider_id = provider.id

      assert %{
               id: ^provider_id,
               config: %{
                 "client_id" => "new_client_id",
                 "private_key" => "new_private_key",
                 "okta_domain" => "new_okta_domain"
               }
             } = provider
    end

    test "doesn't update config if they're blank", %{account: account} do
      provider = Fixtures.Directories.create_okta_provider(account: account)

      assert {:error, changeset} =
               update_provider_config(provider, %{
                 config: %{
                   client_id: "",
                   private_key: "",
                   okta_domain: ""
                 }
               })

      assert changeset.valid? == false

      assert changeset.changes.config.errors == [
               client_id: {"can't be blank", [validation: :required]},
               private_key: {"can't be blank", [validation: :required]},
               okta_domain: {"can't be blank", [validation: :required]}
             ]
    end
  end

  describe "update_provider_sync_state/2" do
    test "updates provider sync state fields individually", %{account: account} do
      provider = Fixtures.Directories.create_okta_provider(account: account)

      assert %{
               "full_user_sync_started_at" => nil,
               "full_user_sync_finished_at" => nil
             } = provider.sync_state

      assert {:ok, provider} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_started_at: DateTime.utc_now()
                 }
               })

      assert %{
               "full_user_sync_started_at" => %DateTime{},
               "full_user_sync_finished_at" => nil
             } = provider.sync_state

      assert {:ok, provider} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_finished_at: DateTime.utc_now()
                 }
               })

      assert %{
               "full_user_sync_started_at" => %DateTime{},
               "full_user_sync_finished_at" => %DateTime{}
             } = provider.sync_state

      assert {:ok, provider} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_started_at: nil,
                   full_user_sync_finished_at: nil
                 }
               })

      assert %{
               "full_user_sync_started_at" => nil,
               "full_user_sync_finished_at" => nil
             } = provider.sync_state
    end

    test "setting the started_at clears the associated finished_at", %{account: account} do
      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)

      provider =
        Fixtures.Directories.create_okta_provider(
          account: account,
          sync_state: %{
            full_user_sync_started_at: one_minute_ago
          }
        )

      assert %{
               "full_user_sync_started_at" => %DateTime{},
               "full_user_sync_finished_at" => nil
             } = provider.sync_state

      assert {:ok, provider} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_finished_at: now
                 }
               })

      assert %{
               "full_user_sync_started_at" => %DateTime{},
               "full_user_sync_finished_at" => %DateTime{}
             } = provider.sync_state

      assert {:ok, provider} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_started_at: now
                 }
               })

      assert %{
               "full_user_sync_started_at" => %DateTime{},
               "full_user_sync_finished_at" => nil
             } = provider.sync_state
    end

    test "prevents setting the finished_at if the started_at is nil", %{account: account} do
      provider =
        Fixtures.Directories.create_okta_provider(
          account: account,
          sync_state: %{
            full_user_sync_started_at: nil
          }
        )

      assert %{
               "full_user_sync_started_at" => nil,
               "full_user_sync_finished_at" => nil
             } = provider.sync_state

      assert {:error, changeset} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_finished_at: DateTime.utc_now()
                 }
               })

      assert changeset.valid? == false

      assert changeset.changes.sync_state.errors ==
               [
                 full_user_sync_finished_at:
                   {"cannot be set when full_user_sync_started_at is nil", []}
               ]
    end

    test "prevents setting the finished_at before the started_at", %{account: account} do
      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -1, :minute)

      provider =
        Fixtures.Directories.create_okta_provider(
          account: account,
          sync_state: %{
            full_user_sync_started_at: one_minute_ago
          }
        )

      assert %{
               "full_user_sync_started_at" => %DateTime{},
               "full_user_sync_finished_at" => nil
             } = provider.sync_state

      assert {:error, changeset} =
               update_provider_sync_state(provider, %{
                 sync_state: %{
                   full_user_sync_finished_at: one_minute_ago
                 }
               })

      assert changeset.valid? == false

      assert changeset.changes.sync_state.errors ==
               [
                 full_user_sync_finished_at: {"must be after full_user_sync_started_at", []}
               ]
    end
  end

  describe "delete_provider/1" do
    test "deletes the provider", %{account: account} do
      provider = Fixtures.Directories.create_okta_provider(account: account)

      assert {:ok, %Domain.Directories.Provider{}} = delete_provider(provider)

      assert {:error, :not_found} = fetch_provider_by_id(provider.id)
    end
  end
end
