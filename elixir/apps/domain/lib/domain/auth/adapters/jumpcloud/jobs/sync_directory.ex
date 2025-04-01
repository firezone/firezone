defmodule Domain.Auth.Adapters.JumpCloud.Jobs.SyncDirectory do
  use Domain.Jobs.Job,
    otp_app: :domain,
    # Database lock prevents updating more frequently than 10 minutes
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Adapter.OpenIDConnect.DirectorySync
  alias Domain.Auth.Adapters.JumpCloud
  require Logger
  require OpenTelemetry.Tracer

  @task_supervisor __MODULE__.TaskSupervisor

  @impl true
  def state(_config) do
    {:ok, pid} = Task.Supervisor.start_link(name: @task_supervisor)
    {:ok, %{task_supervisor: pid}}
  end

  @impl true
  def execute(%{task_supervisor: pid}) do
    DirectorySync.sync_providers(__MODULE__, :jumpcloud, pid)
  end

  def gather_provider_data(provider, task_supervisor_pid) do
    with {:ok, %WorkOS.DirectorySync.Directory{} = directory} <-
           Domain.Auth.DirectorySync.WorkOS.fetch_directory(provider) do
      async_results =
        DirectorySync.run_async_requests(task_supervisor_pid,
          users: fn ->
            JumpCloud.APIClient.list_users(directory)
          end,
          groups: fn ->
            JumpCloud.APIClient.list_groups(directory)
          end
        )

      with {:ok, %{users: users, groups: groups}} <- async_results,
           membership_tuples <- membership_tuples(users) do
        identities_attrs = map_identity_attrs(users)
        actor_groups_attrs = map_group_attrs(groups)
        {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}
      else
        {:error, %WorkOS.Error{} = error} ->
          {:error, "Error connecting to WorkOS", error.message}

        {:error, reason} ->
          {:error, nil, inspect(reason)}

        _ ->
          {:error, nil, "An unknown error occurred"}
      end
    else
      {:ok, nil} ->
        {:error, nil, "No WorkOS Directory has been created"}

      {:error, %WorkOS.Error{} = error} ->
        {:error, "Error connecting to WorkOS", error.message}

      {:error, msg} ->
        {:error, msg, msg}
    end
  end

  defp membership_tuples(users) do
    Enum.flat_map(users, fn user ->
      Enum.map(user.groups, &{"G:" <> &1.id, user.idp_id})
    end)
  end

  # Map identity attributes from JumpCloud to Domain
  defp map_identity_attrs(users) do
    Enum.map(users, fn user ->
      %{
        "provider_identifier" => user.idp_id,
        "provider_state" => %{
          "userinfo" => %{
            "email" => user.username
          }
        },
        "actor" => %{
          "type" => :account_user,
          "name" => "#{user.first_name} #{user.last_name}"
        }
      }
    end)
  end

  # Map group attributes from WorkOS to Domain
  defp map_group_attrs(groups) do
    Enum.map(groups, fn group ->
      %{
        "name" => "Group:" <> group.name,
        "provider_identifier" => "G:" <> group.id
      }
    end)
  end
end
