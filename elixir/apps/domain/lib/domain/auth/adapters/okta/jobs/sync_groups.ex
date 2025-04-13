defmodule Domain.Auth.Adapters.Okta.Jobs.SyncGroups do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(1),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Provider
  alias Domain.Auth.Adapters.OpenIDConnect.DirectorySync
  alias Domain.Auth.Adapters.Okta

  require Logger
  require OpenTelemetry.Tracer

  @full_sync_every_minutes 30

  @task_supervisor __MODULE__.TaskSupervisor

  @impl true
  def state(_config) do
    {:ok, pid} = Task.Supervisor.start_link(name: @task_supervisor)
    {:ok, %{task_supervisor: pid}}
  end

  @impl true
  def execute(%{task_supervisor: pid}) do
    DirectorySync.sync_groups(__MODULE__, :okta, pid)
  end

  @doc """
  Entry point for fetching Groups from Okta.

  If we haven't performed a full sync in the last 30 minutes, the job runs
  in full sync mode, upserting new/existing groups and deleting missing groups.

  Otherwise, the job runs in delta sync mode, only upserting new/existing groups.
  """
  def gather_provider_data(provider, task_supervisor_pid) do
    # 1. Determine sync mode
    sync_mode = sync_mode(provider)

    # 2. Update start time
    update_sync_started(provider, sync_mode)

    # 3. Launch task
    results =
      DirectorySync.run_async_requests(task_supervisor_pid,
        groups: fn ->
          Okta.APIClient.list_groups(provider, sync_mode)
        end
      )

    with {:ok, %{groups: groups}} <- results do

  end

  defp sync_mode(provider) do
    minutes_since_last_full_group_sync =
      DateTime.diff(
        DateTime.utc_now(),
        provider.group_full_sync_finished_at,
        :minute
      )

    if minutes_since_last_full_group_sync > @full_sync_every_minutes do
      :full
    else
      :delta
    end
  end

  defp update_sync_started(provider, :full) do
    Provider.Changeset.sync_started(provider, :group_full_sync_started_at)
    |> Repo.update!()
  end

  defp update_sync_started(provider, :delta) do
    Provider.Changeset.sync_started(provider, :group_delta_sync_started_at)
    |> Repo.update!()
  end

  # Map group attributes from Okta to Domain
  defp map_group_attrs(groups) do
    Enum.map(groups, fn group ->
      %{
        "name" => "Group:" <> group["profile"]["name"],
        "provider_identifier" => "G:" <> group["id"]
      }
    end)
  end
end
