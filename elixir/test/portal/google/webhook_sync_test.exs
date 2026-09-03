defmodule Portal.Google.WebhookSyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.GoogleAPIClientHelpers
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures

  alias Portal.Actor
  alias Portal.ExternalIdentity
  alias Portal.ExternalIdentitySyncState
  alias Portal.Google.APIClient
  alias Portal.Google.Sync
  alias Portal.Google.WebhookSync
  alias Portal.Membership

  setup do
    configure_google_api_client()
    account = account_fixture(features: %{idp_sync: true})
    directory = google_directory_fixture(account: account, orgunit_sync_enabled: false)
    base_directory = Repo.get_by!(Portal.Directory, id: directory.id)

    %{account: account, directory: directory, base_directory: base_directory}
  end

  describe "user notifications" do
    test "updates an existing identity", %{account: account, directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name", email: "old@example.com")

      stub_google(users: %{"user-1" => google_user("user-1", "New Name", "new@example.com")})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      identity = Repo.get_by!(ExternalIdentity, id: identity.id)
      assert identity.name == "New Name"
      assert identity.email == "new@example.com"
      assert identity.directory_id == directory.id
      assert identity.account_id == account.id

      state = Repo.get_by!(ExternalIdentitySyncState, external_identity_id: identity.id)
      assert DateTime.diff(DateTime.utc_now(), state.synced_at) < 5
    end

    test "an older full-sync write does not undo the webhook write",
         %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name")
      stub_google(users: %{"user-1" => google_user("user-1", "Webhook Name", "u1@example.com")})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      stale_synced_at = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Sync.Database.batch_upsert_identities(directory.account_id, directory.id, stale_synced_at, [
          %{idp_id: "user-1", email: "stale@example.com", name: "Stale Name"}
        ])

      assert Repo.get_by!(ExternalIdentity, id: identity.id).name == "Webhook Name"
    end

    test "removes a suspended user with their memberships and directory actor",
         %{directory: directory, base_directory: base_directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      group = group_fixture(account: ctx.account, directory: base_directory, idp_id: "group-1")
      membership_fixture(actor: actor, group: group)

      stub_google(
        users: %{"user-1" => google_user("user-1", "Gone", "u1@example.com", suspended: true)}
      )

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
      refute Repo.get_by(Membership, actor_id: actor.id)
      refute Repo.get_by(Actor, id: actor.id)
    end

    test "removes a user Google no longer returns", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      stub_google(users: %{})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
    end

    test "keeps an actor that still has other identities", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = mark_created_by_directory(identity.actor_id, directory)
      other = identity_fixture(account: ctx.account, actor: actor)
      stub_google(users: %{})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
      assert Repo.get_by(ExternalIdentity, id: other.id)
      assert Repo.get_by(Actor, id: actor.id)
    end

    test "removes a user who left every synced group and org unit",
         %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", member: false)
      actor = mark_created_by_directory(identity.actor_id, directory)
      stub_google(users: %{"user-1" => google_user("user-1", "Alice", "alice@example.com")})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      refute Repo.get_by(ExternalIdentity, id: identity.id)
      refute Repo.get_by(Actor, id: actor.id)
    end

    test "ignores unknown users when org unit sync is off", %{directory: directory} do
      stub_google(users: %{"user-1" => google_user("user-1", "New", "new@example.com")})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      assert Repo.all(ExternalIdentity) == []
    end

    test "skips a user without a primary email", %{directory: directory} = ctx do
      identity = directory_identity(ctx, "user-1", name: "Old Name")

      user = google_user("user-1", "Bad", "bad@example.com") |> Map.delete("primaryEmail")
      stub_google(users: %{"user-1" => user})

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      assert Repo.get_by!(ExternalIdentity, id: identity.id).name == "Old Name"
    end

    test "fails on unexpected Google errors", %{directory: directory} = ctx do
      directory_identity(ctx, "user-1")

      Req.Test.stub(APIClient, fn conn ->
        if conn.request_path == "/token" do
          Req.Test.json(conn, %{"access_token" => "token", "expires_in" => 3600})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
        end
      end)

      assert_raise Portal.Google.SyncError, fn ->
        perform_job(WebhookSync, args(directory, "user-1"))
      end
    end
  end

  describe "org unit memberships" do
    setup %{account: account} do
      directory = google_directory_fixture(account: account, orgunit_sync_enabled: true)
      base_directory = Repo.get_by!(Portal.Directory, id: directory.id)

      eng =
        org_unit_group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "ou-eng",
          name: "Engineering"
        )

      backend =
        org_unit_group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "ou-backend",
          name: "Backend"
        )

      sales =
        org_unit_group_fixture(
          account: account,
          directory: base_directory,
          idp_id: "ou-sales",
          name: "Sales"
        )

      org_units = [
        %{"orgUnitId" => "ou-eng", "orgUnitPath" => "/Engineering"},
        %{"orgUnitId" => "ou-backend", "orgUnitPath" => "/Engineering/Backend"},
        %{"orgUnitId" => "ou-sales", "orgUnitPath" => "/Sales"}
      ]

      %{
        directory: directory,
        base_directory: base_directory,
        eng: eng,
        backend: backend,
        sales: sales,
        org_units: org_units
      }
    end

    test "creates an identity for a new user in a tracked org unit",
         %{directory: directory, eng: eng, backend: backend, sales: sales, org_units: org_units} do
      user = google_user("user-1", "Alice", "alice@example.com", org_unit: "/Engineering/Backend")
      stub_google(users: %{"user-1" => user}, org_units: org_units)

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-1")
      assert identity.directory_id == directory.id
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: eng.id)
      assert Repo.get_by(Membership, actor_id: identity.actor_id, group_id: backend.id)
      refute Repo.get_by(Membership, actor_id: identity.actor_id, group_id: sales.id)
    end

    test "moves org unit memberships when a user changes org unit",
         %{directory: directory, eng: eng, sales: sales, org_units: org_units} = ctx do
      identity = directory_identity(ctx, "user-1")
      actor = Actor |> Repo.get_by!(id: identity.actor_id) |> Repo.preload(:account)
      membership_fixture(actor: actor, group: eng)

      group =
        group_fixture(account: ctx.account, directory: ctx.base_directory, idp_id: "group-1")

      membership_fixture(actor: actor, group: group)

      user = google_user("user-1", "Alice", "alice@example.com", org_unit: "/Sales")
      stub_google(users: %{"user-1" => user}, org_units: org_units)

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      refute Repo.get_by(Membership, actor_id: actor.id, group_id: eng.id)
      assert Repo.get_by(Membership, actor_id: actor.id, group_id: sales.id)
      assert Repo.get_by(Membership, actor_id: actor.id, group_id: group.id)
    end

    test "removes a user who moved out of every tracked org unit",
         %{directory: directory, eng: eng, org_units: org_units} = ctx do
      identity = directory_identity(ctx, "user-1", member: false)
      actor = mark_created_by_directory(identity.actor_id, directory)
      membership_fixture(actor: actor, group: eng)

      user = google_user("user-1", "Alice", "alice@example.com", org_unit: "/Marketing")
      stub_google(users: %{"user-1" => user}, org_units: org_units)

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      refute Repo.get_by(Membership, actor_id: actor.id)
      refute Repo.get_by(ExternalIdentity, id: identity.id)
      refute Repo.get_by(Actor, id: actor.id)
    end

    test "ignores a new user outside every tracked org unit",
         %{directory: directory, org_units: org_units} do
      user = google_user("user-1", "Alice", "alice@example.com", org_unit: "/Marketing")
      stub_google(users: %{"user-1" => user}, org_units: org_units)

      assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

      assert Repo.all(ExternalIdentity) == []
    end
  end

  test "snoozes while a full sync for the directory is running", %{directory: directory} = ctx do
    identity = directory_identity(ctx, "user-1")
    stub_google(users: %{})

    {:ok, job} =
      Oban.insert(Sync.new(%{account_id: directory.account_id, directory_id: directory.id}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

    assert {:snooze, 30} = perform_job(WebhookSync, args(directory, "user-1"))

    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  test "skips accounts without directory sync" do
    account = account_fixture(features: %{idp_sync: false})
    directory = google_directory_fixture(account: account)
    identity = directory_identity(%{account: account, directory: directory}, "user-1")
    stub_google(users: %{})

    assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  test "skips disabled directories", %{account: account} = ctx do
    directory = google_directory_fixture(account: account, is_disabled: true)
    identity = directory_identity(%{ctx | directory: directory}, "user-1")
    stub_google(users: %{})

    assert :ok = perform_job(WebhookSync, args(directory, "user-1"))

    assert Repo.get_by(ExternalIdentity, id: identity.id)
  end

  defp args(directory, user_id) do
    %{account_id: directory.account_id, directory_id: directory.id, user_id: user_id}
  end

  # Identities only exist through a synced group or org unit, so give each one
  # a group membership unless a test wants a user without any.
  defp directory_identity(ctx, idp_id, attrs \\ []) do
    {member, attrs} = Keyword.pop(attrs, :member, true)
    base_directory = Repo.get_by!(Portal.Directory, id: ctx.directory.id)

    identity =
      attrs
      |> Enum.into(%{})
      |> Map.merge(%{
        account: ctx.account,
        directory: base_directory,
        issuer: Sync.issuer(),
        idp_id: idp_id
      })
      |> identity_fixture()

    if member do
      actor = Actor |> Repo.get_by!(id: identity.actor_id) |> Repo.preload(:account)
      group = group_fixture(account: ctx.account, directory: base_directory)
      membership_fixture(actor: actor, group: group)
    end

    identity
  end

  defp mark_created_by_directory(actor_id, directory) do
    Actor
    |> Repo.get_by!(id: actor_id)
    |> Ecto.Changeset.change(created_by_directory_id: directory.id)
    |> Repo.update!()
    |> Repo.preload(:account)
  end

  defp google_user(id, name, email, opts \\ []) do
    %{
      "id" => id,
      "primaryEmail" => email,
      "name" => %{"fullName" => name, "givenName" => name, "familyName" => "User"},
      "suspended" => Keyword.get(opts, :suspended, false),
      "archived" => false,
      "orgUnitPath" => Keyword.get(opts, :org_unit, "/")
    }
  end

  defp stub_google(opts) do
    users = Keyword.get(opts, :users, %{})
    org_units = Keyword.get(opts, :org_units, [])

    Req.Test.stub(APIClient, fn conn ->
      path = conn.request_path

      cond do
        path == "/token" ->
          Req.Test.json(conn, %{"access_token" => "token", "expires_in" => 3600})

        match?(["admin", "directory", "v1", "users", _], Path.split(String.trim_leading(path, "/"))) ->
          ["admin", "directory", "v1", "users", id] = Path.split(String.trim_leading(path, "/"))
          json_or_404(conn, users[id])

        path == "/admin/directory/v1/customer/my_customer/orgunits" ->
          Req.Test.json(conn, %{"organizationUnits" => org_units})

        true ->
          Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
      end
    end)
  end

  defp json_or_404(conn, nil) do
    conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => 404}})
  end

  defp json_or_404(conn, body), do: Req.Test.json(conn, body)
end
