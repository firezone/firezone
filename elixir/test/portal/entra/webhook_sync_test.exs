defmodule Portal.Entra.WebhookSyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures

  alias Portal.Actor
  alias Portal.Entra.Sync
  alias Portal.Entra.WebhookSync
  alias Portal.ExternalIdentity
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

      state = Repo.get_by!(Portal.DirectorySync.IdentityState, directory_id: identity.directory_id, idp_id: identity.idp_id)
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

    test "removes a user Graph no longer returns", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      stub_graph(users: %{})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "updated"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "removes a deleted user without calling Graph", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1", "deleted"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "keeps an actor that still has other identities", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      other = identity_fixture(account: ctx.account, actor: actor)

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
      parent = group_fixture(account: account, directory: base_directory, idp_id: "parent")
      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(
        groups: %{"child" => {"Child", [alice]}, "parent" => {"Parent", [alice]}},
        parents: %{"child" => [%{"id" => "parent", "displayName" => "Parent"}]}
      )

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "updated"))

      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-alice")
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: child.id)
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: parent.id)
    end

    test "creates unknown groups and parents when syncing all groups", %{account: account} do
      directory = entra_directory_fixture(account: account, sync_all_groups: true)
      alice = graph_user("user-alice", "Alice", "alice@example.com")

      stub_graph(
        groups: %{"child" => {"Child", [alice]}, "parent" => {"Parent", [alice]}},
        parents: %{"child" => [%{"id" => "parent", "displayName" => "Parent"}]}
      )

      assert :ok = perform_job(WebhookSync, group_args(directory, "child", "updated"))

      assert %Group{name: "Child"} = Repo.get_by(Group, idp_id: "child")
      assert %Group{name: "Parent"} = Repo.get_by(Group, idp_id: "parent")
      assert length(Repo.all(Membership)) == 2
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

    test "deletes a group on a deleted notification without calling Graph",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1", "deleted"))

      refute Repo.get_by(Group, id: group.id)
    end
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
    parents = Keyword.get(opts, :parents, %{})

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

        String.ends_with?(path, "/transitiveMembers/microsoft.graph.user") ->
          ["v1.0", "groups", id | _] = Path.split(String.trim_leading(path, "/"))
          {_name, members} = Map.fetch!(groups, id)
          Req.Test.json(conn, %{"value" => members})

        String.ends_with?(path, "/transitiveMemberOf/microsoft.graph.group") ->
          ["v1.0", "groups", id | _] = Path.split(String.trim_leading(path, "/"))
          Req.Test.json(conn, %{"value" => Map.get(parents, id, [])})

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
