defmodule Portal.DirectorySync.RescuerTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.DirectorySync.Rescuer
  alias Portal.Entra

  setup do
    account = account_fixture(features: %{idp_sync: true})
    directory = entra_directory_fixture(account: account)
    node = "portal@stopping-#{System.unique_integer([:positive])}"

    %{
      directory: directory,
      node: node,
      killed: executing(directory, [node, "a"]),
      elsewhere: executing(directory, ["portal@other", "b"])
    }
  end

  test "re-queues its node's jobs on a shutdown after Oban stopped", ctx do
    pid = start_rescuer(node: ctx.node, oban: :"oban-not-running")
    :ok = GenServer.stop(pid, :shutdown)

    assert Repo.get!(Oban.Job, ctx.killed.id).state == "available"
    assert Repo.get!(Oban.Job, ctx.elsewhere.id).state == "executing"
  end

  test "rescues the jobs stamped with this node's Oban name by default", ctx do
    mine = executing(ctx.directory, [Oban.Config.node_name(), "c"])
    pid = start_rescuer(oban: :"oban-not-running")
    :ok = GenServer.stop(pid, :shutdown)

    assert Repo.get!(Oban.Job, mine.id).state == "available"
    assert Repo.get!(Oban.Job, ctx.killed.id).state == "executing"
  end

  test "leaves jobs alone while Oban still runs", ctx do
    Process.register(self(), :"oban-running-#{System.unique_integer([:positive])}")
    [name] = for {name, pid} <- Process.registered() |> Enum.map(&{&1, Process.whereis(&1)}), pid == self(), do: name

    pid = start_rescuer(node: ctx.node, oban: name)
    :ok = GenServer.stop(pid, :shutdown)

    assert Repo.get!(Oban.Job, ctx.killed.id).state == "executing"
  end

  test "leaves jobs alone when it stops for any other reason", ctx do
    pid = start_rescuer(node: ctx.node, oban: :"oban-not-running")
    :ok = GenServer.stop(pid, :normal)

    assert Repo.get!(Oban.Job, ctx.killed.id).state == "executing"
  end

  defp start_rescuer(opts) do
    pid = start_supervised!({Rescuer, [name: nil] ++ opts})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
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
      set: [
        state: "executing",
        attempt: 1,
        attempted_at: DateTime.utc_now(),
        attempted_by: attempted_by
      ]
    )

    Repo.get!(Oban.Job, job.id)
  end
end
