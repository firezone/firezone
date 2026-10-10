defmodule Portal.DirectorySyncTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ObanFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.Actor
  alias Portal.DirectorySync
  alias Portal.Entra
  alias Portal.ExternalIdentity

  @identity_fields ~w[idp_id email name given_name family_name preferred_username]a
  @issuer "https://issuer.example.com"

  setup do
    account = account_fixture(features: %{idp_sync: true})
    directory = entra_directory_fixture(account: account)
    %{account: account, directory: directory}
  end

  describe "running_elsewhere?/3" do
    test "sees another executing job for the directory", %{directory: directory} do
      other = executing_job(sync_changeset(directory))
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(:entra, directory.id, mine)
      refute DirectorySync.running_elsewhere?(:entra, directory.id, other)
    end

    test "ignores queued jobs and other directories", %{account: account, directory: directory} do
      other_directory = entra_directory_fixture(account: account)
      executing_job(sync_changeset(other_directory))
      Oban.insert!(sync_changeset(directory))
      mine = Oban.insert!(webhook_changeset(directory))

      refute DirectorySync.running_elsewhere?(:entra, directory.id, mine)
    end

    test "ignores a row older than its worker's timeout", %{directory: directory} do
      dead_at = DateTime.add(DateTime.utc_now(), -(DirectorySync.webhook_timeout() + 360_000), :millisecond)
      executing_job(webhook_changeset(directory), attempted_at: dead_at)
      mine = Oban.insert!(sync_changeset(directory))

      refute DirectorySync.running_elsewhere?(:entra, directory.id, mine)
    end

    test "still blocks on a full sync older than the webhook timeout", %{directory: directory} do
      attempted_at = DateTime.add(DateTime.utc_now(), -(DirectorySync.webhook_timeout() + 360_000), :millisecond)
      executing_job(sync_changeset(directory), attempted_at: attempted_at)
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(:entra, directory.id, mine)
    end

    test "ignores executing jobs of other workers for the directory", %{directory: directory} do
      executing_job(subscriptions_changeset(directory))
      mine = Oban.insert!(webhook_changeset(directory))

      refute DirectorySync.running_elsewhere?(:entra, directory.id, mine)
    end

    test "treats an executing row without attempted_at as alive", %{directory: directory} do
      executing_job(sync_changeset(directory), attempted_at: nil)
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(:entra, directory.id, mine)
    end

    test "keeps blocking on a job whose node left the cluster", %{directory: directory} do
      executing_job(sync_changeset(directory), attempted_by: ["portal@gone", Ecto.UUID.generate()])
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(:entra, directory.id, mine)
    end
  end

  describe "busy?/2" do
    test "is true only while a job for the directory is executing", %{directory: directory} do
      refute DirectorySync.busy?(:entra, directory.id)

      Oban.insert!(sync_changeset(directory))
      refute DirectorySync.busy?(:entra, directory.id)

      executing_job(sync_changeset(directory))
      assert DirectorySync.busy?(:entra, directory.id)
    end

    test "ignores executing jobs of other workers", %{directory: directory} do
      executing_job(subscriptions_changeset(directory))

      refute DirectorySync.busy?(:entra, directory.id)
    end
  end

  describe "rescue_orphans/1" do
    test "re-queues this node's executing jobs and discards spent ones", %{directory: directory} do
      node = "portal@restarted"
      retryable = executing_job(webhook_changeset(directory), attempted_by: [node, "a"])
      spent = executing_job(sync_changeset(directory), attempted_by: [node, "b"])
      elsewhere = executing_job(webhook_changeset(directory), attempted_by: ["portal@other", "c"])

      assert DirectorySync.rescue_orphans(node) == 2

      assert Repo.get!(Oban.Job, retryable.id).state == "available"
      assert Repo.get!(Oban.Job, spent.id).state == "discarded"
      assert Repo.get!(Oban.Job, elsewhere.id).state == "executing"
    end

    test "leaves the jobs of other workers alone", %{directory: directory} do
      node = "portal@restarted"
      other = executing_job(subscriptions_changeset(directory), attempted_by: [node, "d"])

      assert DirectorySync.rescue_orphans(node) == 0
      assert Repo.get!(Oban.Job, other.id).state == "executing"
    end

    test "matches the node Oban stamps on a job it fetches", %{directory: directory} do
      job = Oban.insert!(webhook_changeset(directory))
      conf = Oban.config()
      {:ok, meta} = Oban.Engine.init(conf, queue: "entra_webhook", limit: 1)
      {:ok, {_meta, [%Oban.Job{id: fetched_id}]}} = Oban.Engine.fetch_jobs(conf, meta, %{})

      assert fetched_id == job.id
      assert Repo.get!(Oban.Job, job.id).state == "executing"
      assert DirectorySync.rescue_orphans(Oban.Config.node_name()) == 1
      assert Repo.get!(Oban.Job, job.id).state == "available"
    end
  end

  describe "upsert_identities/6" do
    test "updates the name and email of an actor the directory created when its identity changes",
         %{account: account, directory: directory} do
      upsert(account, directory, [%{idp_id: "user-1", email: "old@example.com", name: "Old Name"}], -60)
      actor = Repo.get_by!(Actor, account_id: account.id, email: "old@example.com")
      assert actor.created_by_directory_id == directory.id

      upsert(account, directory, [%{idp_id: "user-1", email: "new@example.com", name: "New Name"}], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.name == "New Name"
      assert actor.email == "new@example.com"
    end

    test "repairs an actor that fell behind its identity",
         %{account: account, directory: directory} do
      upsert(account, directory, [%{idp_id: "user-1", email: "old@example.com", name: "Old Name"}], -120)
      actor = Repo.get_by!(Actor, account_id: account.id, email: "old@example.com")

      Repo.update_all(
        from(i in ExternalIdentity, where: i.account_id == ^account.id and i.idp_id == "user-1"),
        set: [email: "new@example.com", name: "New Name"]
      )

      upsert(account, directory, [%{idp_id: "user-1", email: "new@example.com", name: "New Name"}], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.name == "New Name"
      assert actor.email == "new@example.com"
    end

    test "never moves an actor back to what an older sync saw",
         %{account: account, directory: directory} do
      upsert(account, directory, [%{idp_id: "user-1", email: "old@example.com", name: "Old Name"}], -120)
      actor = Repo.get_by!(Actor, account_id: account.id, email: "old@example.com")
      upsert(account, directory, [%{idp_id: "user-1", email: "new@example.com", name: "New Name"}], 0)

      upsert(account, directory, [%{idp_id: "user-1", email: "old@example.com", name: "Old Name"}], -60)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.name == "New Name"
      assert actor.email == "new@example.com"
    end

    test "leaves an actor the directory did not create alone",
         %{account: account, directory: directory} do
      actor =
        Portal.ActorFixtures.actor_fixture(
          account: account,
          name: "Admin Name",
          email: "admin@example.com"
        )

      upsert(account, directory, [%{idp_id: "user-1", email: "admin@example.com", name: "IdP Name"}], -60)
      assert Repo.get_by!(ExternalIdentity, idp_id: "user-1").actor_id == actor.id

      upsert(account, directory, [%{idp_id: "user-1", email: "renamed@example.com", name: "Renamed"}], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.name == "Admin Name"
      assert actor.email == "admin@example.com"
    end

    test "keeps the actor's email when another actor already has the new one",
         %{account: account, directory: directory} do
      Portal.ActorFixtures.actor_fixture(account: account, email: "taken@example.com")
      upsert(account, directory, [%{idp_id: "user-1", email: "old@example.com", name: "Old Name"}], -60)
      actor = Repo.get_by!(Actor, account_id: account.id, email: "old@example.com")

      upsert(account, directory, [%{idp_id: "user-1", email: "taken@example.com", name: "New Name"}], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.name == "New Name"
      assert actor.email == "old@example.com"
    end
  end

  describe "upsert_identities/6 with inactive users" do
    test "disables an actor the directory created and keeps its identity",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -60)
      actor = actor_for("user-1")

      upsert(account, directory, [user("user-1", disabled: true)], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == directory.id

      synced_at = DateTime.add(DateTime.utc_now(), -30, :second)
      :ok = DirectorySync.prune(account.id, directory.id, synced_at)

      assert Repo.get_by!(ExternalIdentity, idp_id: "user-1").actor_id == actor.id
      assert Repo.get_by(Actor, id: actor.id)
    end

    test "re-enables the same actor when the user is active again",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -120)
      actor = actor_for("user-1")
      upsert(account, directory, [user("user-1", disabled: true)], -60)

      upsert(account, directory, [user("user-1")], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      refute actor.is_disabled
      assert actor.disabled_by_directory_id == nil
    end

    test "never re-enables an actor an admin disabled",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -60)
      actor = actor_for("user-1")
      Repo.update_all(from(a in Actor, where: a.id == ^actor.id), set: [is_disabled: true])

      upsert(account, directory, [user("user-1")], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == nil
    end

    test "leaves an admin's disable as the admin's when the user turns inactive",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -120)
      actor = actor_for("user-1")
      Repo.update_all(from(a in Actor, where: a.id == ^actor.id), set: [is_disabled: true])

      upsert(account, directory, [user("user-1", disabled: true)], -60)
      upsert(account, directory, [user("user-1")], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == nil
    end

    test "disables again an actor an admin re-enabled while the user is still inactive",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -120)
      actor = actor_for("user-1")
      upsert(account, directory, [user("user-1", disabled: true)], -60)

      {:ok, _} =
        Repo.get_by!(Actor, id: actor.id)
        |> Ecto.Changeset.change(is_disabled: false)
        |> Actor.changeset()
        |> Repo.update()

      upsert(account, directory, [user("user-1", disabled: true)], 0)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == directory.id
    end

    test "never creates an actor for a user it first sees inactive",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1", disabled: true)], 0)

      refute Repo.get_by(ExternalIdentity, idp_id: "user-1")
      refute Repo.get_by(Actor, account_id: account.id, email: "user-1@example.com")
    end

    test "never links an inactive user to an existing actor by email",
         %{account: account, directory: directory} do
      actor = Portal.ActorFixtures.actor_fixture(account: account, email: "user-1@example.com")

      upsert(account, directory, [user("user-1", disabled: true)], 0)

      refute Repo.get_by(ExternalIdentity, idp_id: "user-1")
      refute Repo.get_by!(Actor, id: actor.id).is_disabled
    end

    test "leaves an inactive user's identity for the prune when the directory did not create the actor",
         %{account: account, directory: directory} do
      actor = Portal.ActorFixtures.actor_fixture(account: account, email: "user-1@example.com")
      upsert(account, directory, [user("user-1")], -60)
      assert actor_for("user-1").id == actor.id

      upsert(account, directory, [user("user-1", disabled: true)], 0)
      refute Repo.get_by!(Actor, id: actor.id).is_disabled

      synced_at = DateTime.add(DateTime.utc_now(), -30, :second)
      :ok = DirectorySync.prune(account.id, directory.id, synced_at)

      refute Repo.get_by(ExternalIdentity, idp_id: "user-1")
      assert Repo.get_by!(Actor, id: actor.id)
    end

    test "never undoes a newer enable with an older disable",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -120)
      actor = actor_for("user-1")
      upsert(account, directory, [user("user-1")], 0)

      upsert(account, directory, [user("user-1", disabled: true)], -60)

      refute Repo.get_by!(Actor, id: actor.id).is_disabled
    end

    test "keeps the last enabled admin of the account enabled",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -60)
      actor = promote(actor_for("user-1"))

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          upsert(account, directory, [user("user-1", disabled: true)], 0)
        end)

      assert {:ok, %{kept_admin_ids: [actor_id]}} = result
      assert actor_id == actor.id

      actor = Repo.get_by!(Actor, id: actor.id)
      refute actor.is_disabled
      assert actor.disabled_by_directory_id == nil
      assert log =~ "Kept the last enabled admin enabled"
    end

    test "keeps every admin of a batch enabled when no other enabled admin remains",
         %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1"), user("user-2")], -60)
      first = promote(actor_for("user-1"))
      second = promote(actor_for("user-2"))

      {:ok, %{kept_admin_ids: kept_admin_ids}} =
        upsert(account, directory, [user("user-1", disabled: true), user("user-2", disabled: true)], 0)

      assert Enum.sort(kept_admin_ids) == Enum.sort([first.id, second.id])
      refute Repo.get_by!(Actor, id: first.id).is_disabled
      refute Repo.get_by!(Actor, id: second.id).is_disabled
    end

    test "disables an admin while another enabled admin remains",
         %{account: account, directory: directory} do
      Portal.ActorFixtures.admin_actor_fixture(account: account)
      upsert(account, directory, [user("user-1")], -60)
      actor = promote(actor_for("user-1"))

      assert {:ok, %{kept_admin_ids: []}} = upsert(account, directory, [user("user-1", disabled: true)], 0)

      assert Repo.get_by!(Actor, id: actor.id).is_disabled
    end
  end

  describe "upsert_identities/6 last-admin lock" do
    setup %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -60)

      # A connection outside the sandbox, so its lock is another session's.
      # It is linked to the test, which closes it and so drops the lock.
      {:ok, conn} =
        Repo.config()
        |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: 1)
        |> Postgrex.start_link()

      key = DirectorySync.last_admin_lock_key(account.id)
      Postgrex.query!(conn, "SELECT pg_advisory_lock($1)", [key])

      %{conn: conn, key: key}
    end

    test "waits for the lock before writing inactive users",
         %{account: account, directory: directory, conn: conn, key: key} do
      task = Task.async(fn -> upsert(account, directory, [user("user-1", disabled: true)], 0) end)
      refute Task.yield(task, 200)

      Postgrex.query!(conn, "SELECT pg_advisory_unlock($1)", [key])

      assert {:ok, _} = Task.await(task)
      assert actor_for("user-1").is_disabled
    end

    test "does not take the lock for a batch of active users",
         %{account: account, directory: directory} do
      task = Task.async(fn -> upsert(account, directory, [user("user-1"), user("user-2")], 0) end)

      assert {:ok, {:ok, %{upserted_identities: 2}}} = Task.yield(task, 1_000)
    end
  end

  describe "removing the identity of an actor the directory disabled" do
    setup %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -120)
      actor = actor_for("user-1")

      Portal.IdentityFixtures.identity_fixture(
        account: account,
        actor: actor,
        issuer: "https://other.example.com"
      )

      upsert(account, directory, [user("user-1", disabled: true)], -60)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.disabled_by_directory_id == directory.id

      %{actor: actor}
    end

    test "remove_identity/2 keeps the actor disabled as an admin's disable",
         %{actor: actor, directory: directory} do
      identity = Repo.get_by!(ExternalIdentity, idp_id: "user-1")

      assert {:ok, :removed} = DirectorySync.remove_identity(directory.id, identity)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == nil
    end

    test "prune/3 keeps the actor disabled as an admin's disable",
         %{account: account, actor: actor, directory: directory} do
      :ok = DirectorySync.prune(account.id, directory.id, DateTime.utc_now())

      refute Repo.get_by(ExternalIdentity, idp_id: "user-1")
      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == nil
    end

    test "leaves the directory's disable while it still holds an identity",
         %{account: account, actor: actor, directory: directory} do
      synced_at = DateTime.add(DateTime.utc_now(), -90, :second)
      :ok = DirectorySync.prune(account.id, directory.id, synced_at)

      assert Repo.get_by!(Actor, id: actor.id).disabled_by_directory_id == directory.id
    end
  end

  describe "deleting a directory" do
    test "deletes the actors it disabled", %{account: account, directory: directory} do
      upsert(account, directory, [user("user-1")], -60)
      actor = actor_for("user-1")
      upsert(account, directory, [user("user-1", disabled: true)], 0)

      delete_directory(directory)

      refute Repo.get_by(Actor, id: actor.id)
    end

    test "leaves any other actor it disabled one an admin can enable",
         %{account: account, directory: directory} do
      actor = Portal.ActorFixtures.actor_fixture(account: account)

      Repo.update_all(from(a in Actor, where: a.id == ^actor.id),
        set: [is_disabled: true, disabled_by_directory_id: directory.id]
      )

      delete_directory(directory)

      actor = Repo.get_by!(Actor, id: actor.id)
      assert actor.is_disabled
      assert actor.disabled_by_directory_id == nil

      {:ok, actor} = actor |> Ecto.Changeset.change(is_disabled: false) |> Actor.changeset() |> Repo.update()
      refute actor.is_disabled
    end
  end

  describe "owned_idp_ids/4" do
    test "names only those whose actor the directory created",
         %{account: account, directory: directory} do
      Portal.ActorFixtures.actor_fixture(account: account, email: "user-2@example.com")
      upsert(account, directory, [user("user-1"), user("user-2"), user("user-3")], 0)

      assert DirectorySync.owned_idp_ids(account.id, @issuer, directory.id, ["user-1", "user-2", "unknown"]) ==
               MapSet.new(["user-1"])

      assert DirectorySync.owned_idp_ids(account.id, "https://other.example.com", directory.id, ["user-1"]) ==
               MapSet.new()

      assert DirectorySync.owned_idp_ids(account.id, @issuer, directory.id, []) == MapSet.new()
    end
  end

  test "snooze_seconds/0 spreads competing jobs apart" do
    seconds = for _ <- 1..50, do: DirectorySync.snooze_seconds()
    assert Enum.all?(seconds, &(&1 in 16..45))
  end

  test "timeouts stay under Lifeline's rescue window" do
    assert DirectorySync.full_sync_timeout() < :timer.minutes(120)
    assert DirectorySync.webhook_timeout() < DirectorySync.full_sync_timeout()
  end

  defp user(idp_id, opts \\ []) do
    %{
      idp_id: idp_id,
      email: "#{idp_id}@example.com",
      name: "User #{idp_id}",
      disabled: Keyword.get(opts, :disabled, false)
    }
  end

  defp actor_for(idp_id) do
    identity = Repo.get_by!(ExternalIdentity, idp_id: idp_id)
    Repo.get_by!(Actor, id: identity.actor_id)
  end

  defp delete_directory(directory) do
    {1, _} = Repo.delete_all(from(d in Portal.Directory, where: d.id == ^directory.id))
  end

  defp promote(actor) do
    Repo.update_all(from(a in Actor, where: a.id == ^actor.id), set: [type: :account_admin_user])
    Repo.get_by!(Actor, id: actor.id)
  end

  defp upsert(account, directory, identities, seconds_from_now) do
    synced_at = DateTime.add(DateTime.utc_now(), seconds_from_now, :second)

    {:ok, _} =
      DirectorySync.upsert_identities(
        account.id,
        @issuer,
        directory.id,
        synced_at,
        identities,
        @identity_fields
      )
  end

  defp sync_changeset(directory) do
    Entra.Sync.new(%{account_id: directory.account_id, directory_id: directory.id})
  end

  defp webhook_changeset(directory) do
    Entra.WebhookSync.new(%{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: "user",
      resource_id: Ecto.UUID.generate(),
      change_type: "updated"
    })
  end

  defp subscriptions_changeset(directory) do
    Entra.Subscriptions.new(%{
      account_id: directory.account_id,
      directory_id: directory.id,
      action: "ensure"
    })
  end
end
