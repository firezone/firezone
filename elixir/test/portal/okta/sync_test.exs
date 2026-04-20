defmodule Portal.Okta.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.OktaDirectoryFixtures

  alias Portal.Okta.APIClient
  alias Portal.Okta.Sync
  alias Portal.Okta.Sync.Database
  alias Portal.Okta.SyncError
  alias Portal.ExternalIdentity
  alias Portal.Group
  alias Portal.Membership

  @test_jwk JOSE.JWK.generate_key({:rsa, 1024})
  @test_private_key_jwk @test_jwk |> JOSE.JWK.to_map() |> elem(1)

  # Generate a valid test JWT with required scopes for Okta sync
  @test_access_token (
                       payload = %{
                         "scp" => ["okta.apps.read", "okta.users.read", "okta.groups.read"],
                         "iat" => System.system_time(:second),
                         "exp" => System.system_time(:second) + 3600
                       }

                       {_, jwt} =
                         @test_jwk
                         |> JOSE.JWT.sign(%{"alg" => "RS256"}, payload)
                         |> JOSE.JWS.compact()

                       jwt
                     )

  describe "perform/1" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "performs successful sync with users and groups" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock all API calls
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => "alice@example.com",
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [
              %{
                "id" => "appgroup_1",
                "_embedded" => %{
                  "group" => %{
                    "id" => "group_123",
                    "profile" => %{"name" => "Engineering"}
                  }
                }
              }
            ])

          String.contains?(path, "/groups/group_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "user_123",
                "status" => "ACTIVE",
                "profile" => %{
                  "email" => "alice@example.com",
                  "firstName" => "Alice",
                  "lastName" => "Smith"
                }
              }
            ])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify identity was created
      identities = Repo.all(ExternalIdentity)
      assert length(identities) == 1
      assert hd(identities).email == "alice@example.com"

      # Verify group was created
      groups = Repo.all(Group)
      assert length(groups) == 1
      assert hd(groups).name == "Engineering"

      # Verify membership was created
      memberships = Repo.all(Membership)
      assert length(memberships) == 1

      # Verify directory was updated with sync timestamp
      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      refute is_nil(updated_directory.synced_at)
      assert updated_directory.error_message == nil
    end

    test "filters app users by syncable Okta status" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_active",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => "active@example.com",
                      "firstName" => "Active",
                      "lastName" => "User"
                    }
                  }
                }
              },
              %{
                "id" => "appuser_2",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_provisioned",
                    "status" => "PROVISIONED",
                    "profile" => %{
                      "email" => "provisioned@example.com",
                      "firstName" => "Provisioned",
                      "lastName" => "User"
                    }
                  }
                }
              },
              %{
                "id" => "appuser_3",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_locked_out",
                    "status" => "LOCKED_OUT",
                    "profile" => %{
                      "email" => "locked-out@example.com",
                      "firstName" => "Locked",
                      "lastName" => "Out"
                    }
                  }
                }
              },
              %{
                "id" => "appuser_4",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_suspended",
                    "status" => "SUSPENDED",
                    "profile" => %{
                      "email" => "suspended@example.com",
                      "firstName" => "Suspended",
                      "lastName" => "User"
                    }
                  }
                }
              },
              %{
                "id" => "appuser_5",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_missing_status",
                    "profile" => %{
                      "email" => "missing-status@example.com",
                      "firstName" => "Missing",
                      "lastName" => "Status"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(Sync, %{directory_id: directory.id})
        end)

      identities = Repo.all(ExternalIdentity)
      identity_emails = Enum.map(identities, & &1.email) |> Enum.sort()

      assert identity_emails == [
               "active@example.com",
               "locked-out@example.com",
               "provisioned@example.com"
             ]

      assert Repo.all(Group) == []
      assert Repo.all(Membership) == []
      assert log =~ "Skipping Okta app user with missing status"
      assert log =~ "user_missing_status"
    end

    test "deletes previously synced suspended users on a later sync" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      expect_okta_identity_sync([
        %{
          "id" => "user_active",
          "status" => "ACTIVE",
          "profile" => %{
            "email" => "active@example.com",
            "firstName" => "Active",
            "lastName" => "User"
          }
        },
        %{
          "id" => "user_suspend_later",
          "status" => "ACTIVE",
          "profile" => %{
            "email" => "suspend-me@example.com",
            "firstName" => "Suspend",
            "lastName" => "Me"
          }
        }
      ])

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      suspended_identity =
        Repo.get_by!(ExternalIdentity,
          directory_id: directory.id,
          idp_id: "user_suspend_later"
        )

      suspended_actor = Repo.get_by!(Portal.Actor, id: suspended_identity.actor_id)

      expect_okta_identity_sync([
        %{
          "id" => "user_active",
          "status" => "ACTIVE",
          "profile" => %{
            "email" => "active@example.com",
            "firstName" => "Active",
            "lastName" => "User"
          }
        },
        %{
          "id" => "user_suspend_later",
          "status" => "SUSPENDED",
          "profile" => %{
            "email" => "suspend-me@example.com",
            "firstName" => "Suspend",
            "lastName" => "Me"
          }
        }
      ])

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      identities = Repo.all(ExternalIdentity)
      assert Enum.map(identities, & &1.email) == ["active@example.com"]
      assert Repo.all(Group) == []
      assert Repo.all(Membership) == []

      refute Repo.get_by(ExternalIdentity, id: suspended_identity.id)
      refute Repo.get_by(Portal.Actor, id: suspended_actor.id)
    end

    test "reconnects orphaned policies after sync" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      base_directory = Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      group =
        Portal.GroupFixtures.group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "group_123",
          name: "Engineering"
        )

      resource = Portal.ResourceFixtures.resource_fixture(account: account)

      policy =
        Portal.PolicyFixtures.policy_fixture(account: account, group: group, resource: resource)

      {1, _} =
        Repo.update_all(
          from(p in Portal.Policy, where: p.id == ^policy.id),
          set: [group_id: nil, group_idp_id: group.idp_id]
        )

      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123", "label" => "Test App"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => "alice@example.com",
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [
              %{
                "id" => "appgroup_1",
                "_embedded" => %{
                  "group" => %{
                    "id" => "group_123",
                    "profile" => %{"name" => "Engineering"}
                  }
                }
              }
            ])

          String.contains?(path, "/groups/group_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "user_123",
                "status" => "ACTIVE",
                "profile" => %{
                  "email" => "alice@example.com",
                  "firstName" => "Alice",
                  "lastName" => "Smith"
                }
              }
            ])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      assert Repo.get_by!(Portal.Policy, account_id: account.id, id: policy.id).group_id ==
               group.id
    end

    test "handles missing directory gracefully" do
      non_existent_id = Ecto.UUID.generate()

      assert :ok = perform_job(Sync, %{directory_id: non_existent_id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "returns :ok for jobs without a directory_id arg" do
      assert :ok = Sync.perform(%Oban.Job{args: %{"foo" => "bar"}})
    end

    test "handles disabled directory" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          is_disabled: true
        )

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # No data should be created
      assert Repo.all(ExternalIdentity) == []
      assert Repo.all(Group) == []
    end

    test "raises SyncError when user is missing email field" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock API calls with a user missing email
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            # Return user WITHOUT email field
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{
                      # email is missing!
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError with appropriate message
      assert_raise SyncError, ~r/missing 'email' field/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when user email is null" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock API calls with a user having null email
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [
              %{"id" => "app_123", "label" => "Test App"}
            ])

          String.contains?(path, "/apps/app_123/users") ->
            # Return user with null email
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => nil,
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError with appropriate message
      assert_raise SyncError, ~r/missing 'email' field/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when duplicate app users cause identity upsert failure" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123", "label" => "Test App"}])

          String.contains?(path, "/apps/app_123/users") ->
            duplicate_user = %{
              "id" => "appuser_1",
              "_embedded" => %{
                "user" => %{
                  "id" => "user_123",
                  "status" => "ACTIVE",
                  "profile" => %{
                    "email" => "alice@example.com",
                    "firstName" => "Alice",
                    "lastName" => "Smith"
                  }
                }
              }
            }

            Req.Test.json(conn, [duplicate_user, duplicate_user])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :batch_upsert_identities
    end

    test "raises SyncError when duplicate group members cause membership upsert failure" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123", "label" => "Test App"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => "alice@example.com",
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [
              %{
                "id" => "appgroup_1",
                "_embedded" => %{
                  "group" => %{
                    "id" => "group_123",
                    "profile" => %{"name" => "Engineering"}
                  }
                }
              }
            ])

          String.contains?(path, "/groups/group_123/users") ->
            duplicate_member = %{
              "id" => "user_123",
              "status" => "ACTIVE",
              "profile" => %{
                "email" => "alice@example.com",
                "firstName" => "Alice",
                "lastName" => "Smith"
              }
            }

            Req.Test.json(conn, [duplicate_member, duplicate_member])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :batch_upsert_memberships
    end

    test "raises SyncError when access token fetch fails" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock failed access token request
      Req.Test.expect(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      assert_raise SyncError, ~r/get_access_token/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when access token is missing required scopes" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock successful token but introspect returns missing scopes
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            # Only return okta.apps.read - missing users.read and groups.read
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read"
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert_raise SyncError, ~r/scopes: missing.*okta\.users\.read/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "raises SyncError when introspect response is missing the scope field" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{
              "access_token" => @test_access_token,
              "token_type" => "DPoP",
              "expires_in" => 3600
            })

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{"active" => true})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert_raise SyncError,
                   ~r/missing okta\.apps\.read, okta\.users\.read, okta\.groups\.read/,
                   fn ->
                     perform_job(Sync, %{directory_id: directory.id})
                   end
    end

    test "raises SyncError when apps fetch fails" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock successful token, failed apps
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error" => "forbidden"})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected"})
        end
      end)

      assert_raise SyncError, ~r/list_apps/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end
    end

    test "clears error state on successful sync" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          error_message: "Previous error",
          error_email_count: 3,
          errored_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
        )

      # Mock successful sync with empty data
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Error state should be cleared
      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
      assert updated_directory.errored_at == nil
      assert updated_directory.is_disabled == false
      refute is_nil(updated_directory.synced_at)
    end

    test "raises SyncError when app user streaming yields an error" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "boom"})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :stream_app_users
    end

    test "raises SyncError when app user payload is missing _embedded.user" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [%{"id" => "appuser_1", "_embedded" => %{}}])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :stream_app_users
      assert Exception.message(error) =~ "missing '_embedded.user' payload"
    end

    test "raises SyncError when app group streaming yields an error" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "boom"})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :stream_app_groups
    end

    test "raises SyncError when app group payload is missing _embedded.group" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [%{"id" => "appgroup_1", "_embedded" => %{}}])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :stream_app_groups
      assert Exception.message(error) =~ "missing '_embedded.group' payload"
    end

    test "filters group members by syncable Okta status" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 20, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => "alice@example.com",
                      "firstName" => "Alice",
                      "lastName" => "Smith"
                    }
                  }
                }
              },
              %{
                "id" => "appuser_2",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_456",
                    "status" => "PASSWORD_EXPIRED",
                    "profile" => %{
                      "email" => "bob@example.com",
                      "firstName" => "Bob",
                      "lastName" => "Jones"
                    }
                  }
                }
              },
              %{
                "id" => "appuser_3",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_789",
                    "status" => "ACTIVE",
                    "profile" => %{
                      "email" => "charlie@example.com",
                      "firstName" => "Charlie",
                      "lastName" => "Brown"
                    }
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [
              %{
                "id" => "appgroup_1",
                "_embedded" => %{
                  "group" => %{
                    "id" => "group_123",
                    "profile" => %{"name" => "Engineering"}
                  }
                }
              }
            ])

          String.contains?(path, "/groups/group_123/users") ->
            Req.Test.json(conn, [
              %{"id" => "user_123", "status" => "ACTIVE"},
              %{"id" => "user_456", "status" => "PASSWORD_EXPIRED"},
              %{"id" => "user_789", "status" => "LOCKED_OUT"},
              %{"id" => "user_missing_status"}
            ])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(Sync, %{directory_id: directory.id})
        end)

      memberships = Repo.all(Membership)
      assert length(memberships) == 3
      assert log =~ "Skipping Okta group member with missing status"
      assert log =~ "user_missing_status"
    end

    test "raises SyncError when group member streaming yields an error" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      Req.Test.expect(APIClient, 20, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [
              %{
                "id" => "appgroup_1",
                "_embedded" => %{
                  "group" => %{
                    "id" => "group_123",
                    "profile" => %{"name" => "Engineering"}
                  }
                }
              }
            ])

          String.contains?(path, "/groups/group_123/users") ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "boom"})

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      error =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      assert error.step == :stream_group_members
    end
  end

  describe "error handling integration" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "ErrorHandler properly records error when user missing email" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock API calls with a user missing email
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [
              %{
                "id" => "appuser_1",
                "_embedded" => %{
                  "user" => %{
                    "id" => "user_123",
                    "status" => "ACTIVE",
                    "profile" => %{"firstName" => "Alice", "lastName" => "Smith"}
                  }
                }
              }
            ])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Capture the raised exception
      exception =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      # Simulate Oban telemetry error handling
      job = %Oban.Job{
        id: 1,
        args: %{"directory_id" => directory.id},
        worker: "Portal.Okta.Sync",
        queue: "okta_sync",
        meta: %{}
      }

      meta = %{reason: exception, job: job}
      Portal.DirectorySync.ErrorHandler.handle_error(meta)

      # Verify error was recorded on directory
      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      assert updated_directory.error_message != nil
      # The error message contains the user object that caused the failure
      assert updated_directory.error_message =~ "user_123"
      assert updated_directory.errored_at != nil
    end

    test "ErrorHandler classifies 403 as client_error and disables directory" do
      account = account_fixture(features: %{idp_sync: true})

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      # Mock successful token, 403 on apps
      Req.Test.expect(APIClient, 10, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{
              "errorCode" => "E0000006",
              "errorSummary" => "Access denied"
            })

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Capture the raised exception
      exception =
        assert_raise SyncError, fn ->
          perform_job(Sync, %{directory_id: directory.id})
        end

      # Simulate Oban telemetry error handling
      job = %Oban.Job{
        id: 1,
        args: %{"directory_id" => directory.id},
        worker: "Portal.Okta.Sync",
        queue: "okta_sync",
        meta: %{}
      }

      meta = %{reason: exception, job: job}
      Portal.DirectorySync.ErrorHandler.handle_error(meta)

      updated_directory = Repo.get(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Access denied"
    end
  end

  describe "circuit breaker protection" do
    setup do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"error" => "not mocked"})
      end)

      :ok
    end

    test "raises SyncError when identity deletion is 100%" do
      account = account_fixture(features: %{idp_sync: true})

      # Create directory that has already been synced (not a first sync)
      past_sync_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: past_sync_time
        )

      # Get the base directory for associations
      base_directory =
        Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      # Create 5 existing identities
      # All with last_synced_at in the past, so they would all be deleted
      for i <- 1..5 do
        actor =
          Portal.ActorFixtures.actor_fixture(
            account: account,
            type: :account_user,
            email: "user#{i}@example.com"
          )

        Portal.IdentityFixtures.identity_fixture(
          account: account,
          actor: actor,
          directory: base_directory,
          idp_id: "okta_user_#{i}",
          issuer: "https://#{directory.okta_domain}",
          email: "user#{i}@example.com",
          last_synced_at: past_sync_time
        )
      end

      # Mock API to return zero users (simulating Okta app removal)
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            # Return empty list - all users would be deleted
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError due to circuit breaker
      assert_raise SyncError, ~r/would delete all identities/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end

      # Verify no identities were deleted
      identity_count =
        from(i in Portal.ExternalIdentity,
          where: i.directory_id == ^directory.id,
          select: count(i.id)
        )
        |> Repo.one!()

      assert identity_count == 5
    end

    test "raises SyncError when group deletion is 100%" do
      account = account_fixture(features: %{idp_sync: true})

      past_sync_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: past_sync_time
        )

      base_directory =
        Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      # Create 12 existing groups
      for i <- 1..5 do
        Portal.GroupFixtures.group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "okta_group_#{i}",
          last_synced_at: past_sync_time
        )
      end

      # Also create some identities that will sync successfully
      # (so identity check passes, but group check fails)
      for i <- 1..5 do
        actor =
          Portal.ActorFixtures.actor_fixture(
            account: account,
            type: :account_user,
            email: "user#{i}@example.com"
          )

        Portal.IdentityFixtures.identity_fixture(
          account: account,
          actor: actor,
          directory: base_directory,
          idp_id: "okta_user_#{i}",
          issuer: "https://#{directory.okta_domain}",
          email: "user#{i}@example.com",
          last_synced_at: past_sync_time
        )
      end

      # Mock API to return users but no groups
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            # Return the same users to keep them synced
            Req.Test.json(
              conn,
              for i <- 1..5 do
                %{
                  "id" => "appuser_#{i}",
                  "_embedded" => %{
                    "user" => %{
                      "id" => "okta_user_#{i}",
                      "status" => "ACTIVE",
                      "profile" => %{
                        "email" => "user#{i}@example.com",
                        "firstName" => "User",
                        "lastName" => "#{i}"
                      }
                    }
                  }
                }
              end
            )

          String.contains?(path, "/apps/app_123/groups") ->
            # Return empty list - all groups would be deleted
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should raise SyncError due to circuit breaker on groups
      assert_raise SyncError, ~r/would delete all groups/, fn ->
        perform_job(Sync, %{directory_id: directory.id})
      end

      # Verify no groups were deleted
      group_count =
        from(g in Portal.Group,
          where: g.directory_id == ^directory.id,
          select: count(g.id)
        )
        |> Repo.one!()

      assert group_count == 5
    end

    test "allows deletion below threshold" do
      account = account_fixture(features: %{idp_sync: true})

      past_sync_time = DateTime.utc_now() |> DateTime.add(-3600, :second)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: past_sync_time
        )

      base_directory =
        Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)

      # Create 10 identities - 8 will be synced, 2 will be deleted (20%)
      for i <- 1..10 do
        actor =
          Portal.ActorFixtures.actor_fixture(
            account: account,
            type: :account_user,
            email: "user#{i}@example.com"
          )

        Portal.IdentityFixtures.identity_fixture(
          account: account,
          actor: actor,
          directory: base_directory,
          idp_id: "okta_user_#{i}",
          issuer: "https://#{directory.okta_domain}",
          email: "user#{i}@example.com",
          last_synced_at: past_sync_time
        )
      end

      # Mock API to return 8 of 10 users (20% deletion)
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            # Return 8 of 10 users
            Req.Test.json(
              conn,
              for i <- 1..8 do
                %{
                  "id" => "appuser_#{i}",
                  "_embedded" => %{
                    "user" => %{
                      "id" => "okta_user_#{i}",
                      "status" => "ACTIVE",
                      "profile" => %{
                        "email" => "user#{i}@example.com",
                        "firstName" => "User",
                        "lastName" => "#{i}"
                      }
                    }
                  }
                }
              end
            )

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should succeed - deletion is below threshold
      assert :ok = perform_job(Sync, %{directory_id: directory.id})

      # Verify 2 identities were deleted
      identity_count =
        from(i in Portal.ExternalIdentity,
          where: i.directory_id == ^directory.id,
          select: count(i.id)
        )
        |> Repo.one!()

      assert identity_count == 8
    end

    test "skips threshold check on first sync" do
      account = account_fixture(features: %{idp_sync: true})

      # Create directory with synced_at = nil (first sync)
      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          synced_at: nil
        )

      # Mock API to return empty results
      Req.Test.expect(APIClient, 100, fn %{request_path: path} = conn ->
        cond do
          String.ends_with?(path, "/oauth2/v1/token") ->
            Req.Test.json(conn, %{"access_token" => @test_access_token})

          String.ends_with?(path, "/oauth2/v1/introspect") ->
            Req.Test.json(conn, %{
              "active" => true,
              "scope" => "okta.apps.read okta.users.read okta.groups.read"
            })

          String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
              not String.contains?(path, "/groups") ->
            Req.Test.json(conn, [%{"id" => "app_123"}])

          String.contains?(path, "/apps/app_123/users") ->
            Req.Test.json(conn, [])

          String.contains?(path, "/apps/app_123/groups") ->
            Req.Test.json(conn, [])

          true ->
            Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
        end
      end)

      # Should succeed even though nothing is returned (first sync)
      assert :ok = perform_job(Sync, %{directory_id: directory.id})
    end
  end

  describe "database helpers" do
    test "cover empty and error branches" do
      now = DateTime.utc_now()
      account_id = Ecto.UUID.generate()
      directory_id = Ecto.UUID.generate()
      account = account_fixture(features: %{idp_sync: true})
      directory = okta_directory_fixture(account: account)
      base_directory = Repo.get_by!(Portal.Directory, id: directory.id, account_id: account.id)
      actor = Portal.ActorFixtures.actor_fixture(account: account)

      Portal.GroupFixtures.group_fixture(
        account: account,
        directory: base_directory,
        idp_id: "group1"
      )

      Portal.IdentityFixtures.identity_fixture(
        account: account,
        actor: actor,
        directory: base_directory,
        issuer: "https://okta.example",
        idp_id: "user1"
      )

      assert {:ok, %{upserted_identities: 0}} =
               Database.batch_upsert_identities(
                 account_id,
                 "https://okta.example",
                 directory_id,
                 now,
                 []
               )

      assert {:ok, %{upserted_groups: 0}} =
               Database.batch_upsert_groups(account_id, directory_id, now, [])

      assert {:ok, %{upserted_memberships: 0}} =
               Database.batch_upsert_memberships(
                 account_id,
                 "https://okta.example",
                 directory_id,
                 now,
                 []
               )

      assert {:error, _reason} =
               Database.batch_upsert_identities(
                 account_id,
                 "https://okta.example",
                 directory_id,
                 now,
                 [%{idp_id: "user1", email: "u1@example.com", name: "User 1"}]
               )

      assert {:error, _reason} =
               Database.batch_upsert_groups(
                 account_id,
                 directory_id,
                 now,
                 [%{idp_id: "group1", name: "Group 1"}]
               )

      assert {:error, _reason} =
               Database.batch_upsert_memberships(
                 account.id,
                 "https://okta.example",
                 directory.id,
                 now,
                 [{"group1", "user1"}, {"group1", "user1"}]
               )
    end
  end

  defp expect_okta_identity_sync(app_users) do
    Req.Test.expect(APIClient, 5, fn %{request_path: path} = conn ->
      cond do
        String.ends_with?(path, "/oauth2/v1/token") ->
          Req.Test.json(conn, %{
            "access_token" => @test_access_token,
            "token_type" => "DPoP",
            "expires_in" => 3600
          })

        String.ends_with?(path, "/oauth2/v1/introspect") ->
          Req.Test.json(conn, %{
            "active" => true,
            "scope" => "okta.apps.read okta.users.read okta.groups.read"
          })

        String.ends_with?(path, "/apps") and not String.contains?(path, "/users") and
            not String.contains?(path, "/groups") ->
          Req.Test.json(conn, [
            %{"id" => "app_123", "label" => "Test App"}
          ])

        String.contains?(path, "/apps/app_123/users") ->
          users =
            Enum.with_index(app_users, 1)
            |> Enum.map(fn {user, index} ->
              %{
                "id" => "appuser_#{index}",
                "_embedded" => %{"user" => user}
              }
            end)

          Req.Test.json(conn, users)

        String.contains?(path, "/apps/app_123/groups") ->
          Req.Test.json(conn, [])

        true ->
          Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
      end
    end)
  end
end
