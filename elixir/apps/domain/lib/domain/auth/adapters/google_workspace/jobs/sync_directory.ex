defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs.SyncDirectory do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(2),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Adapter.OpenIDConnect.DirectorySync
  alias Domain.Auth.Adapters.GoogleWorkspace
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
    DirectorySync.sync_providers(__MODULE__, :google_workspace, pid)
  end

  def gather_provider_data(provider, task_supervisor_pid) do
    access_token =
      with {:ok, access_token} <- GoogleWorkspace.fetch_service_account_token(provider) do
        access_token
      else
        {:error, :missing_service_account_key} ->
          provider.adapter_state["access_token"]

        {:error, {401, _response} = reason} ->
          Logger.warning("Failed to fetch service account token",
            account_id: provider.account_id,
            account_slug: provider.account.slug,
            provider_id: provider.id,
            provider_adapter: provider.adapter,
            reason: inspect(reason)
          )

          provider.adapter_state["access_token"]

        {:error, reason} ->
          Logger.error("Failed to fetch service account token",
            reason: inspect(reason),
            account_id: provider.account_id,
            account_slug: provider.account.slug,
            provider_id: provider.id,
            provider_adapter: provider.adapter
          )

          provider.adapter_state["access_token"]
      end

    async_results =
      DirectorySync.run_async_requests(task_supervisor_pid,
        users: fn ->
          GoogleWorkspace.APIClient.list_users(access_token)
        end,
        organization_units: fn ->
          GoogleWorkspace.APIClient.list_organization_units(access_token)
        end,
        groups: fn ->
          GoogleWorkspace.APIClient.list_groups(access_token)
        end
      )

    with {:ok, %{users: users, organization_units: organization_units, groups: groups}} <-
           async_results,
         {:ok, tuples} <- list_membership_tuples(access_token, groups) do
      identities_attrs = map_identity_attrs(users)
      actor_groups_attrs = map_group_attrs(organization_units, groups)
      membership_tuples = map_org_unit_membership_tuples(users, organization_units) ++ tuples
      {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}
    else
      {:error, {401, %{"error" => %{"message" => message}}}} ->
        {:error, {:unauthorized, message}}

      {:error, {status, %{"error" => %{"message" => message}}}} ->
        {:error, message, "Google API returned #{status}: #{message}"}

      {:error, :retry_later} ->
        message = "Google API is temporarily unavailable"
        {:error, message, message}

      {:error, reason} ->
        {:error, nil, inspect(reason)}
    end
  end

  defp list_membership_tuples(access_token, groups) do
    OpenTelemetry.Tracer.with_span "sync_provider.fetch_data.memberships" do
      Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, tuples} ->
        case GoogleWorkspace.APIClient.list_group_members(access_token, group["id"]) do
          {:ok, members} ->
            tuples = Enum.map(members, &{"G:" <> group["id"], &1["id"]}) ++ tuples
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
            "email" => user["primaryEmail"]
          }
        },
        "actor" => %{
          "type" => :account_user,
          "name" => user["name"]["fullName"]
        }
      }
    end)
  end

  defp map_group_attrs(organization_units, groups) do
    Enum.map(groups, fn group ->
      %{
        "name" => "Group:" <> group["name"],
        "provider_identifier" => "G:" <> group["id"]
      }
    end) ++
      Enum.map(organization_units, fn organization_unit ->
        %{
          "name" => "OrgUnit:" <> organization_unit["name"],
          "provider_identifier" => "OU:" <> organization_unit["orgUnitId"]
        }
      end)
  end

  defp find_parent_orgunits(organization_units, child_organization_unit) do
    parent_organization_ou =
      Enum.find(organization_units, fn organization_unit ->
        organization_unit["orgUnitId"] == child_organization_unit["parentOrgUnitId"]
      end)

    if parent_organization_ou["orgUnitId"] do
      find_parent_orgunits(organization_units, parent_organization_ou) ++ [parent_organization_ou]
    else
      []
    end
  end

  defp map_org_unit_membership_tuples(users, organization_units) do
    Enum.flat_map(users, fn user ->
      organization_unit =
        Enum.find(organization_units, fn organization_unit ->
          organization_unit["orgUnitPath"] == user["orgUnitPath"]
        end)

      if organization_unit do
        user_organization_units =
          find_parent_orgunits(organization_units, organization_unit) ++ [organization_unit]

        user_organization_units
        |> Enum.map(fn organization_unit ->
          {"OU:" <> organization_unit["orgUnitId"], user["id"]}
        end)
      else
        []
      end
    end)
  end
end
