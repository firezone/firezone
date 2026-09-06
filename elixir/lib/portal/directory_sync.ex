defmodule Portal.DirectorySync do
  @moduledoc """
  One writer per directory. A full sync and the webhook jobs of a directory
  never run at the same time: a job snoozes while another job for its
  directory is executing on a live node. Every job re-reads the provider when
  it runs, so a change that arrived while another job was running is applied
  by a fresh read after that job finished, and no stale response can undo a
  newer one.

  The check is safe because Oban commits a job to `executing` before
  `perform/1` runs. If two nodes fetch two jobs for one directory, each runs
  only if the other was not executing at its own check, and both cannot be
  true. Both may snooze, which the jittered snooze resolves.

  Every job has a timeout below Oban's Lifeline rescue window, so a job that
  outlives it fails loudly instead of being run twice.
  """
  alias __MODULE__.Database

  @full_sync_timeout :timer.minutes(100)
  @webhook_timeout :timer.minutes(30)

  def full_sync_timeout, do: @full_sync_timeout
  def webhook_timeout, do: @webhook_timeout

  @doc """
  Whether another job of `workers` for the directory is executing on a node
  that is still part of the cluster. A job left executing by a node that went
  away is ignored until Lifeline re-queues it.
  """
  def running_elsewhere?(workers, directory_id, %Oban.Job{id: job_id}) do
    live_nodes = live_nodes()

    Database.executing_jobs(workers, directory_id, job_id)
    |> Enum.any?(&live?(&1, live_nodes))
  end

  @doc """
  Whether any job of `workers` for the directory is executing, and so may
  still write an object it fetched before a notification arrived. A queued job
  fetches only once it runs, after the change.
  """
  def busy?(workers, directory_id) do
    Database.executing_jobs?(workers, directory_id)
  end

  def snooze_seconds, do: 15 + :rand.uniform(30)

  defp live_nodes do
    [Oban.config().node | Enum.map(Node.list(), &to_string/1)]
  end

  defp live?([node | _], live_nodes) when is_binary(node), do: node in live_nodes
  defp live?(_attempted_by, _live_nodes), do: true

  defmodule Database do
    @moduledoc false
    import Ecto.Query
    alias Portal.Safe

    def executing_jobs(workers, directory_id, except_job_id) do
      from(j in Oban.Job,
        where: j.worker in ^worker_names(workers),
        where: j.state == "executing",
        where: j.id != ^except_job_id,
        where: fragment("?->>'directory_id' = ?", j.args, ^directory_id),
        select: j.attempted_by
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def executing_jobs?(workers, directory_id) do
      from(j in Oban.Job,
        where: j.worker in ^worker_names(workers),
        where: j.state == "executing",
        where: fragment("?->>'directory_id' = ?", j.args, ^directory_id)
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    defp worker_names(workers), do: Enum.map(workers, &inspect/1)
  end
end
