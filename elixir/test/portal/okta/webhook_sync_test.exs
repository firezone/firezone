defmodule Portal.Okta.WebhookSyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.ObanFixtures
  import Portal.OktaDirectoryFixtures

  alias Portal.Actor
  alias Portal.ExternalIdentity
  alias Portal.Group
  alias Portal.Membership
  alias Portal.Okta.APIClient
  alias Portal.Okta.Sync
  alias Portal.Okta.WebhookSync

  @test_jwk JOSE.JWK.generate_key({:rsa, 1024})
  @test_private_key_jwk @test_jwk |> JOSE.JWK.to_map() |> elem(1)

  setup do
    account = account_fixture(features: %{idp_sync: true})

    directory =
      okta_directory_fixture(
        account: account,
        private_key_jwk: @test_private_key_jwk,
        kid: "test_kid"
      )

    base_directory = Repo.get_by!(Portal.Directory, id: directory.id)

    Req.Test.stub(APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    %{account: account, directory: directory, base_directory: base_directory}
  end

  describe "user events" do
    test "updates an existing identity", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name", email: "old@example.com")

      stub_okta(
        users: %{"user-1" => okta_user("user-1", "New", "Name", "new@example.com")},
        apps_for: %{"user-1" => ["app-1"]}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      identity = Repo.get_by!(ExternalIdentity, id: identity.id)
      assert identity.name == "New Name"
      assert identity.email == "new@example.com"
    end

    test "creates an identity and its memberships for a user assigned to an application",
         %{account: account, directory: directory, base_directory: base_directory} do
      tracked = group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      stub_okta(
        users: %{"user-1" => okta_user("user-1", "Alice", "Smith", "alice@example.com")},
        apps_for: %{"user-1" => ["app-1"]},
        groups_for: %{"user-1" => ["group-1", "group-untracked"]}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-1")
      assert identity.directory_id == directory.id
      assert [membership] = Repo.all_by(Membership, actor_id: identity.actor_id)
      assert membership.group_id == tracked.id
      refute Repo.get_by(Group, idp_id: "group-untracked")
    end

    test "moves a user's memberships when their groups change",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = Actor |> Repo.get_by!(id: identity.actor_id) |> Repo.preload(:account)
      old = group_fixture(account: account, directory: base_directory, idp_id: "group-old")
      new = group_fixture(account: account, directory: base_directory, idp_id: "group-new")
      membership_fixture(actor: actor, group: old)

      stub_okta(
        users: %{"user-1" => okta_user("user-1", "Alice", "Smith", "alice@example.com")},
        apps_for: %{"user-1" => ["app-1"]},
        groups_for: %{"user-1" => ["group-new"]}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      refute Repo.get_by(Membership, actor_id: actor.id, group_id: old.id)
      assert Repo.get_by(Membership, actor_id: actor.id, group_id: new.id)
    end

    test "removes a user Okta deactivated with their memberships and directory actor",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      membership_fixture(actor: actor, group: group)

      stub_okta(
        users: %{
          "user-1" => okta_user("user-1", "Gone", "User", "gone@example.com", "DEPROVISIONED")
        },
        apps_for: %{"user-1" => ["app-1"]}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
      refute Repo.get_by(Membership, actor_id: actor.id)
      refute Repo.get_by(Actor, id: actor.id)
    end

    test "removes a user Okta no longer returns", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      stub_okta(users: %{})

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "removes a user no application is assigned to", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")

      stub_okta(
        users: %{"user-1" => okta_user("user-1", "Alice", "Smith", "alice@example.com")},
        apps_for: %{"user-1" => []}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "ignores an unknown user no application is assigned to", %{directory: directory} do
      stub_okta(
        users: %{"user-1" => okta_user("user-1", "Alice", "Smith", "alice@example.com")},
        apps_for: %{"user-1" => []}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      assert Repo.all(ExternalIdentity) == []
    end

    test "skips a user without an email", %{directory: directory} do
      stub_okta(
        users: %{"user-1" => okta_user("user-1", "Alice", "Smith", nil)},
        apps_for: %{"user-1" => ["app-1"]}
      )

      assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

      assert Repo.all(ExternalIdentity) == []
    end

    test "fails on unexpected Okta errors", %{directory: directory} = ctx do
      directory_identity(ctx, "user-1")

      Req.Test.stub(APIClient, fn conn ->
        if String.ends_with?(conn.request_path, "/oauth2/v1/token") do
          Req.Test.json(conn, %{"access_token" => "token", "token_type" => "DPoP"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"errorSummary" => "boom"})
        end
      end)

      error =
        assert_raise Portal.Okta.SyncError, fn ->
          perform_job(WebhookSync, user_args(directory, "user-1"))
        end

      assert error.step == :get_user
    end
  end

  describe "group events" do
    test "renames a tracked group and resyncs its members",
         %{account: account, directory: directory, base_directory: base_directory} = ctx do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1", name: "Old")
      alice = directory_identity(ctx, "user-alice")
      carol = directory_identity(ctx, "user-carol")
      carol_actor = Actor |> Repo.get_by!(id: carol.actor_id) |> Repo.preload(:account)
      membership_fixture(actor: carol_actor, group: group)

      stub_okta(groups: %{"group-1" => {"Engineering", ["user-alice", "user-unknown"]}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1"))

      assert Repo.get_by!(Group, id: group.id).name == "Engineering"
      assert Repo.get_by(Membership, actor_id: alice.actor_id, group_id: group.id)
      refute Repo.get_by(Membership, actor_id: carol_actor.id, group_id: group.id)
      refute Repo.get_by(ExternalIdentity, idp_id: "user-unknown")
    end

    test "deletes a tracked group Okta no longer returns",
         %{account: account, directory: directory, base_directory: base_directory} do
      group = group_fixture(account: account, directory: base_directory, idp_id: "group-1")
      stub_okta(groups: %{})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1"))

      refute Repo.get_by(Group, id: group.id)
    end

    test "ignores groups the directory does not track", %{directory: directory} do
      stub_okta(groups: %{"group-1" => {"Engineering", []}})

      assert :ok = perform_job(WebhookSync, group_args(directory, "group-1"))

      assert Repo.all(Group) == []
    end
  end

  test "snoozes while a full sync for the directory is executing", %{directory: directory} = ctx do
    identity = directory_identity(ctx, "user-1")
    stub_okta(users: %{})
    executing_job(Sync.new(%{account_id: directory.account_id, directory_id: directory.id}))

    assert {:snooze, seconds} = perform_job(WebhookSync, user_args(directory, "user-1"))
    assert seconds in 16..45
    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  test "skips disabled directories", %{account: account} = ctx do
    directory =
      okta_directory_fixture(
        account: account,
        private_key_jwk: @test_private_key_jwk,
        kid: "test_kid",
        is_disabled: true
      )

    identity = directory_identity(%{ctx | directory: directory}, "user-1")
    stub_okta(users: %{})

    assert :ok = perform_job(WebhookSync, user_args(directory, "user-1"))

    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  defp user_args(directory, user_id) do
    %{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: "user",
      resource_id: user_id
    }
  end

  defp group_args(directory, group_id) do
    %{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: "group",
      resource_id: group_id
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

  defp okta_user(id, first, last, email, status \\ "ACTIVE") do
    profile = %{"firstName" => first, "lastName" => last}
    profile = if email, do: Map.put(profile, "email", email), else: profile
    %{"id" => id, "status" => status, "profile" => profile}
  end

  defp stub_okta(opts) do
    users = Keyword.get(opts, :users, %{})
    apps_for = Keyword.get(opts, :apps_for, %{})
    groups_for = Keyword.get(opts, :groups_for, %{})
    groups = Keyword.get(opts, :groups, %{})

    Req.Test.stub(APIClient, fn conn ->
      segments = conn.request_path |> String.trim_leading("/") |> Path.split()

      case segments do
        ["oauth2", "v1", "token"] ->
          Req.Test.json(conn, %{"access_token" => "token", "token_type" => "DPoP", "expires_in" => 3600})

        ["api", "v1", "apps"] ->
          [_, user_id] = Regex.run(~r/user\.id eq "([^"]+)"/, URI.decode_query(conn.query_string)["filter"])
          Req.Test.json(conn, Enum.map(Map.get(apps_for, user_id, []), &%{"id" => &1}))

        ["api", "v1", "users", user_id, "groups"] ->
          Req.Test.json(
            conn,
            Enum.map(Map.get(groups_for, user_id, []), &%{"id" => &1, "profile" => %{"name" => &1}})
          )

        ["api", "v1", "users", user_id] ->
          json_or_404(conn, users[user_id])

        ["api", "v1", "groups", group_id, "users"] ->
          case groups[group_id] do
            {_name, member_ids} ->
              Req.Test.json(conn, Enum.map(member_ids, &okta_user(&1, "Member", &1, "#{&1}@example.com")))

            nil ->
              json_or_404(conn, nil)
          end

        ["api", "v1", "groups", group_id] ->
          case groups[group_id] do
            {name, _members} -> Req.Test.json(conn, %{"id" => group_id, "profile" => %{"name" => name}})
            nil -> json_or_404(conn, nil)
          end

        _ ->
          Req.Test.json(conn, %{"error" => "unexpected: #{conn.request_path}"})
      end
    end)
  end

  defp json_or_404(conn, nil) do
    conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errorCode" => "E0000007"})
  end

  defp json_or_404(conn, body), do: Req.Test.json(conn, body)
end
