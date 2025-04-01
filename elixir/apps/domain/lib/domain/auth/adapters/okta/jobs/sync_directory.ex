defmodule Domain.Auth.Adapters.Okta.Jobs.SyncDirectory do
  use Domain.Jobs.Job,
    otp_app: :domain,
    # Database lock prevents updating more frequently than 10 minutes
    every: :timer.minutes(20),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Adapter.OpenIDConnect.DirectorySync
  alias Domain.Auth.Adapters.Okta
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
    DirectorySync.sync_providers(__MODULE__, :okta, pid)
  end

  def gather_provider_data(provider, task_supervisor_pid) do
    endpoint = provider.adapter_config["api_base_url"]
    access_token = provider.adapter_state["access_token"]

    async_results =
      DirectorySync.run_async_requests(task_supervisor_pid,
        users: fn ->
          Okta.APIClient.list_users(endpoint, access_token)
        end,
        groups: fn ->
          Okta.APIClient.list_groups(endpoint, access_token)
        end
      )

    with {:ok, %{users: users, groups: groups}} <- async_results,
         {:ok, membership_tuples} <- list_membership_tuples(endpoint, access_token, groups) do
      identities_attrs = map_identity_attrs(users)
      actor_groups_attrs = map_group_attrs(groups)
      {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}
    else
      {:error, {status, %{"errorCode" => error_code, "errorSummary" => error_summary}}} ->
        message = "#{error_code} => #{error_summary}"
        {:error, message, "Okta API returned #{status}: #{message}"}

      # TODO: Okta API client needs to be updated to pull message from header
      {:error, {401, ""}} ->
        message = "401 - Unauthorized"
        {:error, message, message}

      # TODO: Okta API client needs to be updated to pull message from header
      {:error, {403, ""}} ->
        message = "403 - Forbidden"
        {:error, message, message}

      {:error, :retry_later} ->
        message = "Okta API is temporarily unavailable"
        {:error, message, message}

      {:error, reason} ->
        {:error, nil, inspect(reason)}
    end
  end

  defp list_membership_tuples(endpoint, access_token, groups) do
    OpenTelemetry.Tracer.with_span "sync_provider.fetch_data.memberships" do
      Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, tuples} ->
        case Okta.APIClient.list_group_members(endpoint, access_token, group["id"]) do
          {:ok, members} ->
            tuples = Enum.map(members, &{"G:" <> group["id"], &1["id"]}) ++ tuples
            {:cont, {:ok, tuples}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Map identity attributes from Okta to Domain
  defp map_identity_attrs(users) do
    Enum.map(users, fn user ->
      %{
        "provider_identifier" => user["id"],
        "provider_state" => %{
          "userinfo" => %{
            "email" => user["profile"]["email"]
          }
        },
        "actor" => %{
          "type" => :account_user,
          "name" => "#{user["profile"]["firstName"]} #{user["profile"]["lastName"]}"
        }
      }
    end)
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
