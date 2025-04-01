defmodule Domain.Auth.Adapters.MicrosoftEntra.Jobs.SyncDirectory do
  use Domain.Jobs.Job,
    otp_app: :domain,
    # Database lock prevents updating more frequently than 10 minutes
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Adapter.OpenIDConnect.DirectorySync
  alias Domain.Auth.Adapters.MicrosoftEntra
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
    DirectorySync.sync_providers(__MODULE__, :microsoft_entra, pid)
  end

  def gather_provider_data(provider, task_supervisor_pid) do
    access_token = provider.adapter_state["access_token"]

    async_results =
      DirectorySync.run_async_requests(task_supervisor_pid,
        users: fn ->
          MicrosoftEntra.APIClient.list_users(access_token)
        end,
        groups: fn ->
          MicrosoftEntra.APIClient.list_groups(access_token)
        end
      )

    with {:ok, %{users: users, groups: groups}} <- async_results,
         {:ok, membership_tuples} <- list_membership_tuples(access_token, groups) do
      identities_attrs = map_identity_attrs(users)
      actor_groups_attrs = map_group_attrs(groups)
      {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}
    else
      {:error, {401, %{"error" => %{"message" => message}}}} ->
        {:error, {:unauthorized, message}}

      {:error, {status, %{"error" => %{"message" => message}}}} ->
        {:error, message, "Microsoft Graph API returned #{status}: #{message}"}

      {:error, :retry_later} ->
        message = "Microsoft Graph API is temporarily unavailable"
        {:error, message, message}

      {:error, reason} ->
        {:error, nil, inspect(reason)}
    end
  end

  defp list_membership_tuples(access_token, groups) do
    OpenTelemetry.Tracer.with_span "sync_provider.fetch_data.memberships" do
      Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, tuples} ->
        case MicrosoftEntra.APIClient.list_group_members(access_token, group["id"]) do
          {:ok, members} ->
            tuples = Enum.map(members, &{"G:" <> group["id"], &1["id"]}) ++ tuples
            {:cont, {:ok, tuples}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Map identity attributes from Microsoft Entra to Domain
  defp map_identity_attrs(users) do
    Enum.map(users, fn user ->
      %{
        "provider_identifier" => user["id"],
        "provider_state" => %{
          "userinfo" => %{
            "email" => user["userPrincipalName"]
          }
        },
        "actor" => %{
          "type" => :account_user,
          "name" => user["displayName"]
        }
      }
    end)
  end

  # Map group attributes from Microsoft Entra to Domain
  defp map_group_attrs(groups) do
    Enum.map(groups, fn group ->
      %{
        "name" => "Group:" <> group["displayName"],
        "provider_identifier" => "G:" <> group["id"]
      }
    end)
  end
end
