defmodule Domain.Auth.Adapters.Okta.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.Auth.Adapter.DirectorySync
  alias Domain.Auth.Adapters.Okta
  require Logger

  @behaviour DirectorySync

  every minutes(5), :refresh_access_tokens do
    providers = Domain.Auth.all_providers_pending_token_refresh_by_adapter!(:okta)
    Logger.debug("Refreshing access tokens for #{length(providers)} Okta providers")

    Enum.each(providers, fn provider ->
      Logger.debug("Refreshing access token",
        provider_id: provider.id,
        account_id: provider.account_id
      )

      case Okta.refresh_access_token(provider) do
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
    providers = Domain.Auth.all_providers_pending_sync_by_adapter!(:okta)
    Logger.debug("Syncing #{length(providers)} Okta providers")
    DirectorySync.sync_providers(__MODULE__, providers)
  end

  def gather_provider_data(provider) do
    endpoint = provider.adapter_config["api_base_url"]
    access_token = provider.adapter_state["access_token"]

    async_results =
      DirectorySync.run_async_requests(Okta.TaskSupervisor,
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

      {:error, :retry_later} ->
        message = "Okta API is temporarily unavailable"
        {:error, message, message}

      {:error, reason} ->
        {:error, nil, inspect(reason)}
    end
  end

  defp list_membership_tuples(endpoint, access_token, groups) do
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
