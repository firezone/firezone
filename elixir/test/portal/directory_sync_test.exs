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
      other = executing_sync(directory)
      mine = webhook_job(directory)

      assert DirectorySync.running_elsewhere?(@workers, directory.id, mine)
      refute DirectorySync.running_elsewhere?(@workers, directory.id, other)
    end

    test "ignores queued jobs and other directories", %{account: account, directory: directory} do
      other_directory = entra_directory_fixture(account: account)
      executing_sync(other_directory)
      Oban.insert!(sync_changeset(directory))
      mine = webhook_job(directory)

      refute DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end

    test "ignores a job left executing by a node that left the cluster", %{directory: directory} do
      executing_sync(directory, attempted_by: ["portal@gone", Ecto.UUID.generate()])
      mine = webhook_job(directory)

      refute DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end

    test "counts a job executing on this node", %{directory: directory} do
      executing_sync(directory, attempted_by: [Oban.config().node, Ecto.UUID.generate()])
      mine = webhook_job(directory)

      assert DirectorySync.running_elsewhere?(@workers, directory.id, mine)
    end
  end

  describe "busy?/2" do
    test "is true only while a job for the directory is executing", %{directory: directory} do
      refute DirectorySync.busy?(@workers, directory.id)

      Oban.insert!(sync_changeset(directory))
      refute DirectorySync.busy?(@workers, directory.id)

      executing_sync(directory)
      assert DirectorySync.busy?(@workers, directory.id)
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

  defp executing_sync(directory, opts \\ []) do
    job = Oban.insert!(sync_changeset(directory))

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "executing", attempted_by: Keyword.get(opts, :attempted_by)]
    )

    Repo.get!(Oban.Job, job.id)
  end

  defp webhook_job(directory) do
    Oban.insert!(
      Entra.WebhookSync.new(%{
        account_id: directory.account_id,
        directory_id: directory.id,
        resource: "user",
        resource_id: "user-1",
        change_type: "updated"
      })
    )
  end
end
