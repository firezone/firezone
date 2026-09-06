defmodule Portal.DirectorySync.RescuerTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.DirectorySync.Rescuer
  alias Portal.Entra

  test "re-queues the jobs its node left executing when it stops" do
    account = account_fixture(features: %{idp_sync: true})
    directory = entra_directory_fixture(account: account)
    node = "portal@stopping-#{System.unique_integer([:positive])}"

    killed = executing(directory, [node, "a"])
    elsewhere = executing(directory, ["portal@other", "b"])

    pid = start_supervised!({Rescuer, node: node, name: nil})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    :ok = GenServer.stop(pid)

    assert Repo.get!(Oban.Job, killed.id).state == "available"
    assert Repo.get!(Oban.Job, elsewhere.id).state == "executing"
  end

  defp executing(directory, attempted_by) do
    job =
      Oban.insert!(
        Entra.WebhookSync.new(%{
          account_id: directory.account_id,
          directory_id: directory.id,
          resource: "user",
          resource_id: Ecto.UUID.generate(),
          change_type: "updated"
        })
      )

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "executing", attempt: 1, attempted_at: DateTime.utc_now(), attempted_by: attempted_by]
    )

    Repo.get!(Oban.Job, job.id)
  end
end
