defmodule Portal.DirectorySync do
  @moduledoc """
  One writer per directory. A full sync and the webhook jobs of a directory
  never run at the same time: a job snoozes while another job for its
  directory may still be writing. Every job re-reads the provider when it
  runs, so a change that arrived while another job was running is applied by
  a fresh read after that job finished, and no stale response can undo a
  newer one.

  The check is safe because Oban commits a job to `executing` before
  `perform/1` runs. If two nodes fetch two jobs for one directory, each runs
  only if the other was not executing at its own check, and both cannot be
  true. Both may snooze, which the jittered snooze resolves.

  An executing row keeps blocking until its process certainly cannot write:
  Oban kills a job at its timeout, so a row older than that plus a margin is
  dead, and a node that restarts re-queues the rows it left behind, since a
  node name cannot run twice. Leaving the cluster proves nothing, a
  disconnected node can still reach the database.
  """
  alias __MODULE__.Database

  @workers [
    Portal.Entra.Sync,
    Portal.Entra.WebhookSync,
    Portal.Google.Sync,
    Portal.Google.WebhookSync,
    Portal.Okta.Sync
  ]

  @full_sync_timeout :timer.minutes(100)
  @webhook_timeout :timer.minutes(30)
  @dead_margin :timer.minutes(5)

  def full_sync_timeout, do: @full_sync_timeout
  def webhook_timeout, do: @webhook_timeout

  @doc """
  Whether another job of `workers` for the directory is executing and young
  enough that its process may still be alive.
  """
  def running_elsewhere?(workers, directory_id, %Oban.Job{id: job_id}) do
    timeouts = Map.new(workers, &{inspect(&1), &1.timeout(nil)})
    now = DateTime.utc_now()

    Database.executing_jobs(workers, directory_id, job_id)
    |> Enum.any?(fn
      %{attempted_at: nil} ->
        true

      %{worker: worker, attempted_at: attempted_at} ->
        DateTime.diff(now, attempted_at, :millisecond) < timeouts[worker] + @dead_margin
    end)
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

  @doc """
  Re-queues the sync jobs this node left executing before it restarted, so a
  deploy does not block their directories until the rows age out.
  """
  def rescue_own_orphans do
    if Node.alive?() do
      rescue_orphans(Oban.config().node)
    else
      0
    end
  end

  def rescue_orphans(node) do
    Database.rescue_orphans(@workers, node)
  end

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
        select: %{worker: j.worker, attempted_at: j.attempted_at}
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

    def rescue_orphans(workers, node) do
      orphans =
        from(j in Oban.Job,
          where: j.worker in ^worker_names(workers),
          where: j.state == "executing",
          where: fragment("?[1] = ?", j.attempted_by, ^node)
        )

      {rescued, _} =
        orphans
        |> where([j], j.attempt < j.max_attempts)
        |> Safe.unscoped()
        |> Safe.update_all(set: [state: "available"])

      {discarded, _} =
        orphans
        |> where([j], j.attempt >= j.max_attempts)
        |> Safe.unscoped()
        |> Safe.update_all(set: [state: "discarded", discarded_at: DateTime.utc_now()])

      rescued + discarded
    end

    defp worker_names(workers), do: Enum.map(workers, &inspect/1)
  end
end
