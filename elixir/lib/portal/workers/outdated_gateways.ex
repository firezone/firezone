defmodule Portal.Workers.OutdatedGateways do
  @moduledoc """
  Oban worker that checks for outdated gateways and sends notifications.
  Scheduled via cron: every minute in dev, Sundays at 9am in prod.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias __MODULE__.Database
  alias Portal.{Billing, Device, Mailer}

  @impl Oban.Worker
  def perform(_job) do
    run_check()
    :ok
  end

  defp run_check do
    latest_version = Portal.ComponentVersions.gateway_version()

    Database.all_accounts_pending_notification!()
    |> Enum.reject(&dormant?/1)
    |> Enum.each(fn account ->
      incompatible_client_count = Database.count_incompatible_for(account, latest_version)

      all_online_gateways_for_account(account)
      |> Enum.filter(&Device.gateway_outdated?/1)
      |> send_notifications(account, incompatible_client_count)
    end)
  end

  # Dropped before anything is sent so last_notified stays unset and the account
  # is notified the first time it comes back.
  defp dormant?(account) do
    not Billing.paid_plan?(account) and not Database.account_active?(account.id)
  end

  defp all_online_gateways_for_account(account) do
    online_ids = Portal.Presence.Devices.online_ids(account.id, :gateway)

    Database.all_gateways_for_account!(account)
    |> Enum.filter(&(&1.id in online_ids))
  end

  defp send_notifications([], _account, _incompatible_client_count) do
    Logger.debug("No outdated gateways for account")
  end

  defp send_notifications(gateways, account, incompatible_client_count) do
    admin_emails =
      Database.all_admins_for_account!(account)
      |> Enum.map(& &1.email)

    if admin_emails != [] do
      send_email(account, gateways, incompatible_client_count, admin_emails)
    end

    changeset =
      account_changeset(account, %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              last_notified: DateTime.utc_now()
            }
          }
        }
      })

    Database.update_account(changeset)
  end

  defp send_email(account, gateways, incompatible_client_count, emails) do
    Mailer.Notifications.outdated_gateway_email(
      account,
      gateways,
      incompatible_client_count,
      emails
    )
    |> Mailer.enqueue()
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue outdated gateway email",
          account_id: account.id,
          recipient_count: length(emails),
          reason: inspect(reason)
        )
    end
  end

  defp account_changeset(account, attrs) do
    import Ecto.Changeset

    account
    |> cast(attrs, [])
    |> cast_embed(:config,
      with: fn config, config_attrs ->
        config
        |> cast(config_attrs, [])
        |> cast_embed(:notifications,
          with: fn notifications, notif_attrs ->
            notifications
            |> cast(notif_attrs, [])
            |> cast_embed(:outdated_gateway,
              with: fn gateway, gateway_attrs ->
                gateway
                |> cast(gateway_attrs, [:last_notified])
              end
            )
          end
        )
      end
    )
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Device

    def all_accounts_pending_notification! do
      from(a in Portal.Account,
        where: fragment("?->'notifications'->'outdated_gateway'->>'enabled' = 'true'", a.config),
        where:
          fragment(
            "?->'notifications'->'outdated_gateway'->>'last_notified' IS NULL",
            a.config
          ) or
            fragment(
              "(?->'notifications'->'outdated_gateway'->>'last_notified')::timestamp < timezone('UTC', NOW()) - interval '24 hours'",
              a.config
            )
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def account_active?(account_id) do
      from(sl in Portal.SessionLog, where: sl.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def all_admins_for_account!(account) do
      from(a in Portal.Actor, as: :actors)
      |> where([actors: a], a.is_disabled == false)
      |> where([actors: a], a.account_id == ^account.id)
      |> where([actors: a], a.type == :account_admin_user)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def update_account(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    def count_incompatible_for(account, gateway_version) do
      %{major: g_major, minor: g_minor} = Version.parse!(gateway_version)

      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> where([devices: d], d.account_id == ^account.id)
      |> where([devices: d], d.last_seen_at > ago(1, "week"))
      |> where(
        [devices: d],
        fragment("split_part(?, '.', 1)::int", d.last_seen_version) < ^g_major or
          (fragment("split_part(?, '.', 1)::int", d.last_seen_version) == ^g_major and
             fragment("split_part(?, '.', 2)::int", d.last_seen_version) <= ^(g_minor - 2))
      )
      |> join(:inner, [devices: d], a in Portal.Actor,
        on: d.actor_id == a.id and d.account_id == a.account_id,
        as: :actor
      )
      |> where([actor: a], a.is_disabled == false)
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def all_gateways_for_account!(account) do
      from(g in Device,
        where: g.type == :gateway,
        where: g.account_id == ^account.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

  end
end
