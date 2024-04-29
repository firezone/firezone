defmodule Domain.Auth.Adapters.JumpCloud.Jobs.SyncDirectory do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(2),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Adapter.DirectorySync
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
    api_key = provider.adapter_config["api_key"]

    async_results =
      DirectorySync.run_async_requests(task_supervisor_pid,
        users: fn ->
          JumpCloud.APIClient.list_users(api_key)
        end,
        groups: fn ->
          JumpCloud.APIClient.list_groups(api_key)
        end
      )

    with {:ok, %{users: users, groups: groups}} <- async_results,
         {:ok, membership_tuples} <- list_membership_tuples(api_key, groups, users) do
      identities_attrs = map_identity_attrs(users)
      actor_groups_attrs = map_group_attrs(groups)
      {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}
    else
      {:error, {401, %{"error" => _error, "message" => message}}} ->
        {:error, {:unauthorized, message}}

      {:error, {status, %{"error" => %{"message" => message}}}} ->
        {:error, message, "JumpCloud API returned #{status}: #{message}"}

      {:error, :retry_later} ->
        message = "JumpCloud API is temporarily unavailable"
        {:error, message, message}

      {:error, reason} ->
        {:error, nil, inspect(reason)}
    end
  end

  defp list_membership_tuples(api_key, groups, users) do
    user_ids = MapSet.new(users, & &1["id"])

    OpenTelemetry.Tracer.with_span "sync_provider.fetch_data.memberships" do
      Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, tuples} ->
        case JumpCloud.APIClient.list_group_members(api_key, group["id"], user_ids) do
          {:ok, members} ->
            tuples =
              (members
               |> Enum.filter(&MapSet.member?(user_ids, &1))
               |> Enum.map(&{"G:" <> group["id"], &1})) ++ tuples

            {:cont, {:ok, tuples}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp map_identity_attrs(users) do
    Enum.map(users, fn user ->
      %{
        "provider_identifier" => user["id"],
        "provider_state" => %{
          "userinfo" => %{
            "email" => user["email"]
          }
        },
        "actor" => %{
          "type" => :account_user,
          "name" => "#{user["firstname"]} #{user["lastname"]}"
        }
      }
    end)
  end

  defp map_group_attrs(groups) do
    Enum.map(groups, fn group ->
      %{
        "name" => "Group:" <> group["name"],
        "provider_identifier" => "G:" <> group["id"]
      }
    end)
  end
end
