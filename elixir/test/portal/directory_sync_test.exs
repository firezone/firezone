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

  test "snooze_seconds/0 spreads competing jobs apart" do
    seconds = for _ <- 1..50, do: DirectorySync.snooze_seconds()
    assert Enum.all?(seconds, &(&1 in 16..45))
  end

  test "timeouts stay under Lifeline's rescue window" do
    assert DirectorySync.full_sync_timeout() < :timer.minutes(120)
    assert DirectorySync.webhook_timeout() < DirectorySync.full_sync_timeout()
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
