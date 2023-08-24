defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.{Auth, Actors}
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
               {:ok, tuples} <-
                 list_membership_tuples(access_token, groups) do
            identities_attrs =
              Enum.map(users, fn user ->
                %{
                  "provider_identifier" => user["id"],
                  "actor" => %{
                    "type" => :account_user,
                    "name" => user["name"]["fullName"]
                  }
                }
              end)

            actor_groups_attrs =
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

            tuples =
              Enum.flat_map(users, fn user ->
                organization_unit =
                  Enum.find(organization_units, fn organization_unit ->
                    organization_unit["orgUnitPath"] == user["orgUnitPath"]
                  end)

                [{"OU:" <> organization_unit["orgUnitId"], user["id"]}]
              end) ++ tuples

            Ecto.Multi.new()
            |> Ecto.Multi.append(Auth.sync_provider_identities_multi(provider, identities_attrs))
            |> Ecto.Multi.append(Actors.sync_provider_groups_multi(provider, actor_groups_attrs))
            |> Actors.sync_provider_memberships_multi(provider, tuples)
            |> Domain.Repo.transaction()

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
end
