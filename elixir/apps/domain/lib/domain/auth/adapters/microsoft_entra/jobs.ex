defmodule Domain.Auth.Adapters.MicrosoftEntra.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.Auth.Adapter.DirectorySync
  alias Domain.Auth.Adapters.MicrosoftEntra
  require Logger

  @behaviour DirectorySync

  every minutes(5), :refresh_access_tokens do
    providers = Domain.Auth.all_providers_pending_token_refresh_by_adapter!(:microsoft_entra)
    Logger.debug("Refreshing access tokens for #{length(providers)} Microsoft Entra providers")

    Enum.each(providers, fn provider ->
      Logger.debug("Refreshing access token",
        provider_id: provider.id,
        account_id: provider.account_id
      )

      case MicrosoftEntra.refresh_access_token(provider) do
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
    providers = Domain.Auth.all_providers_pending_sync_by_adapter!(:microsoft_entra)
    Logger.debug("Syncing #{length(providers)} Microsoft Entra providers")
    DirectorySync.sync_providers(__MODULE__, providers)
  end

  def gather_provider_data(provider) do
    access_token = provider.adapter_state["access_token"]

    async_results =
      DirectorySync.run_async_requests(MicrosoftEntra.TaskSupervisor,
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
