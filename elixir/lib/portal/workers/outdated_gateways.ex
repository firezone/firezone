defmodule Portal.Workers.OutdatedGateways do
  @moduledoc """
  Oban worker that checks for outdated gateways and sends notifications.
  Scheduled via cron: every minute in dev, Sundays at 9am in prod.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  require Logger
  require OpenTelemetry.Tracer

  alias __MODULE__.Database
  alias Portal.{Gateway, Mailer}

  @impl Oban.Worker
  def perform(_job) do
    run_check()
    :ok
  end

  defp run_check do
    latest_version = Portal.ComponentVersions.gateway_version()

    Database.all_accounts_pending_notification!()
    |> Enum.each(fn account ->
      incompatible_client_count = Database.count_incompatible_for(account, latest_version)

      all_online_gateways_for_account(account)
      |> Enum.filter(&Gateway.gateway_outdated?/1)
      |> send_notifications(account, incompatible_client_count)
    end)
  end

  defp all_online_gateways_for_account(account) do
    gateways_by_id =
      Database.all_gateways_for_account!(account)
      |> Enum.group_by(& &1.id)

    Database.all_sites_for_account!(account)
    |> Enum.flat_map(&Database.all_online_gateway_ids_by_site_id!(&1.id))
    |> Enum.flat_map(&Map.get(gateways_by_id, &1))
  end

  defp send_notifications([], _account, _incompatible_client_count) do
    Logger.debug("No outdated gateways for account")
  end

  defp send_notifications(gateways, account, incompatible_client_count) do
    Database.all_admins_for_account!(account)
    |> Enum.each(&send_email(account, gateways, incompatible_client_count, &1.email))

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

  defp send_email(account, gateways, incompatible_client_count, email) do
    Mailer.Notifications.outdated_gateway_email(
      account,
      gateways,
      incompatible_client_count,
      email
    )
    |> Mailer.deliver_with_rate_limit()
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
    alias Portal.Client
    alias Portal.ClientSession

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

    def all_admins_for_account!(account) do
      from(a in Portal.Actor, as: :actors)
      |> where([actors: a], is_nil(a.disabled_at))
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

      from(c in Client, as: :clients)
      |> where([clients: c], c.account_id == ^account.id)
      |> join(
        :inner_lateral,
        [clients: c],
        s in subquery(
          from(s in ClientSession,
            where: s.client_id == parent_as(:clients).id,
            where: s.account_id == parent_as(:clients).account_id,
            order_by: [desc: s.inserted_at],
            limit: 1
          )
        ),
        on: true,
        as: :latest_session
      )
      |> where([latest_session: s], s.inserted_at > ago(1, "week"))
      |> where(
        [latest_session: s],
        fragment("split_part(?, '.', 1)::int", s.version) < ^g_major or
          (fragment("split_part(?, '.', 1)::int", s.version) == ^g_major and
             fragment("split_part(?, '.', 2)::int", s.version) <= ^(g_minor - 2))
      )
      |> join(:inner, [clients: c], a in Portal.Actor,
        on: c.actor_id == a.id and c.account_id == a.account_id,
        as: :actor
      )
      |> where([actor: a], is_nil(a.disabled_at))
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def all_gateways_for_account!(account) do
      from(g in Portal.Gateway,
        where: g.account_id == ^account.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def all_sites_for_account!(account) do
      from(g in Portal.Site,
        where: g.account_id == ^account.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def all_online_gateway_ids_by_site_id!(site_id) do
      Portal.Presence.Gateways.Site.list(site_id)
      |> Map.keys()
    end
  end
end
