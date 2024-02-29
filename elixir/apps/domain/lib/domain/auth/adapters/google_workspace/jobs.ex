defmodule Domain.Auth.Adapters.GoogleWorkspace.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.{Auth, Actors}
  alias Domain.Auth.Adapters.GoogleWorkspace
  alias Domain.Auth.Adapters.Common.SyncLogger
  require Logger

  every minutes(5), :refresh_access_tokens do
    with {:ok, providers} <-
           Domain.Auth.list_providers_pending_token_refresh_by_adapter(:google_workspace) do
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
  end

  every minutes(3), :sync_directory do
    with {:ok, providers} <- Domain.Auth.list_providers_pending_sync_by_adapter(:google_workspace) do
      Logger.debug("Syncing #{length(providers)} Google Workspace providers")

      providers
      |> Domain.Repo.preload(:account)
      |> Enum.chunk_every(5)
      |> Enum.each(fn providers ->
        Enum.map(providers, &sync_provider/1)
      end)
    end
  end

  def sync_provider(provider) do
    Logger.debug("Syncing provider",
      account_id: provider.account_id,
      provider_id: provider.id
    )

    access_token = provider.adapter_state["access_token"]

    with true <- Domain.Accounts.idp_sync_enabled?(provider.account),
         {:ok, users} <- GoogleWorkspace.APIClient.list_users(access_token),
         {:ok, organization_units} <-
           GoogleWorkspace.APIClient.list_organization_units(access_token),
         {:ok, groups} <- GoogleWorkspace.APIClient.list_groups(access_token),
         {:ok, tuples} <-
           list_membership_tuples(access_token, groups) do
      identities_attrs =
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

          if organization_unit["orgUnitId"] do
            [{"OU:" <> organization_unit["orgUnitId"], user["id"]}]
          else
            []
          end
        end) ++ tuples

      Ecto.Multi.new()
      |> Ecto.Multi.append(Auth.sync_provider_identities_multi(provider, identities_attrs))
      |> Ecto.Multi.append(Actors.sync_provider_groups_multi(provider, actor_groups_attrs))
      |> Actors.sync_provider_memberships_multi(provider, tuples)
      |> Ecto.Multi.update(:save_last_updated_at, fn _effects_so_far ->
        Auth.Provider.Changeset.sync_finished(provider)
      end)
      |> Domain.Repo.transaction(timeout: :timer.minutes(15))
      |> case do
        {:ok, effects} ->
          SyncLogger.log_effects(provider, effects)

        {:error, reason} ->
          Logger.error("Failed to sync provider",
            provider_id: provider.id,
            account_id: provider.account_id,
            reason: inspect(reason)
          )

          {:error, reason}

        {:error, step, reason, _effects_so_far} ->
          Logger.error("Failed to sync provider",
            provider_id: provider.id,
            account_id: provider.account_id,
            step: inspect(step),
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      false ->
        Auth.Provider.Changeset.sync_failed(
          provider,
          "IdP sync is not enabled in your subscription plan"
        )
        |> Domain.Repo.update!()

        :ok

      {:error, {401, %{"error" => %{"message" => message}}}} ->
        Auth.Provider.Changeset.sync_failed(provider, message)
        |> Domain.Repo.update!()

        :ok

      {:error, {status, %{"error" => %{"message" => message}}}} ->
        provider =
          Auth.Provider.Changeset.sync_failed(provider, message)
          |> Domain.Repo.update!()

        log_sync_error(provider, "Google API returned #{status}: #{message}")

      {:error, :retry_later} ->
        message = "Google API is temporarily unavailable"

        provider =
          Auth.Provider.Changeset.sync_failed(provider, message)
          |> Domain.Repo.update!()

        log_sync_error(provider, message)

      {:error, reason} ->
        Logger.error("Failed to sync provider",
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
      Logger.warning("Failed to sync provider", metadata)
    else
      Logger.info("Failed to sync provider", metadata)
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
