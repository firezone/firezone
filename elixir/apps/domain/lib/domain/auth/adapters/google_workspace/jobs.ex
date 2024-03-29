defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.Auth.Adapter.DirectorySync
  alias Domain.Auth.Adapters.GoogleWorkspace
  require Logger

  @behaviour DirectorySync

  every minutes(5), :refresh_access_tokens do
    providers = Domain.Auth.all_providers_pending_token_refresh_by_adapter!(:google_workspace)
    Logger.debug("Refreshing access tokens for #{length(providers)} providers")

    Enum.each(providers, fn provider ->
      Logger.debug("Refreshing access token",
        provider_id: provider.id,
        account_id: provider.account_id
      )

      case GoogleWorkspace.refresh_access_token(provider) do
        {:ok, provider} ->
          Logger.debug("Finished refreshing access token",
            provider_id: provider.id,
            account_id: provider.account_id
          )

        {:error, reason} ->
          Logger.error("Failed refreshing access token",
            provider_id: provider.id,
            account_id: provider.account_id,
            reason: inspect(reason)
          )
      end
    end)
  end

  every minutes(3), :sync_directory do
    providers = Domain.Auth.all_providers_pending_sync_by_adapter!(:google_workspace)
    Logger.debug("Syncing #{length(providers)} Google Workspace providers")
    DirectorySync.sync_providers(__MODULE__, providers)
  end

  def gather_provider_data(provider) do
    access_token = provider.adapter_state["access_token"]

    async_results =
      DirectorySync.run_async_requests(GoogleWorkspace.TaskSupervisor,
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

  defp map_org_unit_membership_tuples(users, organization_units) do
    Enum.flat_map(users, fn user ->
      organization_unit =
        Enum.find(organization_units, fn organization_unit ->
          organization_unit["orgUnitPath"] == user["orgUnitPath"]
        end)

      if organization_unit["orgUnitId"] do
        [{"OU:" <> organization_unit["orgUnitId"], user["id"]}]
      else
        []
      end
    end)
  end
end
