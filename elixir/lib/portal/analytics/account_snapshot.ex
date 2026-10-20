defmodule Portal.Analytics.AccountSnapshot do
  @moduledoc """
  Builds a product usage snapshot of every enabled account for PostHog.

  Each account yields two events: a `$groupidentify` that keeps the account's
  group properties current, and an `Account Snapshot` event that records the same
  properties over time. Properties are counts, enum values, timestamps and Stripe
  subscription details only.
  Names, addresses, emails, IPs and other customer-entered data are never sent.

  Building is separate from sending, so the payload can be inspected locally:

      Portal.Analytics.AccountSnapshot.stream() |> Enum.to_list() |> List.flatten()
  """

  alias Portal.Account
  alias Portal.Analytics.PostHog
  alias __MODULE__.Database

  @group_type "account"
  @snapshot_event "Account Snapshot"
  @batch_size 100

  @doc """
  Lazily builds snapshot events, emitting one list of events per batch of accounts.
  """
  @spec stream(DateTime.t()) :: Enumerable.t()
  def stream(now \\ DateTime.utc_now()) do
    Stream.unfold(nil, fn cursor ->
      case Database.fetch_enabled_accounts_batch(cursor, @batch_size) do
        [] ->
          nil

        accounts ->
          counts =
            accounts
            |> Database.fetch_counts_for_accounts(now)
            |> add_presence_counts(accounts, now)
          {build_events(accounts, counts, now), List.last(accounts).id}
      end
    end)
  end

  @doc """
  Sends every snapshot event to PostHog, one batch request per batch of accounts.
  """
  @spec send_all(DateTime.t()) :: :ok | {:error, term()}
  def send_all(now \\ DateTime.utc_now()) do
    now
    |> stream()
    |> Enum.reduce_while(:ok, fn events, :ok ->
      case PostHog.batch(events) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec build_events([Account.t()], %{Ecto.UUID.t() => map()}, DateTime.t()) :: [map()]
  def build_events(accounts, counts, now) do
    timestamp = DateTime.to_iso8601(now)
    date = Date.to_iso8601(DateTime.to_date(now))

    Enum.flat_map(accounts, fn account ->
      properties = properties(account, Map.get(counts, account.id, %{}))

      [
        %{
          "event" => "$groupidentify",
          "timestamp" => timestamp,
          "uuid" => PostHog.event_uuid([account.id, "$groupidentify", date]),
          "properties" => %{
            "distinct_id" => account.id,
            "$process_person_profile" => false,
            "$group_type" => @group_type,
            "$group_key" => account.id,
            "$group_set" => properties
          }
        },
        %{
          "event" => @snapshot_event,
          "timestamp" => timestamp,
          "uuid" => PostHog.event_uuid([account.id, @snapshot_event, date]),
          "properties" =>
            Map.merge(properties, %{
              "distinct_id" => account.id,
              "$process_person_profile" => false,
              "$groups" => %{@group_type => account.id}
            })
        }
      ]
    end)
  end

  # `last_seen_at` is written when a device connects, not while it stays connected,
  # so devices connected since before a window started are missing from that
  # window's database count. Presence knows when each connection started, so those
  # are added from there. Counting in memory keeps device IDs out of the queries.
  @presence_windows [
    gateways_active_1d: {:gateway, 1},
    clients_active_1d: {:client, 1},
    clients_active_7d: {:client, 7},
    clients_active_30d: {:client, 30}
  ]

  defp add_presence_counts(counts, accounts, now) do
    Enum.reduce(accounts, counts, fn account, counts ->
      presence_counts = presence_counts(account.id, now)

      Map.update(counts, account.id, presence_counts, &sum_counts(&1, presence_counts))
    end)
  end

  defp sum_counts(a, b), do: Map.merge(a, b, fn _key, a, b -> a + b end)

  defp presence_counts(account_id, now) do
    cutoffs =
      Map.new(@presence_windows, fn {key, {_type, days}} ->
        {key, now |> DateTime.add(-days, :day) |> DateTime.to_unix()}
      end)

    initial =
      Map.new([:gateways_online, :clients_online | Keyword.keys(@presence_windows)], &{&1, 0})

    account_id
    |> Portal.Presence.Devices.Account.list()
    |> Enum.reduce(initial, fn
      {_device_id, %{metas: [%{type: type, online_at: online_at} | _]}}, acc ->
        count_session(acc, type, online_at, cutoffs)

      _presence, acc ->
        acc
    end)
  end

  defp count_session(acc, type, online_at, cutoffs) do
    acc = Map.update!(acc, online_key(type), &(&1 + 1))

    Enum.reduce(@presence_windows, acc, fn {key, {window_type, _days}}, acc ->
      if type == window_type and online_at <= cutoffs[key],
        do: Map.update!(acc, key, &(&1 + 1)),
        else: acc
    end)
  end

  defp online_key(:gateway), do: :gateways_online
  defp online_key(:client), do: :clients_online

  defp properties(account, counts) do
    %{
      "plan_type" => account |> Portal.Billing.plan_type() |> Atom.to_string(),
      "subscription_status" => stripe(account).subscription_status,
      "trial_ends_at" => iso8601(stripe(account).trial_ends_at),
      "support_type" => stripe(account).support_type,
      "add_ons" => add_on_names(stripe(account)),
      "account_created_at" => DateTime.to_iso8601(account.inserted_at),
      "features_enabled" => enabled_features(account),
      "sites_count" => Map.get(counts, :sites, 0),
      "gateways_count" => Map.get(counts, :gateways, 0),
      "gateways_online_count" => Map.get(counts, :gateways_online, 0),
      "gateways_active_1d_count" => Map.get(counts, :gateways_active_1d, 0),
      "gateway_versions" => Map.get(counts, :gateway_versions, []),
      "clients_count" => Map.get(counts, :clients, 0),
      "clients_online_count" => Map.get(counts, :clients_online, 0),
      "clients_active_1d_count" => Map.get(counts, :clients_active_1d, 0),
      "clients_active_7d_count" => Map.get(counts, :clients_active_7d, 0),
      "clients_active_30d_count" => Map.get(counts, :clients_active_30d, 0),
      "clients_verified_count" => Map.get(counts, :clients_verified, 0),
      "resources_count" => Map.get(counts, :resources, 0),
      "resources_cidr_count" => Map.get(counts, :resources_cidr, 0),
      "resources_ip_count" => Map.get(counts, :resources_ip, 0),
      "resources_dns_count" => Map.get(counts, :resources_dns, 0),
      "resources_internet_count" => Map.get(counts, :resources_internet, 0),
      "resources_device_pool_count" => Map.get(counts, :resources_device_pool, 0),
      "policies_count" => Map.get(counts, :policies, 0),
      "policies_disabled_count" => Map.get(counts, :policies_disabled, 0),
      "policies_with_conditions_count" => Map.get(counts, :policies_with_conditions, 0),
      "policies_with_postures_count" => Map.get(counts, :policies_with_postures, 0),
      "policy_authorizations_active_count" => Map.get(counts, :policy_authorizations_active, 0),
      "admins_count" => Map.get(counts, :admins, 0),
      "users_count" => Map.get(counts, :users, 0),
      "service_accounts_count" => Map.get(counts, :service_accounts, 0),
      "api_clients_count" => Map.get(counts, :api_clients, 0),
      "groups_managed_count" => Map.get(counts, :groups_managed, 0),
      "groups_static_count" => Map.get(counts, :groups_static, 0),
      "auth_provider_types" => Map.get(counts, :auth_provider_types, []),
      "directory_types" => Map.get(counts, :directory_types, []),
      "posture_provider_types" => Map.get(counts, :posture_provider_types, []),
      "log_sink_types" => Map.get(counts, :log_sink_types, []),
      "api_tokens_count" => Map.get(counts, :api_tokens, 0),
      "oauth_grants_count" => Map.get(counts, :oauth_grants, 0)
    }
  end

  defp stripe(%Account{metadata: %{stripe: %Account.Metadata.Stripe{} = stripe}}), do: stripe
  defp stripe(%Account{}), do: %Account.Metadata.Stripe{}

  defp add_on_names(%Account.Metadata.Stripe{add_ons: add_ons}) when is_list(add_ons) do
    add_ons |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp add_on_names(_stripe), do: []

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp enabled_features(%Account{features: nil}), do: []

  defp enabled_features(%Account{features: features}) do
    features
    |> Map.from_struct()
    |> Enum.filter(fn {_feature, enabled} -> enabled == true end)
    |> Enum.map(fn {feature, _enabled} -> Atom.to_string(feature) end)
    |> Enum.sort()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def fetch_enabled_accounts_batch(cursor, limit) do
      from(a in Account,
        where: a.is_disabled == false,
        order_by: [asc: a.id],
        limit: ^limit
      )
      |> maybe_after_cursor(cursor)
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp maybe_after_cursor(query, nil), do: query
    defp maybe_after_cursor(query, cursor), do: where(query, [a], a.id > ^cursor)

    @doc """
    Fetches snapshot counts for the given accounts with one grouped query per table.
    Returns a map of account_id -> counts; accounts without rows in a table are absent
    from that table's counts.
    """
    def fetch_counts_for_accounts(accounts, now) do
      account_ids = Enum.map(accounts, & &1.id)

      [
        count_sites(account_ids),
        count_devices(account_ids, now),
        gateway_versions(account_ids, now),
        count_resources(account_ids),
        count_policies(account_ids),
        count_policy_authorizations(account_ids, now),
        count_actors(account_ids),
        count_groups(account_ids),
        types_in_use(Portal.AuthProvider, :auth_provider_types, account_ids),
        types_in_use(Portal.Directory, :directory_types, account_ids),
        types_in_use(Portal.PostureProvider, :posture_provider_types, account_ids),
        types_in_use(Portal.LogSink, :log_sink_types, account_ids),
        count_rows(Portal.APIToken, :api_tokens, account_ids),
        count_rows(Portal.OAuthGrant, :oauth_grants, account_ids)
      ]
      |> Enum.reduce(%{}, fn counts_by_account, acc ->
        Map.merge(acc, counts_by_account, fn _account_id, a, b -> Map.merge(a, b) end)
      end)
    end

    defp count_sites(account_ids) do
      from(s in Portal.Site,
        where: s.account_id in ^account_ids,
        where: s.managed_by == :account,
        group_by: s.account_id,
        select: {s.account_id, %{sites: count(s.id)}}
      )
      |> all_as_map()
    end

    defp count_devices(account_ids, now) do
      from(d in Portal.Device,
        where: d.account_id in ^account_ids,
        group_by: d.account_id,
        select:
          {d.account_id,
           %{
             gateways: filter(count(d.id), d.type == :gateway),
             gateways_active_1d:
               filter(count(d.id), d.type == :gateway and d.last_seen_at > ^days_ago(now, 1)),
             clients: filter(count(d.id), d.type == :client),
             clients_active_1d:
               filter(count(d.id), d.type == :client and d.last_seen_at > ^days_ago(now, 1)),
             clients_active_7d:
               filter(count(d.id), d.type == :client and d.last_seen_at > ^days_ago(now, 7)),
             clients_active_30d:
               filter(count(d.id), d.type == :client and d.last_seen_at > ^days_ago(now, 30)),
             clients_verified:
               filter(count(d.id), d.type == :client and not is_nil(d.verified_at))
           }}
      )
      |> all_as_map()
    end

    defp gateway_versions(account_ids, now) do
      from(d in Portal.Device,
        where: d.account_id in ^account_ids,
        where: d.type == :gateway,
        where: not is_nil(d.last_seen_version),
        where: d.last_seen_at > ^days_ago(now, 30),
        distinct: true,
        select: {d.account_id, d.last_seen_version}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> group_values(:gateway_versions)
    end

    defp count_resources(account_ids) do
      from(r in Portal.Resource,
        where: r.account_id in ^account_ids,
        group_by: r.account_id,
        select:
          {r.account_id,
           %{
             resources: count(r.id),
             resources_cidr: filter(count(r.id), r.type == :cidr),
             resources_ip: filter(count(r.id), r.type == :ip),
             resources_dns: filter(count(r.id), r.type == :dns),
             resources_internet: filter(count(r.id), r.type == :internet),
             resources_device_pool: filter(count(r.id), r.type == :device_pool)
           }}
      )
      |> all_as_map()
    end

    defp count_policies(account_ids) do
      from(p in Portal.Policy,
        where: p.account_id in ^account_ids,
        group_by: p.account_id,
        select:
          {p.account_id,
           %{
             policies: count(p.id),
             policies_disabled: filter(count(p.id), p.is_disabled),
             policies_with_conditions:
               filter(count(p.id), fragment("cardinality(?) > 0", p.conditions)),
             policies_with_postures: filter(count(p.id), not is_nil(p.postures))
           }}
      )
      |> all_as_map()
    end

    # Authorizations are deleted once they expire, so this is the number currently
    # in effect, not a history.
    defp count_policy_authorizations(account_ids, now) do
      from(pa in Portal.PolicyAuthorization,
        where: pa.account_id in ^account_ids,
        where: pa.expires_at > ^now,
        group_by: pa.account_id,
        select: {pa.account_id, %{policy_authorizations_active: count(pa.id)}}
      )
      |> all_as_map()
    end

    defp count_actors(account_ids) do
      from(a in Portal.Actor,
        where: a.account_id in ^account_ids,
        where: a.is_disabled == false,
        group_by: a.account_id,
        select:
          {a.account_id,
           %{
             admins: filter(count(a.id), a.type == :account_admin_user),
             users: filter(count(a.id), a.type == :account_user),
             service_accounts: filter(count(a.id), a.type == :service_account),
             api_clients: filter(count(a.id), a.type == :api_client)
           }}
      )
      |> all_as_map()
    end

    defp count_groups(account_ids) do
      from(g in Portal.Group,
        where: g.account_id in ^account_ids,
        group_by: g.account_id,
        select:
          {g.account_id,
           %{
             groups_managed: filter(count(g.id), g.type == :managed),
             groups_static: filter(count(g.id), g.type == :static)
           }}
      )
      |> all_as_map()
    end

    defp types_in_use(schema, key, account_ids) do
      from(row in schema,
        where: row.account_id in ^account_ids,
        distinct: true,
        select: {row.account_id, row.type}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(fn {account_id, type} -> {account_id, Atom.to_string(type)} end)
      |> group_values(key)
    end

    defp count_rows(schema, key, account_ids) do
      from(row in schema,
        where: row.account_id in ^account_ids,
        group_by: row.account_id,
        select: {row.account_id, count(row.id)}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new(fn {account_id, count} -> {account_id, %{key => count}} end)
    end

    defp all_as_map(query) do
      query
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end

    defp group_values(rows, key) do
      rows
      |> Enum.group_by(fn {account_id, _value} -> account_id end, fn {_id, value} -> value end)
      |> Map.new(fn {account_id, values} -> {account_id, %{key => Enum.sort(values)}} end)
    end

    defp days_ago(now, days), do: DateTime.add(now, -days, :day)
  end
end
