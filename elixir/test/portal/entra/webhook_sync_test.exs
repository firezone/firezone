defmodule Portal.Entra.WebhookSyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query

  import Portal.AccountFixtures
  import Portal.ObanFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.RepoQueryHelpers

  alias Portal.Actor
  alias Portal.Entra.Sync
  alias Portal.Entra.WebhookSync
  alias Portal.ExternalIdentity
  alias Portal.ExternalIdentitySyncState
  alias Portal.Group
  alias Portal.Membership
  alias Portal.Microsoft.Graph.APIClient

  setup do
    account = account_fixture(features: %{idp_sync: true})
    directory = entra_directory_fixture(account: account, sync_all_groups: false)
    base_directory = Repo.get_by!(Portal.Directory, id: directory.id)

    Req.Test.stub(APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    %{
      account: account,
      directory: directory,
      base_directory: base_directory,
      issuer: Sync.issuer(directory)
    }
  end

  describe "user notifications" do
    test "updates an existing identity", %{account: account, directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name", email: "old@example.com")

      stub_graph(users: %{"user-1" => graph_user("user-1", "New Name", "new@example.com")})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      identity = Repo.get_by!(ExternalIdentity, id: identity.id)
      assert identity.name == "New Name"
      assert identity.email == "new@example.com"
      assert identity.directory_id == directory.id

      state = Repo.get_by!(ExternalIdentitySyncState, external_identity_id: identity.id)
      assert DateTime.diff(DateTime.utc_now(), state.synced_at) < 5
      assert account.id == identity.account_id
    end

    test "an older full-sync write does not undo the webhook write",
         %{directory: directory, issuer: issuer} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name")
      stub_graph(users: %{"user-1" => graph_user("user-1", "Webhook Name", "u1@example.com")})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      stale_synced_at = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Sync.Database.batch_upsert_identities(directory.account_id, issuer, directory.id, stale_synced_at, [
          %{idp_id: "user-1", email: "stale@example.com", name: "Stale Name"}
        ])

      assert Repo.get_by!(ExternalIdentity, id: identity.id).name == "Webhook Name"
    end

    test "removes a disabled user with their memberships and directory actor",
         %{directory: directory, base_directory: base_directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      group = group_fixture(account: ctx.account, directory: base_directory, idp_id: "group-1")
      membership_fixture(actor: actor, group: group)

      stub_graph(users: %{"user-1" => graph_user("user-1", "Gone", "u1@example.com", false)})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
      refute Repo.get_by(Membership, actor_id: actor.id)
      refute Repo.get_by(Actor, id: actor.id)
    end

    test "removes an identity, its memberships, and its actor in one transaction",
         %{directory: directory, base_directory: base_directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      group = group_fixture(account: ctx.account, directory: base_directory, idp_id: "group-1")
      membership_fixture(actor: actor, group: group)
      stub_graph(users: %{})

      queries =
        capture_queries(fn ->
          assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))
        end)

      assert one_transaction?(queries, ~s(DELETE FROM "external_identities"), ~s(DELETE FROM "actors"))
      refute Repo.get_by(Actor, id: actor.id)
    end

    test "locks the actor before removing its identity", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      mark_created_by_directory(identity.actor_id, directory)
      stub_graph(users: %{})

      queries =
        capture_queries(fn ->
          assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))
        end)

      assert one_transaction?(queries, "FOR UPDATE", ~s(DELETE FROM "external_identities"))
    end

    test "leaves other actors of the directory alone when removing a user",
         %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      mark_created_by_directory(identity.actor_id, directory)
      orphan = Portal.ActorFixtures.actor_fixture(account: ctx.account)
      mark_created_by_directory(orphan.id, directory)
      stub_graph(users: %{})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

      refute Repo.get_by(Actor, id: identity.actor_id)
      assert Repo.get_by(Actor, id: orphan.id)
    end

    test "removes a user Graph no longer returns", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      stub_graph(users: %{})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "removes a user on a deleted notification once Graph confirms it",
         %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      stub_graph(users: %{})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "keeps a user Graph restored after a stale deleted notification",
         %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name")
      stub_graph(users: %{"user-1" => graph_user("user-1", "Restored", "u1@example.com")})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

      assert Repo.get_by!(ExternalIdentity, id: identity.id).name == "Restored"
    end

    test "keeps an actor that still has other identities", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      other = identity_fixture(account: ctx.account, actor: actor)
      stub_graph(users: %{})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
      assert Repo.get_by(ExternalIdentity, id: other.id)
      assert Repo.get_by(Actor, id: actor.id)
    end

    test "ignores users this directory does not know", %{directory: directory} do
      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      assert Repo.all(ExternalIdentity) == []
    end

    test "skips a user whose email is invalid", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name")
      stub_graph(users: %{"user-1" => graph_user("user-1", "Bad", "not-an-email")})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      assert Repo.get_by!(ExternalIdentity, id: identity.id).name == "Old Name"
    end

    test "fails on unexpected Graph errors", %{directory: directory} = ctx do
      directory_identity(ctx, "user-1")

      Req.Test.stub(APIClient, fn conn ->
        if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "token"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
        end
      end)

      assert_raise Portal.Entra.SyncError, fn ->
        perform_job(WebhookSync, user_args(directory, "user-1", "updated"))
      end
    end
  end

  describe "group notifications" do
    test "ignores untracked groups when syncing assigned groups only", %{directory: directory} do
      stub_graph(groups: %{"group-1" => {"Engineering", [graph_user("user-1", "Alice", "a@example.com")]}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      assert Repo.all(Group) == []
      assert Repo.all(ExternalIdentity) == []
    end

    test "reconciles tracked parents of an untracked child",
         %{account: account, directory: directory, base_directory: base_directory} do
      parent =
        group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "parent",
          nested_group_idp_ids: ["child"]
        )

      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(groups: %{"child" => {"Child", [alice]}, "parent" => {"Parent", [graph_group("child")]}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "updated"))

      refute Repo.get_by(Group, idp_id: "child")
      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: parent.id)
    end

    test "renames a tracked group and reconciles its members",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      group =
        group_fixture(account: account, directory: base_directory, idp_id: "group-1", name: "Old")

      carol = directory_identity(ctx, "user-carol")
      carol_actor = Actor |> Repo.get_by!(id: carol.actor_id) |> Repo.preload(:account)
      membership_fixture(actor: carol_actor, group: group)

      stub_graph(
        groups: %{
          "group-1" => {"Engineering", [graph_user("user-alice", "Alice", "alice@example.com")]}
        }
      )

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      group = Repo.get_by!(Group, id: group.id)
      assert group.name == "Engineering"

      alice = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert alice.directory_id == directory.id
      assert Repo.get_by(Membership, actor_id: alice.actor_id, group_id: group.id)

      refute Repo.get_by(Membership, actor_id: carol_actor.id, group_id: group.id)
      assert Repo.get_by(ExternalIdentity, id: carol.id)
    end

    test "reconciles tracked parent groups too",
         %{account: account, directory: directory, base_directory: base_directory} do
      child = group_fixture(account: account, directory: base_directory, idp_id: "child")

      parent =
        group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "parent",
          nested_group_idp_ids: ["child"]
        )

      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(groups: %{"child" => {"Child", [alice]}, "parent" => {"Parent", [graph_group("child")]}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "updated"))

      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: child.id)
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: parent.id)
    end

    test "creates an unknown group with its nested members when syncing all groups",
         %{account: account} do
      directory = entra_directory_fixture(account: account, sync_all_groups: true)
      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(groups: %{"parent" => {"Parent", [graph_group("child")]}, "child" => {"Child", [alice]}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "parent", "updated"))

      assert %Group{name: "Parent", nested_group_idp_ids: ["child"]} = Repo.get_by(Group, idp_id: "parent")
      refute Repo.get_by(Group, idp_id: "child")
      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert [_] = Repo.all_by(Membership, actor_id: identity.actor_id)
    end

    test "deletes a group Graph no longer returns",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      carol = directory_identity(ctx, "user-carol")
      membership_fixture(actor: Actor |> Repo.get_by!(id: carol.actor_id) |> Repo.preload(:account), group: group)
      stub_graph(groups: %{})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      refute Repo.get_by(Group, id: group.id)
      assert Repo.all(Membership) == []
    end

    test "resyncs the tracked parents a deleted child was nested in",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      parent =
        group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "parent",
          nested_group_idp_ids: ["child"]
        )

      carol = directory_identity(ctx, "user-carol")
      carol_actor = Actor |> Repo.get_by!(id: carol.actor_id) |> Repo.preload(:account)
      membership_fixture(actor: carol_actor, group: parent)

      stub_graph(groups: %{"parent" => {"Parent", []}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "deleted"))

      refute Repo.get_by(Membership, actor_id: carol_actor.id, group_id: parent.id)
      assert Repo.get_by!(Group, id: parent.id).nested_group_idp_ids == []
    end

    test "removes a stored parent Graph no longer returns",
         %{account: account, directory: directory, base_directory: base_directory} do
      parent =
        group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "parent",
          nested_group_idp_ids: ["child"]
        )

      stub_graph(groups: %{"child" => {"Child", []}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "updated"))

      refute Repo.get_by(Group, id: parent.id)
    end

    test "fails on unexpected Graph errors for groups",
         %{account: account, directory: directory, base_directory: base_directory} do
      group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      Req.Test.stub(APIClient, fn conn ->
        if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "token"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
        end
      end)

      error =
        assert_raise Portal.Entra.SyncError, fn ->
          perform_job(WebhookSync, group_args(directory, "group-1", "updated"))
        end

      assert error.step == :get_group
    end

    test "reconnects a policy to a group that comes back", %{account: account} do
      directory = entra_directory_fixture(account: account, sync_all_groups: true)
      base_directory = Repo.get_by!(Portal.Directory, id: directory.id)
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      resource = Portal.ResourceFixtures.resource_fixture(account: account)

      policy =
        Portal.PolicyFixtures.policy_fixture(account: account, group: group, resource: resource)

      {1, _} =
        Repo.update_all(from(p in Portal.Policy, where: p.id == ^policy.id),
          set: [group_idp_id: "group-1"]
        )

      stub_graph(groups: %{})
      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "deleted"))
      assert Repo.get_by!(Portal.Policy, account_id: account.id, id: policy.id).group_id == nil

      stub_graph(groups: %{"group-1" => {"Engineering", []}})
      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      %Group{id: new_id} = Repo.get_by!(Group, idp_id: "group-1")
      assert new_id != group.id
      assert Repo.get_by!(Portal.Policy, account_id: account.id, id: policy.id).group_id == new_id
    end

    test "writes a root's memberships in one statement however many groups nest them",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      stub_graph(
        groups: %{
          "group-1" =>
            {"Engineering",
             [graph_group("inner-a"), graph_user("user-alice", "Alice", "alice@example.com")]},
          "inner-a" =>
            {"A", [graph_group("inner-b"), graph_user("user-bob", "Bob", "bob@example.com")]},
          "inner-b" => {"B", [graph_user("user-carol", "Carol", "carol@example.com")]}
        }
      )

      queries =
        capture_queries(fn ->
          assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))
        end)

      assert Enum.count(queries, &String.contains?(&1, "membership_input")) == 1
      assert length(Repo.all_by(Membership, group_id: group.id)) == 3
    end

    test "reads each group once per notification across the changed group and its parents",
         %{account: account, directory: directory, base_directory: base_directory} do
      group_fixture(account: account, directory: base_directory, idp_id: "child")

      group_fixture(
        account: account,
        directory: base_directory,
        idp_id: "parent",
        nested_group_idp_ids: ["child"]
      )

      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(
        groups: %{"parent" => {"Parent", [graph_group("child")]}, "child" => {"Child", [alice]}},
        notify: self()
      )

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "updated"))

      assert_received {:members_read, "child"}
      refute_received {:members_read, "child"}
    end

    test "grants a user reachable through two nested groups once",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(
        groups: %{
          "group-1" => {"Engineering", [graph_group("inner-a"), graph_group("inner-b")]},
          "inner-a" => {"A", [alice]},
          "inner-b" => {"B", [alice]}
        }
      )

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert [_] = Repo.all_by(Membership, actor_id: identity.actor_id, group_id: group.id)
    end

    test "records the nesting and prunes stale members in one transaction",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      parent =
        group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "parent",
          nested_group_idp_ids: ["child"]
        )

      carol = directory_identity(ctx, "user-carol")
      carol_actor = Actor |> Repo.get_by!(id: carol.actor_id) |> Repo.preload(:account)
      membership_fixture(actor: carol_actor, group: parent)

      stub_graph(groups: %{"parent" => {"Parent", []}})

      queries =
        capture_queries(fn ->
          assert :ok = perform_job(WebhookSync, group_args(directory, "child", "deleted"))
        end)

      assert one_transaction?(
               queries,
               ~s(SET "nested_group_idp_ids"),
               ~s(DELETE FROM "memberships")
             )
    end

    test "walks nested groups, records them, and flattens their users into the group",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(
        groups: %{
          "group-1" => {"Engineering", [graph_group("inner-b"), graph_group("inner-a")]},
          "inner-a" => {"A", [alice, graph_group("group-1")]},
          "inner-b" => {"B", [graph_group("inner-a")]}
        }
      )

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      assert Repo.get_by!(Group, id: group.id).nested_group_idp_ids == ["inner-a", "inner-b"]
      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: group.id)
    end

    test "keeps walking when a nested group vanishes before its members are read",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(groups: %{"group-1" => {"Engineering", [graph_group("gone"), alice]}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "updated"))

      assert Repo.get_by!(Group, id: group.id).nested_group_idp_ids == ["gone"]
      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: group.id)
    end

    test "deletes a group on a deleted notification once Graph confirms it",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      stub_graph(groups: %{})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "deleted"))

      refute Repo.get_by(Group, id: group.id)
    end
  end

  test "snoozes while a full sync for the directory is executing", %{directory: directory} = ctx do
    identity = directory_identity(ctx, "user-1")

    executing_job(Sync.new(%{account_id: directory.account_id, directory_id: directory.id}))

    assert {:snooze, seconds} = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))
    assert seconds in 16..45
    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  test "skips accounts without directory sync" do
    account = account_fixture(features: %{idp_sync: false})
    directory = entra_directory_fixture(account: account)
    identity = directory_identity(%{account: account, directory: directory}, "user-1")

    assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  test "skips disabled directories", %{account: account} = ctx do
    directory = entra_directory_fixture(account: account, is_disabled: true)
    identity = directory_identity(%{ctx | directory: directory}, "user-1")

    assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  defp user_args(directory, id, change_type) do
    %{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: "user",
      resource_id: id,
      change_type: change_type
    }
  end

  defp group_args(directory, id, change_type) do
    %{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: "group",
      resource_id: id,
      change_type: change_type
    }
  end

  defp directory_identity(ctx, idp_id, attrs \\ []) do
    attrs
    |> Enum.into(%{})
    |> Map.merge(%{
      account: ctx.account,
      directory: Repo.get_by!(Portal.Directory, id: ctx.directory.id),
      issuer: Sync.issuer(ctx.directory),
      idp_id: idp_id
    })
    |> identity_fixture()
  end

  defp mark_created_by_directory(actor_id, directory) do
    Actor
    |> Repo.get_by!(id: actor_id)
    |> Ecto.Changeset.change(created_by_directory_id: directory.id)
    |> Repo.update!()
    |> Repo.preload(:account)
  end

  defp graph_group(id), do: %{"@odata.type" => "#microsoft.graph.group", "id" => id}

  defp graph_user(id, name, email, enabled \\ true) do
    %{
      "id" => id,
      "displayName" => name,
      "mail" => email,
      "userPrincipalName" => email,
      "givenName" => name,
      "surname" => "User",
      "accountEnabled" => enabled
    }
  end

  defp stub_graph(opts) do
    users = Keyword.get(opts, :users, %{})
    groups = Keyword.get(opts, :groups, %{})
    notify = Keyword.get(opts, :notify)

    Req.Test.stub(APIClient, fn conn ->
      path = conn.request_path

      cond do
        String.ends_with?(path, "/oauth2/v2.0/token") ->
          Req.Test.json(conn, %{"access_token" => "token"})

        match?(["v1.0", "users", _], Path.split(String.trim_leading(path, "/"))) ->
          ["v1.0", "users", id] = Path.split(String.trim_leading(path, "/"))
          json_or_404(conn, users[id])

        match?(["v1.0", "groups", _], Path.split(String.trim_leading(path, "/"))) ->
          ["v1.0", "groups", id] = Path.split(String.trim_leading(path, "/"))

          case groups[id] do
            {name, _members} -> Req.Test.json(conn, %{"id" => id, "displayName" => name})
            nil -> json_or_404(conn, nil)
          end

        String.ends_with?(path, "/members") ->
          ["v1.0", "groups", id | _] = Path.split(String.trim_leading(path, "/"))

          if notify do
            send(notify, {:members_read, id})
          end

          case Map.get(groups, id) do
            {_name, members} -> Req.Test.json(conn, %{"value" => members})
            nil -> json_or_404(conn, nil)
          end

        true ->
          Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
      end
    end)
  end

  defp json_or_404(conn, nil) do
    conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => "NotFound"}})
  end

  defp json_or_404(conn, body), do: Req.Test.json(conn, body)
end
