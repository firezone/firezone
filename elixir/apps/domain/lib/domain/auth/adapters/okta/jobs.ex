defmodule Domain.Auth.Adapters.Okta.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.{Auth, Actors}
  alias Domain.Auth.Adapters.Okta
  alias Domain.Auth.Adapters.Common.SyncLogger
  require Logger

  every minutes(5), :refresh_access_tokens do
    with {:ok, providers} <-
           Domain.Auth.list_providers_pending_token_refresh_by_adapter(:okta) do
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
  end

  every minutes(3), :sync_directory do
    with {:ok, providers} <- Domain.Auth.list_providers_pending_sync_by_adapter(:okta) do
      Logger.debug("Syncing #{length(providers)} Okta providers")

      providers
      |> Domain.Repo.preload(:account)
      |> Enum.chunk_every(5)
      |> Enum.each(fn providers ->
        Enum.map(providers, fn provider ->
          if Domain.Accounts.idp_sync_enabled?(provider.account) do
            sync_provider_directory(provider)
          else
            Auth.Provider.Changeset.sync_failed(
              provider,
              "IdP sync is not enabled in your subscription plan"
            )
            |> Domain.Repo.update!()

            :ok
          end
        end)
      end)
    end
  end

  def sync_provider_directory(provider) do
    Logger.debug("Syncing provider: #{provider.id}", provider_id: provider.id)

    endpoint = provider.adapter_config["api_base_url"]
    access_token = provider.adapter_state["access_token"]

    with {:ok, users} <- Okta.APIClient.list_users(endpoint, access_token),
         {:ok, groups} <- Okta.APIClient.list_groups(endpoint, access_token),
         {:ok, tuples} <- list_membership_tuples(endpoint, access_token, groups) do
      identities_attrs = map_identity_attrs(users)
      actor_groups_attrs = map_group_attrs(groups)

      Ecto.Multi.new()
      |> Ecto.Multi.append(Auth.sync_provider_identities_multi(provider, identities_attrs))
      |> Ecto.Multi.append(Actors.sync_provider_groups_multi(provider, actor_groups_attrs))
      |> Actors.sync_provider_memberships_multi(provider, tuples)
      |> Ecto.Multi.update(:save_last_updated_at, fn _effects_so_far ->
        Auth.Provider.Changeset.sync_finished(provider)
      end)
      |> Domain.Repo.transaction()
      |> case do
        {:ok, effects} ->
          SyncLogger.log_effects(provider, effects)

        {:error, reason} ->
          Logger.error("Failed to sync provider",
            provider_id: provider.id,
            account_id: provider.account_id,
            reason: inspect(reason)
          )

        {:error, op, value, changes_so_far} ->
          Logger.error("Failed to sync provider",
            provider_id: provider.id,
            account_id: provider.account_id,
            op: op,
            value: inspect(value),
            changes_so_far: inspect(changes_so_far)
          )
      end
    else
      {:error, {status, %{"errorCode" => error_code, "errorSummary" => error_summary}}} ->
        message = "#{error_code} => #{error_summary}"

        provider =
          Auth.Provider.Changeset.sync_failed(provider, message)
          |> Domain.Repo.update!()

        log_sync_error(provider, "Okta API returned #{status}: #{message}")

      {:error, :retry_later} ->
        message = "Okta API is temporarily unavailable"

        provider =
          Auth.Provider.Changeset.sync_failed(provider, message)
          |> Domain.Repo.update!()

        log_sync_error(provider, message)

      {:error, reason} ->
        Logger.error("Failed syncing provider",
          account_id: provider.account_id,
          provider_id: provider.id,
          reason: inspect(reason)
        )
    end
  end

  defp log_sync_error(provider, message) do
    metadata = [
      account_id: provider.account_id,
      provider_id: provider.id,
      reason: message
    ]

    if provider.last_syncs_failed >= 3 do
      Logger.warning("Failed syncing provider", metadata)
    else
      Logger.info("Failed syncing provider", metadata)
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
