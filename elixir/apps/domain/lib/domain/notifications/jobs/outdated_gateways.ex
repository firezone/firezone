defmodule Domain.Notifications.Jobs.OutdatedGateways do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  require Logger
  require OpenTelemetry.Tracer

  alias Domain.Actors
  alias Domain.{Accounts, Gateways, Mailer}

  @impl true
  if Mix.env() == :prod do
    def execute(_config) do
      # Should only run on Sundays
      day_of_week = Date.utc_today() |> Date.day_of_week()
      if day_of_week == 7, do: run_check()
    end
  else
    def execute(_config) do
      run_check()
    end
  end

  defp run_check do
    Accounts.all_active_paid_accounts_pending_notification!()
    |> Enum.each(fn account ->
      all_online_gateways_for_account(account)
      |> Enum.filter(&Gateways.gateway_outdated?/1)
      |> send_notifications(account)
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

  defp send_notifications([], _account) do
    Logger.debug("No outdated gateways for account")
  end

  defp send_notifications(gateways, account) do
    Domain.Actors.all_admins_for_account!(account, preload: :identities)
    |> Enum.flat_map(&list_emails_for_actor/1)
    |> Enum.each(&send_email(account, gateways, &1))

    Domain.Accounts.update_account(account, %{
      config: %{
        notifications: %{
          outdated_gateway: %{
            last_notified: DateTime.utc_now()
          }
        }
      }
    })
  end

  defp list_emails_for_actor(%Actors.Actor{} = actor) do
    actor.identities
    |> Enum.map(&Domain.Auth.get_identity_email/1)
    |> Enum.uniq()
  end

  defp send_email(account, gateways, email) do
    Mailer.Notifications.outdated_gateway_email(account, gateways, email)
    |> Mailer.deliver_with_rate_limit()
  end

  def notified_in_last_24h?(%Accounts.Account{} = account) do
    last_notification = last_notified(account.config.notifications)

    if is_nil(last_notification) do
      false
    else
      DateTime.diff(DateTime.utc_now(), last_notification, :hour) < 24
    end
  end

  defp last_notified(%{outdated_gateway: %{last_notified: datetime}}), do: datetime
  defp last_notified(_), do: nil
end
