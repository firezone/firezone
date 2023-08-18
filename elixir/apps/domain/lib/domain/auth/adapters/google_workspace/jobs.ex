defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.Auth.Adapters.GoogleWorkspace
  require Logger

  every minutes(5), :refresh_access_tokens do
    # Enum.each(fn provider ->
    #   Logger.debug("Refreshing tokens for #{inspect(provider)}")
    #   GoogleWorkspace.refresh_access_token(provider)
    # end)

    :ok
  end

  every minutes(3), :sync_directory do
    datetime_filter = DateTime.utc_now() |> DateTime.add(-10, :minute)

    with {:ok, providers_to_sync} <-
           Domain.Auth.list_active_providers_by_adapter_and_last_synced_at(
             :google_workspace,
             {:lt, datetime_filter}
           ) do
      Logger.debug("Syncing #{length(providers_to_sync)} providers")

      providers_to_sync
      |> Enum.chunk_every(5)
      |> Enum.each(fn providers ->
        Enum.map(providers, fn provider ->
          Logger.debug("Syncing provider", provider_id: provider.id)

          access_token = provider.adapter_state[:access_token]

          with {:ok, users} <- GoogleWorkspace.APIClient.list_users(access_token),
               {:ok, organization_units} <-
                 GoogleWorkspace.APIClient.list_organization_units(access_token),
               {:ok, groups} <- GoogleWorkspace.APIClient.list_groups(access_token),
               {:ok, group_ids_by_user_id} <- list_group_ids_by_user_id(access_token, groups) do
            actors =
              Enum.map(users, fn user ->
                %{
                  "name" => user["name"]["fullName"],
                  "identities" => [%{"provider_identifier" => user["id"]}]
                }
              end)

            actor_groups =
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

            # _groups_multi = Actors.upsert_provider_groups_multi(provider, actor_groups)

            dbg({actors, actor_groups, group_ids_by_user_id})

            # insert actors
            # insert groups and memberships

            Logger.debug("Finished syncing provider", provider_id: provider.id)
          else
            {:error, reason} ->
              Logger.error("Failed syncing provider",
                provider_id: provider.id,
                reason: inspect(reason)
              )
          end
        end)
      end)
    end
  end

  defp list_group_ids_by_user_id(access_token, groups) do
    Enum.reduce_while(groups, {:ok, %{}}, fn group, {:ok, group_ids_by_user_id} ->
      case GoogleWorkspace.APIClient.list_group_members(access_token, group["id"]) do
        {:ok, members} ->
          group_ids_by_user_id =
            Enum.reduce(members, group_ids_by_user_id, fn member, group_ids_by_user_id ->
              {_current_value, group_ids_by_user_id} =
                Map.get_and_update(group_ids_by_user_id, member["id"], fn
                  nil -> {nil, [group["id"]]}
                  group_ids -> {group_ids, [group["id"]] ++ group_ids}
                end)

              group_ids_by_user_id
            end)

          {:cont, {:ok, group_ids_by_user_id}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
