defmodule Portal.DirectorySyncTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.DirectorySync
  alias Portal.Entra

  @workers [Entra.Sync, Entra.WebhookSync]

  setup do
    account = account_fixture(features: %{idp_sync: true})
    directory = entra_directory_fixture(account: account)
    %{account: account, directory: directory}
  end

  describe "running_elsewhere?/3" do
    test "sees another executing job for the directory", %{directory: directory} do
      other = executing(sync_changeset(directory))
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(@workers, directory.id, mine)
      refute DirectorySync.running_elsewhere?(@workers, directory.id, other)
    end

    test "ignores queued jobs and other directories", %{account: account, directory: directory} do
      other_directory = entra_directory_fixture(account: account)
      executing(sync_changeset(other_directory))
      Oban.insert!(sync_changeset(directory))
      mine = Oban.insert!(webhook_changeset(directory))

      refute DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end

    test "ignores a row older than its worker's timeout", %{directory: directory} do
      dead_at = DateTime.add(DateTime.utc_now(), -(DirectorySync.webhook_timeout() + 360_000), :millisecond)
      executing(webhook_changeset(directory), attempted_at: dead_at)
      mine = Oban.insert!(sync_changeset(directory))

      refute DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end

    test "still blocks on a full sync older than the webhook timeout", %{directory: directory} do
      attempted_at = DateTime.add(DateTime.utc_now(), -(DirectorySync.webhook_timeout() + 360_000), :millisecond)
      executing(sync_changeset(directory), attempted_at: attempted_at)
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end

    test "keeps blocking on a job whose node left the cluster", %{directory: directory} do
      executing(sync_changeset(directory), attempted_by: ["portal@gone", Ecto.UUID.generate()])
      mine = Oban.insert!(webhook_changeset(directory))

      assert DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end
  end

  describe "busy?/2" do
    test "is true only while a job for the directory is executing", %{directory: directory} do
      refute DirectorySync.busy?(@workers, directory.id)

      Oban.insert!(sync_changeset(directory))
      refute DirectorySync.busy?(@workers, directory.id)

      executing(sync_changeset(directory))
      assert DirectorySync.busy?(@workers, directory.id)
    end
  end

  describe "rescue_orphans/1" do
    test "re-queues this node's executing jobs and discards spent ones", %{directory: directory} do
      node = "portal@restarted"
      retryable = executing(webhook_changeset(directory), attempted_by: [node, "a"])
      spent = executing(sync_changeset(directory), attempted_by: [node, "b"])
      elsewhere = executing(webhook_changeset(directory), attempted_by: ["portal@other", "c"])

      assert DirectorySync.rescue_orphans(node) == 2

      assert Repo.get!(Oban.Job, retryable.id).state == "available"
      assert Repo.get!(Oban.Job, spent.id).state == "discarded"
      assert Repo.get!(Oban.Job, elsewhere.id).state == "executing"
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

  test "snooze_seconds/0 spreads competing jobs apart" do
    seconds = for _ <- 1..50, do: DirectorySync.snooze_seconds()
    assert Enum.all?(seconds, &(&1 in 16..45))
  end

  test "timeouts stay under Lifeline's rescue window" do
    assert DirectorySync.full_sync_timeout() < :timer.minutes(120)
    assert DirectorySync.webhook_timeout() < DirectorySync.full_sync_timeout()
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

  defp executing(changeset, opts \\ []) do
    job = Oban.insert!(changeset)

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [
        state: "executing",
        attempt: 1,
        attempted_at: Keyword.get(opts, :attempted_at, DateTime.utc_now()),
        attempted_by: Keyword.get(opts, :attempted_by, ["portal@here", "uuid"])
      ]
    )

    Repo.get!(Oban.Job, job.id)
  end
end
