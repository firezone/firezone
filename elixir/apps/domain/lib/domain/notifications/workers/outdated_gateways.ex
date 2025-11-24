defmodule Domain.Notifications.Workers.OutdatedGateways do
  @moduledoc """
  Oban worker that checks for outdated gateways and sends notifications.
  Scheduled via cron: every minute in dev, Sundays at 9am in prod.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 86400]

  require Logger
  require OpenTelemetry.Tracer

  alias Domain.{Actors, Accounts, Clients, Gateways, Mailer}

  @impl Oban.Worker
  def perform(_job) do
    run_check()
    :ok
  end

  defp run_check do
    latest_version = Domain.ComponentVersions.gateway_version()

    Accounts.all_accounts_pending_notification!()
    |> Enum.each(fn account ->
      incompatible_client_count = Clients.count_incompatible_for(account, latest_version)

      all_online_gateways_for_account(account)
      |> Enum.filter(&Gateways.gateway_outdated?/1)
      |> send_notifications(account, incompatible_client_count)
    end)
  end

  defp all_online_gateways_for_account(account) do
    gateways_by_id =
      Gateways.all_gateways_for_account!(account)
      |> Enum.group_by(& &1.id)

    Gateways.all_groups_for_account!(account)
    |> Enum.flat_map(&Gateways.all_online_gateway_ids_by_group_id!(&1.id))
    |> Enum.flat_map(&Map.get(gateways_by_id, &1))
  end

  defp send_notifications([], _account, _incompatible_client_count) do
    Logger.debug("No outdated gateways for account")
  end

  defp send_notifications(gateways, account, incompatible_client_count) do
    Actors.all_admins_for_account!(account)
    |> Enum.each(&send_email(account, gateways, incompatible_client_count, &1.email))

    Accounts.update_account(account, %{
      config: %{
        notifications: %{
          outdated_gateway: %{
            last_notified: DateTime.utc_now()
          }
        }
      }
    })
  end

  defp send_email(account, gateways, incompatible_client_count, email) do
    Mailer.Notifications.outdated_gateway_email(
      account,
      gateways,
      incompatible_client_count,
      email
    )
    |> Mailer.deliver_with_rate_limit()
  end
end
