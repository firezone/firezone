defmodule Domain.Auth.Adapters.Okta.Jobs.SyncDirectoryTest do
  use Domain.DataCase, async: true
  alias Domain.{Auth, Actors}
  alias Domain.Mocks.OktaDirectory
  import Domain.Auth.Adapters.Okta.Jobs.SyncDirectory

  describe "execute/1" do
    setup do
      jwk = %{
        "kty" => "oct",
        "k" => :jose_base64url.encode("super_secret_key")
      }

      jws = %{
        "alg" => "HS256"
      }

      claims = %{
        "sub" => "1234567890",
        "name" => "FooBar",
        "iat" => DateTime.utc_now() |> DateTime.to_unix(),
        "exp" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      }

      {_, jwt} =
        JOSE.JWT.sign(jwk, jws, claims)
        |> JOSE.JWS.compact()

      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_okta_provider(account: account, access_token: jwt)

      %{
        bypass: bypass,
        account: account,
        provider: provider
      }
    end

    test "returns error when IdP sync is not enabled", %{account: account, provider: provider} do
      {:ok, _account} = Domain.Accounts.update_account(account, %{features: %{idp_sync: false}})

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1

      assert updated_provider.last_sync_error ==
               "IdP sync is not enabled in your subscription plan"
    end

    test "syncs IdP data", %{provider: provider, bypass: bypass} do
      groups = [
        %{
          "id" => "GROUP_DEVOPS_ID",
          "created" => "2024-02-07T04:32:03.000Z",
          "lastUpdated" => "2024-02-07T04:32:03.000Z",
          "lastMembershipUpdated" => "2024-02-07T04:32:38.000Z",
          "objectClass" => [
            "okta:user_group"
          ],
          "type" => "OKTA_GROUP",
          "profile" => %{
            "name" => "DevOps",
            "description" => ""
          },
          "_links" => %{
            "logo" => [
              %{
                "name" => "medium",
                "href" => "http://localhost/md/image.png",
                "type" => "image/png"
              },
              %{
                "name" => "large",
                "href" => "http://localhost/lg/image.png",
                "type" => "image/png"
              }
            ],
            "users" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqhvv4IFj2Avg5d7/users"
            },
            "apps" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqhvv4IFj2Avg5d7/apps"
            }
          }
        },
        %{
          "id" => "GROUP_ENGINEERING_ID",
          "created" => "2024-02-07T04:30:49.000Z",
          "lastUpdated" => "2024-02-07T04:30:49.000Z",
          "lastMembershipUpdated" => "2024-02-07T04:32:23.000Z",
          "objectClass" => [
            "okta:user_group"
          ],
          "type" => "OKTA_GROUP",
          "profile" => %{
            "name" => "Engineering",
            "description" => "All of Engineering"
          },
          "_links" => %{
            "logo" => [
              %{
                "name" => "medium",
                "href" => "http://localhost/md/image.png",
                "type" => "image/png"
              },
              %{
                "name" => "large",
                "href" => "http://localhost/lg/image.png",
                "type" => "image/png"
              }
            ],
            "users" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqfqxwa2ohLhp5d7/users"
            },
            "apps" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqfqxwa2ohLhp5d7/apps"
            }
          }
        }
      ]

      users = [
        %{
          "id" => "USER_JDOE_ID",
          "status" => "ACTIVE",
          "created" => "2023-12-21T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-12-21T20:04:06.000Z",
          "lastLogin" => "2024-02-08T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "John",
            "lastName" => "Doe",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jdoe@example.com",
            "email" => "jdoe@example.com"
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/OT6AZkcmzkDXwkXcjTHY"
            }
          }
        },
        %{
          "id" => "USER_JSMITH_ID",
          "status" => "ACTIVE",
          "created" => "2023-10-23T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-11-21T20:04:06.000Z",
          "lastLogin" => "2024-02-02T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "Jane",
            "lastName" => "Smith",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jsmith@example.com",
            "email" => "jsmith@example.com"
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/I5OsjUZAUVJr4BvNVp3l"
            }
          }
        }
      ]

      members = [
        %{
          "id" => "USER_JDOE_ID",
          "status" => "ACTIVE",
          "created" => "2023-12-21T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-12-21T20:04:06.000Z",
          "lastLogin" => "2024-02-08T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "John",
            "lastName" => "Doe",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jdoe@example.com",
            "email" => "jdoe@example.com"
          },
          "credentials" => %{
            "password" => %{},
            "emails" => [
              %{
                "value" => "jdoe@example.com",
                "status" => "VERIFIED",
                "type" => "PRIMARY"
              }
            ],
            "provider" => %{
              "type" => "OKTA",
              "name" => "OKTA"
            }
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/OT6AZkcmzkDXwkXcjTHY"
            }
          }
        },
        %{
          "id" => "USER_JSMITH_ID",
          "status" => "ACTIVE",
          "created" => "2023-10-23T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-11-21T20:04:06.000Z",
          "lastLogin" => "2024-02-02T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "Jane",
            "lastName" => "Smith",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jsmith@example.com",
            "email" => "jsmith@example.com"
          },
          "credentials" => %{
            "password" => %{},
            "emails" => [
              %{
                "value" => "jsmith@example.com",
                "status" => "VERIFIED",
                "type" => "PRIMARY"
              }
            ],
            "provider" => %{
              "type" => "OKTA",
              "name" => "OKTA"
            }
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/I5OsjUZAUVJr4BvNVp3l"
            }
          }
        }
      ]

      OktaDirectory.mock_groups_list_endpoint(bypass, 200, JSON.encode!(groups))
      OktaDirectory.mock_users_list_endpoint(bypass, 200, JSON.encode!(users))

      Enum.each(groups, fn group ->
        OktaDirectory.mock_group_members_list_endpoint(
          bypass,
          group["id"],
          200,
          JSON.encode!(members)
        )
      end)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      groups = Actors.Group |> Repo.all()
      assert length(groups) == 2

      for group <- groups do
        assert group.provider_identifier in ["G:GROUP_ENGINEERING_ID", "G:GROUP_DEVOPS_ID"]
        assert group.name in ["Group:Engineering", "Group:DevOps"]

        assert group.inserted_at
        assert group.updated_at

        assert group.provider_id == provider.id
      end

      identities = ExternalIdentity |> Repo.all() |> Repo.preload(:actor)
      assert length(identities) == 2

      for identity <- identities do
        assert identity.inserted_at
        assert identity.provider_id == provider.id
        assert identity.provider_identifier in ["USER_JDOE_ID", "USER_JSMITH_ID"]

        assert identity.provider_state in [
                 %{"userinfo" => %{"email" => "jdoe@example.com"}},
                 %{"userinfo" => %{"email" => "jsmith@example.com"}}
               ]

        assert identity.actor.name in ["John Doe", "Jane Smith"]
      end

      memberships = Actors.Membership |> Repo.all()
      assert length(memberships) == 4

      updated_provider = Repo.get!(Domain.Auth.Provider, provider.id)
      assert updated_provider.last_synced_at != provider.last_synced_at
    end

    test "does not crash on endpoint errors", %{bypass: bypass} do
      Bypass.down(bypass)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert Repo.aggregate(Actors.Group, :count) == 0
    end

    test "updates existing identities and actors", %{
      account: account,
      provider: provider,
      bypass: bypass
    } do
      users = [
        %{
          "id" => "USER_JDOE_ID",
          "status" => "ACTIVE",
          "created" => "2023-12-21T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-12-21T20:04:06.000Z",
          "lastLogin" => "2024-02-08T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "John",
            "lastName" => "Doe",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jdoe@example.com",
            "email" => "jdoe@example.com"
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/OT6AZkcmzkDXwkXcjTHY"
            }
          }
        }
      ]

      actor = Fixtures.Actors.create_actor(account: account)

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: actor,
          provider_identifier: "USER_JDOE_ID"
        )

      OktaDirectory.mock_groups_list_endpoint(bypass, 200, JSON.encode!([]))
      OktaDirectory.mock_users_list_endpoint(bypass, 200, JSON.encode!(users))

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_identity =
               Repo.get(Domain.ExternalIdentity, identity.id)
               |> Repo.preload(:actor)

      assert updated_identity.provider_state == %{
               "userinfo" => %{"email" => "jdoe@example.com"}
             }

      assert updated_identity.actor.name == "John Doe"
    end

    test "updates existing groups and memberships", %{
      account: account,
      provider: provider,
      bypass: bypass
    } do
      users = [
        %{
          "id" => "USER_JDOE_ID",
          "status" => "ACTIVE",
          "created" => "2023-12-21T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-12-21T20:04:06.000Z",
          "lastLogin" => "2024-02-08T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "John",
            "lastName" => "Doe",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jdoe@example.com",
            "email" => "jdoe@example.com"
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/OT6AZkcmzkDXwkXcjTHY"
            }
          }
        },
        %{
          "id" => "USER_JSMITH_ID",
          "status" => "ACTIVE",
          "created" => "2023-10-23T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-11-21T20:04:06.000Z",
          "lastLogin" => "2024-02-02T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "Jane",
            "lastName" => "Smith",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jsmith@example.com",
            "email" => "jsmith@example.com"
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/I5OsjUZAUVJr4BvNVp3l"
            }
          }
        }
      ]

      groups = [
        %{
          "id" => "GROUP_DEVOPS_ID",
          "created" => "2024-02-07T04:32:03.000Z",
          "lastUpdated" => "2024-02-07T04:32:03.000Z",
          "lastMembershipUpdated" => "2024-02-07T04:32:38.000Z",
          "objectClass" => [
            "okta:user_group"
          ],
          "type" => "OKTA_GROUP",
          "profile" => %{
            "name" => "DevOps",
            "description" => ""
          },
          "_links" => %{
            "logo" => [
              %{
                "name" => "medium",
                "href" => "http://localhost/md/image.png",
                "type" => "image/png"
              },
              %{
                "name" => "large",
                "href" => "http://localhost/lg/image.png",
                "type" => "image/png"
              }
            ],
            "users" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqhvv4IFj2Avg5d7/users"
            },
            "apps" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqhvv4IFj2Avg5d7/apps"
            }
          }
        },
        %{
          "id" => "GROUP_ENGINEERING_ID",
          "created" => "2024-02-07T04:30:49.000Z",
          "lastUpdated" => "2024-02-07T04:30:49.000Z",
          "lastMembershipUpdated" => "2024-02-07T04:32:23.000Z",
          "objectClass" => [
            "okta:user_group"
          ],
          "type" => "OKTA_GROUP",
          "profile" => %{
            "name" => "Engineering",
            "description" => "All of Engineering"
          },
          "_links" => %{
            "logo" => [
              %{
                "name" => "medium",
                "href" => "http://localhost/md/image.png",
                "type" => "image/png"
              },
              %{
                "name" => "large",
                "href" => "http://localhost/lg/image.png",
                "type" => "image/png"
              }
            ],
            "users" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqfqxwa2ohLhp5d7/users"
            },
            "apps" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqfqxwa2ohLhp5d7/apps"
            }
          }
        },
        %{
          "id" => "GROUP_FINANCE_ID",
          "created" => "2024-02-07T05:30:49.000Z",
          "lastUpdated" => "2024-02-07T05:30:49.000Z",
          "lastMembershipUpdated" => "2024-02-07T05:32:23.000Z",
          "objectClass" => [
            "okta:user_group"
          ],
          "type" => "OKTA_GROUP",
          "profile" => %{
            "name" => "Finance",
            "description" => "Finance Dept"
          },
          "_links" => %{
            "logo" => [
              %{
                "name" => "medium",
                "href" => "http://localhost/md/image.png",
                "type" => "image/png"
              },
              %{
                "name" => "large",
                "href" => "http://localhost/lg/image.png",
                "type" => "image/png"
              }
            ],
            "users" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqfqxwa2ohLmp5d7/users"
            },
            "apps" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/groups/00gezqfqxwa2ohLmp5d7/apps"
            }
          }
        }
      ]

      one_member = [
        %{
          "id" => "USER_JDOE_ID",
          "status" => "ACTIVE",
          "created" => "2023-12-21T18:30:05.000Z",
          "activated" => nil,
          "statusChanged" => "2023-12-21T20:04:06.000Z",
          "lastLogin" => "2024-02-08T05:14:25.000Z",
          "lastUpdated" => "2023-12-21T20:04:06.000Z",
          "passwordChanged" => "2023-12-21T20:04:06.000Z",
          "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
          "profile" => %{
            "firstName" => "John",
            "lastName" => "Doe",
            "mobilePhone" => nil,
            "secondEmail" => nil,
            "login" => "jdoe@example.com",
            "email" => "jdoe@example.com"
          },
          "credentials" => %{
            "password" => %{},
            "emails" => [
              %{
                "value" => "jdoe@example.com",
                "status" => "VERIFIED",
                "type" => "PRIMARY"
              }
            ],
            "provider" => %{
              "type" => "OKTA",
              "name" => "OKTA"
            }
          },
          "_links" => %{
            "self" => %{
              "href" => "http://localhost:#{bypass.port}/api/v1/users/OT6AZkcmzkDXwkXcjTHY"
            }
          }
        }
      ]

      two_members =
        one_member ++
          [
            %{
              "id" => "USER_JSMITH_ID",
              "status" => "ACTIVE",
              "created" => "2023-10-23T18:30:05.000Z",
              "activated" => nil,
              "statusChanged" => "2023-11-21T20:04:06.000Z",
              "lastLogin" => "2024-02-02T05:14:25.000Z",
              "lastUpdated" => "2023-12-21T20:04:06.000Z",
              "passwordChanged" => "2023-12-21T20:04:06.000Z",
              "type" => %{"id" => "otye1rmouoEfu7KCV5d7"},
              "profile" => %{
                "firstName" => "Jane",
                "lastName" => "Smith",
                "mobilePhone" => nil,
                "secondEmail" => nil,
                "login" => "jsmith@example.com",
                "email" => "jsmith@example.com"
              },
              "credentials" => %{
                "password" => %{},
                "emails" => [
                  %{
                    "value" => "jsmith@example.com",
                    "status" => "VERIFIED",
                    "type" => "PRIMARY"
                  }
                ],
                "provider" => %{
                  "type" => "OKTA",
                  "name" => "OKTA"
                }
              },
              "_links" => %{
                "self" => %{
                  "href" => "http://localhost:#{bypass.port}/api/v1/users/I5OsjUZAUVJr4BvNVp3l"
                }
              }
            }
          ]

      actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_identifier: "USER_JDOE_ID"
      )

      other_actor = Fixtures.Actors.create_actor(account: account)

      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: other_actor,
        provider_identifier: "USER_JSMITH_ID"
      )

      deleted_identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: other_actor,
          provider_identifier: "USER_JSMITH_ID2"
        )

      deleted_identity_token =
        Fixtures.Tokens.create_token(
          account: account,
          actor: other_actor,
          identity: deleted_identity
        )

      group =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_ENGINEERING_ID"
        )

      _group2 =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:GROUP_FINANCE_ID"
        )

      deleted_group =
        Fixtures.Actors.create_group(
          account: account,
          provider: provider,
          provider_identifier: "G:DELETED_GROUP_ID!"
        )

      Fixtures.Actors.create_membership(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: group)
      deleted_membership = Fixtures.Actors.create_membership(account: account, group: group)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: deleted_group)

      OktaDirectory.mock_groups_list_endpoint(bypass, 200, JSON.encode!(groups))
      OktaDirectory.mock_users_list_endpoint(bypass, 200, JSON.encode!(users))

      OktaDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_ENGINEERING_ID",
        200,
        JSON.encode!(two_members)
      )

      OktaDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_DEVOPS_ID",
        200,
        JSON.encode!(one_member)
      )

      OktaDirectory.mock_group_members_list_endpoint(
        bypass,
        "GROUP_FINANCE_ID",
        200,
        JSON.encode!([])
      )

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_group = Repo.get(Domain.Actors.Group, group.id)
      assert updated_group.name == "Group:Engineering"

      assert created_group =
               Repo.get_by(Domain.Actors.Group, provider_identifier: "G:GROUP_DEVOPS_ID")

      assert created_group.name == "Group:DevOps"

      assert memberships = Repo.all(Domain.Actors.Membership.Query.all())
      assert length(memberships) == 4

      assert memberships = Repo.all(Domain.Actors.Membership.Query.with_joined_groups())
      assert length(memberships) == 4

      membership_group_ids = Enum.map(memberships, & &1.group_id)
      assert group.id in membership_group_ids
      assert deleted_group.id not in membership_group_ids

      # Deletes membership for a deleted group
      refute Repo.get_by(Domain.Actors.Membership, group_id: deleted_group.id)

      # Creates membership for a new group
      assert Repo.get_by(Domain.Actors.Membership, actor_id: actor.id, group_id: created_group.id)

      # Creates membership for a member of existing group
      assert Repo.get_by(Domain.Actors.Membership, actor_id: other_actor.id, group_id: group.id)

      # Deletes membership that is not found on IdP end
      refute Repo.get_by(Domain.Actors.Membership,
               actor_id: deleted_membership.actor_id,
               group_id: deleted_membership.group_id
             )

      # Signs out users which identity has been deleted
      refute Repo.reload(deleted_identity_token)
    end

    test "persists the sync error on the provider", %{provider: provider, bypass: bypass} do
      response = %{
        "errorCode" => "E0000011",
        "errorSummary" => "Invalid token provided",
        "errorLink" => "E0000011",
        "errorId" => "sampleU-5P2FZVslkYBMP_Rsq",
        "errorCauses" => []
      }

      error_message = "#{response["errorCode"]} => #{response["errorSummary"]}"

      for path <- [
            "api/v1/users",
            "api/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 401, JSON.encode!(response))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1
      assert updated_provider.last_sync_error == error_message

      for path <- [
            "api/v1/users",
            "api/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 500, "")
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 2
      assert updated_provider.last_sync_error == "Okta API is temporarily unavailable"

      cancel_bypass_expectations_check(bypass)
    end

    test "sends email on failed directory sync when errors are in body", %{
      account: account,
      provider: provider,
      bypass: bypass
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      _identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      response = %{
        "errorCode" => "E0000011",
        "errorSummary" => "Invalid token provided",
        "errorLink" => "E0000011",
        "errorId" => "sampleU-5P2FZVslkYBMP_Rsq",
        "errorCauses" => []
      }

      for path <- [
            "api/v1/users",
            "api/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          Plug.Conn.send_resp(conn, 401, JSON.encode!(response))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()

      provider
      |> Ecto.Changeset.change(last_syncs_failed: 9)
      |> Repo.update!()

      assert execute(%{task_supervisor: pid}) == :ok

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Identity Provider Sync Error"
        assert email.text_body =~ "failed to sync 10 time(s)"
      end)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      refute_email_sent()

      cancel_bypass_expectations_check(bypass)
    end

    test "sends email on failed directory sync when errors are in header", %{
      account: account,
      provider: provider,
      bypass: bypass
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      _identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      # Okta returns 401 with error info in www-authenticate header
      www_authenticate_header =
        "Bearer authorization_uri=\"http://example.okta.com/oauth2/v1/authorize\", " <>
          "realm=\"http://example.okta.com\", " <>
          "scope=\"okta.groups.read\", " <>
          "error=\"invalid_token\", " <>
          "error_description=\"The token has expired.\", " <>
          "resource=\"/api/v1/groups\""

      for path <- [
            "api/v1/users",
            "api/v1/groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", www_authenticate_header)
          |> Plug.Conn.send_resp(401, "")
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()

      provider
      |> Ecto.Changeset.change(last_syncs_failed: 9)
      |> Repo.update!()

      assert execute(%{task_supervisor: pid}) == :ok

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Identity Provider Sync Error"
        assert email.text_body =~ "failed to sync 10 time(s)"
      end)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      refute_email_sent()

      cancel_bypass_expectations_check(bypass)
    end
  end
end
