defmodule Domain.Notifications.Jobs.OutdatedGateways do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  require Logger
  require OpenTelemetry.Tracer

  alias Domain.Actors
  alias Domain.{Accounts, Gateways}

  @impl true
  def execute(_config) do
    Accounts.all_active_paid_accounts!()
    |> Enum.filter(fn account ->
      account_ready_for_outdated_notification?(account)
    end)
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
  end

  defp list_emails_for_actor(%Actors.Actor{} = actor) do
    actor.identities
    |> Enum.map(&Domain.Auth.get_identity_email/1)
    |> Enum.uniq()
  end

  defp send_email(account, gateways, email) do
    Domain.Mailer.Notifications.outdated_gateway_email(account, gateways, email)
    |> Domain.Mailer.deliver_with_rate_limit()
  end

  defp account_ready_for_outdated_notification?(_account) do
    true
  end
end
