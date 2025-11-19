defmodule Domain.Auth.Adapters.JumpCloud.Jobs.SyncDirectoryTest do
  use Domain.DataCase, async: true
  alias Domain.{Auth, Actors}
  alias Domain.Mocks.WorkOSDirectory
  import Domain.Auth.Adapters.JumpCloud.Jobs.SyncDirectory

  describe "execute/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_jumpcloud_provider(account: account)

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

    test "syncs IdP data", %{provider: provider} do
      bypass = Bypass.open()

      groups = [
        %{
          "id" => "GROUP_ALL_ID",
          "object" => "directory_group",
          "idp_id" => "all",
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "name" => "All",
          "created_at" => "2021-10-27 15:21:50.640958",
          "updated_at" => "2021-12-13 12:15:45.531847",
          "raw_attributes" => %{}
        },
        %{
          "id" => "GROUP_ENGINEERING_ID",
          "object" => "directory_group",
          "idp_id" => "engineering",
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "name" => "Engineering",
          "created_at" => "2021-10-27 15:21:50.640958",
          "updated_at" => "2021-12-13 12:15:45.531847",
          "raw_attributes" => %{}
        }
      ]

      users = [
        %{
          "id" => "workos_user_jdoe_id",
          "object" => "directory_user",
          "custom_attributes" => %{},
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "emails" => [
            %{
              "primary" => true,
              "type" => "type",
              "value" => "jdoe@example.local"
            }
          ],
          "groups" => groups,
          "idp_id" => "USER_JDOE_ID",
          "first_name" => "John",
          "last_name" => "Doe",
          "job_title" => "Software Eng",
          "raw_attributes" => %{},
          "state" => "active",
          "username" => "jdoe@example.local",
          "created_at" => "2023-07-17T20:07:20.055Z",
          "updated_at" => "2023-07-17T20:07:20.055Z"
        },
        %{
          "id" => "workos_user_jsmith_id",
          "object" => "directory_user",
          "custom_attributes" => %{},
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "emails" => [
            %{
              "primary" => true,
              "type" => "type",
              "value" => "jsmith@example.local"
            }
          ],
          "groups" => groups,
          "idp_id" => "USER_JSMITH_ID",
          "first_name" => "Jane",
          "last_name" => "Smith",
          "job_title" => "Software Eng",
          "raw_attributes" => %{},
          "state" => "active",
          "username" => "jsmith@example.local",
          "created_at" => "2023-07-17T20:07:20.055Z",
          "updated_at" => "2023-07-17T20:07:20.055Z"
        }
      ]

      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")
      WorkOSDirectory.mock_list_directories_endpoint(bypass)
      WorkOSDirectory.mock_list_users_endpoint(bypass, users)
      WorkOSDirectory.mock_list_groups_endpoint(bypass, groups)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      groups = Actors.Group |> Repo.all()
      assert length(groups) == 2

      for group <- groups do
        assert group.provider_identifier in ["G:GROUP_ALL_ID", "G:GROUP_ENGINEERING_ID"]
        assert group.name in ["Group:All", "Group:Engineering"]

        assert group.inserted_at
        assert group.updated_at

        assert group.created_by == :provider
        assert group.provider_id == provider.id
      end

      identities = Auth.Identity |> Repo.all() |> Repo.preload(:actor)
      assert length(identities) == 2

      for identity <- identities do
        assert identity.inserted_at
        assert identity.created_by == :provider
        assert identity.provider_id == provider.id
        assert identity.provider_identifier in ["USER_JDOE_ID", "USER_JSMITH_ID"]

        assert identity.provider_state in [
                 %{"userinfo" => %{"email" => "jdoe@example.local"}},
                 %{"userinfo" => %{"email" => "jsmith@example.local"}}
               ]

        assert identity.actor.name in ["John Doe", "Jane Smith"]
      end

      memberships = Actors.Membership |> Repo.all()
      assert length(memberships) == 4

      updated_provider = Repo.get!(Domain.Auth.Provider, provider.id)
      assert updated_provider.last_synced_at != provider.last_synced_at
    end

    test "does not crash on endpoint errors" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert Repo.aggregate(Actors.Group, :count) == 0
    end

    test "updates existing identities and actors", %{account: account, provider: provider} do
      bypass = Bypass.open()

      users = [
        %{
          "id" => "workos_user_jdoe_id",
          "object" => "directory_user",
          "custom_attributes" => %{},
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "emails" => [
            %{
              "primary" => true,
              "type" => "type",
              "value" => "jdoe@example.local"
            }
          ],
          "groups" => [],
          "idp_id" => "USER_JDOE_ID",
          "first_name" => "John",
          "last_name" => "Doe",
          "job_title" => "Software Eng",
          "raw_attributes" => %{},
          "state" => "active",
          "username" => "jdoe@example.local",
          "created_at" => "2023-07-17T20:07:20.055Z",
          "updated_at" => "2023-07-17T20:07:20.055Z"
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

      assert original_identity =
               Repo.get(Domain.Auth.Identity, identity.id)
               |> Repo.preload(:actor)

      refute original_identity.actor.name == "John Doe"

      refute original_identity.provider_state == %{
               "userinfo" => %{"email" => "jdoe@example.local"}
             }

      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")
      WorkOSDirectory.mock_list_directories_endpoint(bypass)
      WorkOSDirectory.mock_list_users_endpoint(bypass, users)
      WorkOSDirectory.mock_list_groups_endpoint(bypass)

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_identity =
               Repo.get(Domain.Auth.Identity, identity.id)
               |> Repo.preload(:actor)

      assert updated_identity.provider_state == %{
               "userinfo" => %{"email" => "jdoe@example.local"}
             }

      assert updated_identity.actor.name == "John Doe"
    end

    test "updates existing groups and memberships", %{account: account, provider: provider} do
      bypass = Bypass.open()

      group_all = %{
        "id" => "GROUP_ALL_ID",
        "object" => "directory_group",
        "idp_id" => "all",
        "directory_id" => "dir_123",
        "organization_id" => "org_123",
        "name" => "All",
        "created_at" => "2021-10-27 15:21:50.640958",
        "updated_at" => "2021-12-13 12:15:45.531847",
        "raw_attributes" => %{}
      }

      group_engineering = %{
        "id" => "GROUP_ENGINEERING_ID",
        "object" => "directory_group",
        "idp_id" => "engineering",
        "directory_id" => "dir_123",
        "organization_id" => "org_123",
        "name" => "Engineering",
        "created_at" => "2021-10-27 15:21:50.640958",
        "updated_at" => "2021-12-13 12:15:45.531847",
        "raw_attributes" => %{}
      }

      group_finance = %{
        "id" => "GROUP_FINANCE_ID",
        "object" => "directory_group",
        "idp_id" => "finance",
        "directory_id" => "dir_123",
        "organization_id" => "org_123",
        "name" => "Finance",
        "created_at" => "2021-10-28 15:21:50.640958",
        "updated_at" => "2021-12-14 12:15:45.531847",
        "raw_attributes" => %{}
      }

      users = [
        %{
          "id" => "workos_user_jdoe_id",
          "object" => "directory_user",
          "custom_attributes" => %{},
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "emails" => [
            %{
              "primary" => true,
              "type" => "type",
              "value" => "jdoe@example.local"
            }
          ],
          "groups" => [group_all, group_engineering],
          "idp_id" => "USER_JDOE_ID",
          "first_name" => "John",
          "last_name" => "Doe",
          "job_title" => "Software Eng",
          "raw_attributes" => %{},
          "state" => "active",
          "username" => "jdoe@example.local",
          "created_at" => "2023-07-17T20:07:20.055Z",
          "updated_at" => "2023-07-17T20:07:20.055Z"
        },
        %{
          "id" => "workos_user_jsmith_id",
          "object" => "directory_user",
          "custom_attributes" => %{},
          "directory_id" => "dir_123",
          "organization_id" => "org_123",
          "emails" => [
            %{
              "primary" => true,
              "type" => "type",
              "value" => "jsmith@example.local"
            }
          ],
          "groups" => [group_all],
          "idp_id" => "USER_JSMITH_ID",
          "first_name" => "Jane",
          "last_name" => "Smith",
          "job_title" => "Software Eng",
          "raw_attributes" => %{},
          "state" => "active",
          "username" => "jsmith@example.local",
          "created_at" => "2023-07-17T20:07:20.055Z",
          "updated_at" => "2023-07-17T20:07:20.055Z"
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
          provider_identifier: "G:GROUP_ALL_ID"
        )

      _group_finance =
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
      Fixtures.Actors.create_membership(account: account, actor: actor, group: deleted_group)

      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")
      WorkOSDirectory.mock_list_directories_endpoint(bypass)
      WorkOSDirectory.mock_list_users_endpoint(bypass, users)

      WorkOSDirectory.mock_list_groups_endpoint(bypass, [
        group_all,
        group_engineering,
        group_finance
      ])

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_group = Repo.get(Domain.Actors.Group, group.id)
      assert updated_group.name == "Group:All"

      assert created_group =
               Repo.get_by(Domain.Actors.Group, provider_identifier: "G:GROUP_ENGINEERING_ID")

      assert created_group.name == "Group:Engineering"

      assert memberships = Repo.all(Domain.Actors.Membership.Query.all())
      assert length(memberships) == 4

      assert memberships = Repo.all(Domain.Actors.Membership.Query.with_joined_groups())
      assert length(memberships) == 4

      membership_group_ids = Enum.map(memberships, & &1.group_id)
      assert group.id in membership_group_ids
      assert deleted_group.id not in membership_group_ids

      # Deletes membership for a deleted group
      refute Repo.get_by(Domain.Actors.Membership, group_id: deleted_group.id)

      # Created membership for a new group
      assert Repo.get_by(
               Domain.Actors.Membership,
               actor_id: actor.id,
               group_id: created_group.id
             )

      # Created membership for a member of existing group
      assert Repo.get_by(
               Domain.Actors.Membership,
               actor_id: other_actor.id,
               group_id: group.id
             )

      # Deletes membership that is not found on IdP end
      refute Repo.get_by(Domain.Actors.Membership, group_id: deleted_group.id)

      # Signs out users which identity has been deleted
      refute Repo.reload(deleted_identity_token)
    end

    test "stops the sync retires on 401 error from WorkOS", %{provider: provider} do
      bypass = Bypass.open()
      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")

      error_message = "Error connecting to WorkOS"

      response = %{"message" => "Unauthorized"}

      for path <- [
            "/directories",
            "/directory_users",
            "/directory_groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
          |> Plug.Conn.send_resp(401, JSON.encode!(response))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1
      assert updated_provider.last_sync_error == error_message
    end

    test "persists the sync error on the provider", %{provider: provider} do
      bypass = Bypass.open()

      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")

      for path <- [
            "/directories",
            "/directory_users",
            "/directory_groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
          |> Plug.Conn.send_resp(500, JSON.encode!(%{}))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 1
      assert updated_provider.last_sync_error == "Error connecting to WorkOS"

      for path <- [
            "/directories",
            "/directory_users",
            "/directory_groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
          |> Plug.Conn.send_resp(500, JSON.encode!(%{}))
        end)
      end

      {:ok, pid} = Task.Supervisor.start_link()
      assert execute(%{task_supervisor: pid}) == :ok

      assert updated_provider = Repo.get(Domain.Auth.Provider, provider.id)
      refute updated_provider.last_synced_at
      assert updated_provider.last_syncs_failed == 2
      assert updated_provider.last_sync_error == "Error connecting to WorkOS"

      cancel_bypass_expectations_check(bypass)
    end

    test "sends email on failed directory sync", %{account: account, provider: provider} do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      _identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      bypass = Bypass.open()

      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")

      for path <- [
            "/directories",
            "/directory_users",
            "/directory_groups"
          ] do
        Bypass.stub(bypass, "GET", path, fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers([{"content-type", "application/json"}])
          |> Plug.Conn.send_resp(500, JSON.encode!(%{}))
        end)
      end

      provider
      |> Ecto.Changeset.change(last_syncs_failed: 9)
      |> Repo.update!()

      {:ok, pid} = Task.Supervisor.start_link()
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
