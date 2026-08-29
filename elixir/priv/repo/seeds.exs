defmodule Portal.Repo.Seeds do
  @moduledoc """
  Seeds the database with initial data.
  """
  import Ecto.Changeset
  import Ecto.Query

  alias Portal.{
    Repo,
    APIRequestLog,
    Authentication,
    AuthProvider,
    Account,
    Actor,
    ChangeLog,
    Crypto,
    EmailOTP,
    Entra,
    Defender,
    ExternalIdentity,
    Device,
    FlowLog,
    PolicyAuthorization,
    Google,
    Group,
    Intune,
    Iru,
    Membership,
    NameGenerator,
    OIDC,
    Policy,
    Resource,
    Safe,
    Santa,
    SentinelOne,
    SessionLog,
    Site,
    ClientToken,
    Userpass,
    X509
  }

  alias Portal.Types.LogId

  # User agent strings for seeded clients and gateways.
  # Update these when bumping the connlib version used in dev/test.
  @ua_gateway "Linux/6.1.0 connlib/1.4.1 (x86_64)"
  @ua_ios "iOS/18.7.7 apple-client/1.4.1 (24.6.0)"
  @ua_android "Android/14 connlib/1.4.1"
  @ua_windows "Windows/11.0.22631 connlib/1.4.1"
  @ua_ubuntu "Ubuntu/22.04 connlib/1.4.1"
  @ua_macos "Mac OS/14.1.0 apple-client/1.4.1 (arm64; 23.1.0)"
  # Pinned >= 1.5.9: client-to-client connections are version-gated.
  @ua_pool_member "Ubuntu/22.04 connlib/1.5.9"

  @initiator_user_agents [@ua_ios, @ua_android, @ua_windows, @ua_ubuntu, @ua_macos]

  # {region, city, lat, lon} tuples for seeded sessions.
  @locations [
    {"US-CA", "San Francisco", 37.7749, -122.4194},
    {"US-NY", "New York", 40.7128, -74.006},
    {"GB", "London", 51.5074, -0.1278},
    {"DE", "Berlin", 52.52, 13.405},
    {"FR", "Paris", 48.8566, 2.3522},
    {"NL", "Amsterdam", 52.3676, 4.9041},
    {"SG", "Singapore", 1.3521, 103.8198},
    {"JP", "Tokyo", 35.6762, 139.6503},
    {"AU", "Sydney", -33.8688, 151.2093},
    {"CA", "Toronto", 43.6532, -79.3832},
    {"BR", "Sao Paulo", -23.5505, -46.6333},
    {"UA", "Kyiv", 50.4333, 30.5167}
  ]

  # Populate these in your .env
  defp google_idp_id do
    System.get_env("GOOGLE_IDP_ID", "dummy")
  end

  defp entra_idp_id do
    System.get_env("ENTRA_IDP_ID", "dummy")
  end

  defp entra_tenant_id do
    System.get_env("ENTRA_TENANT_ID", "dummy")
  end

  # Helper function to create auth providers with the new structure
  defp create_auth_provider(provider_module, attrs, subject) do
    provider_id = Ecto.UUID.generate()
    type = AuthProvider.type!(provider_module)
    # Convert type to atom if it's a string
    type = if is_binary(type), do: String.to_existing_atom(type), else: type

    # First create the base auth_provider record using Repo directly
    {:ok, _base_provider} =
      Repo.insert(%AuthProvider{
        id: provider_id,
        account_id: subject.account.id,
        type: type
      })

    # Then create the provider-specific record using Repo directly (seeds don't need authorization)
    attrs_with_id =
      attrs
      |> Map.put(:id, provider_id)
      |> Map.put(:account_id, subject.account.id)

    changeset = struct(provider_module, attrs_with_id) |> Ecto.Changeset.change()

    Repo.insert(changeset)
  end

  # Helper function to create resource directly without context module
  defp create_resource(attrs, subject) do
    # Create the resource
    resource =
      %Resource{
        account_id: subject.account.id,
        type: attrs[:type] || attrs["type"],
        name: attrs[:name] || attrs["name"],
        address: attrs[:address] || attrs["address"],
        address_description: attrs[:address_description] || attrs["address_description"],
        filters: attrs[:filters] || attrs["filters"] || [],
        site_id: attrs[:site_id] || attrs["site_id"]
      }
      |> Repo.insert!()

    {:ok, resource}
  end

  # Helper function to create gateway directly without context module
  defp create_gateway(attrs, context) do
    # Extract version from user agent
    version =
      context.user_agent
      |> String.split("/")
      |> List.last()
      |> String.split(" ")
      |> List.first()

    # Get the site to get the account_id
    site_id = attrs["site_id"] || attrs[:site_id]
    site = Repo.get_by!(Site, id: site_id)
    firezone_id = attrs["firezone_id"] || attrs[:firezone_id]

    public_key = attrs["public_key"] || attrs[:public_key]

    # First create the gateway
    gateway =
      %Device{}
      |> Ecto.Changeset.cast(
        %{
          name: attrs["name"] || attrs[:name],
          firezone_id: firezone_id,
          ipv4: attrs["ipv4"] || attrs[:ipv4],
          ipv6: attrs["ipv6"] || attrs[:ipv6]
        },
        [:name, :firezone_id, :ipv4, :ipv6]
      )
      |> Ecto.Changeset.put_change(:type, :gateway)
      |> Ecto.Changeset.put_change(:account_id, site.account_id)
      |> Ecto.Changeset.put_change(:site_id, site_id)
      |> Device.changeset()
      |> Safe.unscoped()
      |> Safe.insert()
      |> case do
        {:ok, gateway} ->
          gateway

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
      end

    # Find the latest gateway token for the site
    gateway_token =
      Repo.one!(
        from(t in Portal.GatewayToken,
          where: t.site_id == ^site_id and t.account_id == ^site.account_id,
          order_by: [desc: t.inserted_at],
          limit: 1
        )
      )

    {location_region, location_city, location_lat, location_lon} = Enum.random(@locations)

    gateway =
      gateway
      |> Ecto.Changeset.change(
        public_key: public_key,
        last_seen_user_agent: context.user_agent,
        last_seen_remote_ip: context.remote_ip,
        last_seen_remote_ip_location_region: location_region,
        last_seen_remote_ip_location_city: location_city,
        last_seen_remote_ip_location_lat: location_lat,
        last_seen_remote_ip_location_lon: location_lon,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now(),
        gateway_token_id: gateway_token.id
      )
      |> Repo.update!()

    {:ok, gateway}
  end

  # Helper function to create client directly without context module
  defp create_client(attrs, subject, client_token_id, user_agent) do
    # Extract version from user agent (e.g., "macOS/14.6 apple-client/1.4.1" -> "1.4.1")
    version =
      user_agent |> String.split("/") |> List.last() |> String.split(" ") |> List.first()

    firezone_id = attrs["firezone_id"] || attrs[:firezone_id]

    # First create the client
    public_key = attrs["public_key"] || attrs[:public_key]

    client =
      %Device{}
      |> Ecto.Changeset.cast(
        %{
          name: attrs["name"] || attrs[:name],
          firezone_id: firezone_id,
          identifier_for_vendor: attrs["identifier_for_vendor"] || attrs[:identifier_for_vendor],
          device_uuid: attrs["device_uuid"] || attrs[:device_uuid],
          device_serial: attrs["device_serial"] || attrs[:device_serial],
          ipv4: attrs["ipv4"] || attrs[:ipv4],
          ipv6: attrs["ipv6"] || attrs[:ipv6]
        },
        [:name, :firezone_id, :identifier_for_vendor, :device_uuid, :device_serial, :ipv4, :ipv6]
      )
      |> Ecto.Changeset.put_change(:type, :client)
      |> Ecto.Changeset.put_change(:account_id, subject.account.id)
      |> Ecto.Changeset.put_change(:actor_id, subject.actor.id)
      |> Device.changeset()
      |> Safe.unscoped()
      |> Safe.insert()
      |> case do
        {:ok, client} ->
          client

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
      end

    {location_region, location_city, location_lat, location_lon} = Enum.random(@locations)

    client =
      client
      |> Ecto.Changeset.change(
        public_key: public_key,
        last_seen_user_agent: user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_remote_ip_location_region: location_region,
        last_seen_remote_ip_location_city: location_city,
        last_seen_remote_ip_location_lat: location_lat,
        last_seen_remote_ip_location_lon: location_lon,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now(),
        client_token_id: client_token_id
      )
      |> Repo.update!()

    {:ok, client}
  end

  defp create_seed_policy_authorization(
         subject,
         initiating_device,
         receiving_device,
         resource,
         policy,
         membership
       ) do
    %PolicyAuthorization{
      initiating_device_id: initiating_device.id,
      receiving_device_id: receiving_device.id,
      resource_id: resource.id,
      policy_id: policy.id,
      membership_id: membership && membership.id,
      account_id: subject.account.id,
      token_id: subject.credential.id,
      initiator_remote_ip: {127, 0, 0, 1},
      initiator_user_agent: @ua_ios,
      receiver_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}, netmask: nil},
      expires_at: subject.expires_at || DateTime.add(DateTime.utc_now(), 1, :hour)
    }
    |> Repo.insert!()
  end

  # Seeds logs from each device rather than pre-aggregated flows. The recent rows
  # deliberately cover the states the Flow Logs UI needs to communicate:
  # paired TCP/UDP logs, an open initiator log, a responder-only log,
  # an invalid-looking interval caused by clock skew, and a one-to-many
  # overlap that must be labeled ambiguous rather than silently rolled up.
  defp seed_flow_logs(account, actor, initiator, auth_provider_id, contexts) do
    now = DateTime.utc_now()

    base = %{
      account: account,
      actor: actor,
      initiator: initiator,
      auth_provider_id: auth_provider_id,
      inserted_at: now
    }

    google = Map.merge(base, contexts.google)
    httpbin = Map.merge(base, contexts.httpbin)
    network = Map.merge(base, contexts.network)
    iperf = Map.merge(base, contexts.iperf)

    open_report =
      seed_flow_log_row(google, %{
        role: :initiator,
        protocol: :tcp,
        inner_src_port: 54_001,
        inner_dst_port: 443,
        flow_start: DateTime.add(now, -2, :minute),
        flow_end: nil
      })

    recent_tcp =
      paired_seed_flow_logs(httpbin, %{
        protocol: :tcp,
        inner_src_port: 54_002,
        inner_dst_port: 443,
        flow_start: DateTime.add(now, -8, :minute),
        flow_end: DateTime.add(now, -3, :minute),
        tx_packets: 6_240,
        rx_packets: 5_980,
        tx_bytes: 8_400_000,
        rx_bytes: 42_700_000
      })

    recent_udp =
      paired_seed_flow_logs(google, %{
        protocol: :udp,
        inner_src_port: 54_003,
        inner_dst_port: 53,
        flow_start: DateTime.add(now, -14, :minute),
        flow_end: DateTime.add(now, -12, :minute),
        tx_packets: 24,
        rx_packets: 22,
        tx_bytes: 2_480,
        rx_bytes: 9_720
      })

    responder_only =
      seed_flow_log_row(network, %{
        role: :responder,
        protocol: :tcp,
        inner_src_port: 54_004,
        inner_dst_port: 22,
        flow_start: DateTime.add(now, -22, :minute),
        flow_end: DateTime.add(now, -20, :minute)
      })

    clock_skewed =
      seed_flow_log_row(iperf, %{
        role: :initiator,
        protocol: :tcp,
        inner_src_port: 54_005,
        inner_dst_port: 5_201,
        flow_start: DateTime.add(now, -30, :minute),
        flow_end: DateTime.add(now, -31, :minute),
        tx_packets: 8_440,
        rx_packets: 8_120,
        tx_bytes: 640_000_000,
        rx_bytes: 612_000_000
      })

    # The initiator sees one long flow while the responder sees two sequential
    # windows for the same tuple. Both overlap the initiator window, so neither
    # responder can be selected as a guaranteed match from the current fields.
    ambiguous_attrs = %{
      protocol: :tcp,
      inner_src_port: 54_006,
      inner_dst_port: 80
    }

    ambiguous = [
      seed_flow_log_row(
        httpbin,
        Map.merge(ambiguous_attrs, %{
          role: :initiator,
          flow_start: DateTime.add(now, -55, :minute),
          flow_end: DateTime.add(now, -30, :minute),
          tx_packets: 940,
          rx_packets: 860,
          tx_bytes: 2_800_000,
          rx_bytes: 18_600_000
        })
      ),
      seed_flow_log_row(
        httpbin,
        Map.merge(ambiguous_attrs, %{
          role: :responder,
          flow_start: DateTime.add(now, -54, :minute),
          flow_end: DateTime.add(now, -43, :minute),
          tx_packets: 410,
          rx_packets: 380,
          tx_bytes: 1_200_000,
          rx_bytes: 8_100_000
        })
      ),
      seed_flow_log_row(
        httpbin,
        Map.merge(ambiguous_attrs, %{
          role: :responder,
          flow_start: DateTime.add(now, -42, :minute),
          flow_end: DateTime.add(now, -29, :minute),
          tx_packets: 525,
          rx_packets: 475,
          tx_bytes: 1_580_000,
          rx_bytes: 10_420_000
        })
      )
    ]

    historical =
      1..6
      |> Enum.flat_map(fn i ->
        context = Enum.at([google, httpbin, iperf], rem(i - 1, 3))
        protocol = if rem(i, 3) == 0, do: :udp, else: :tcp
        started_at = DateTime.add(now, -i * 8, :hour)

        paired_seed_flow_logs(context, %{
          protocol: protocol,
          inner_src_port: 55_000 + i,
          inner_dst_port: if(protocol == :udp, do: 5_201, else: context.default_port),
          flow_start: started_at,
          flow_end: DateTime.add(started_at, 90 + i * 20, :second),
          tx_packets: 80 * i,
          rx_packets: 65 * i,
          tx_bytes: 240_000 * i,
          rx_bytes: 1_100_000 * i
        })
      end)

    rows =
      [open_report]
      |> Kernel.++(recent_tcp)
      |> Kernel.++(recent_udp)
      |> Kernel.++([responder_only, clock_skewed])
      |> Kernel.++(ambiguous)
      |> Kernel.++(historical)

    {count, _} = Repo.insert_all(FlowLog, rows)
    IO.puts("Created #{count} flow logs")
    IO.puts("")
  end

  defp paired_seed_flow_logs(context, attrs) do
    initiator = seed_flow_log_row(context, Map.put(attrs, :role, :initiator))

    responder_attrs =
      attrs
      |> Map.put(:role, :responder)
      |> Map.update!(:flow_start, &DateTime.add(&1, 2, :second))
      |> Map.update!(:flow_end, &DateTime.add(&1, 3, :second))
      |> Map.put(:tx_packets, max(Map.get(attrs, :tx_packets, 120) - 2, 0))
      |> Map.put(:rx_packets, max(Map.get(attrs, :rx_packets, 96) - 2, 0))
      |> Map.put(:tx_bytes, max(Map.get(attrs, :tx_bytes, 600_000) - 1_200, 0))
      |> Map.put(:rx_bytes, max(Map.get(attrs, :rx_bytes, 1_800_000) - 2_400, 0))

    [initiator, seed_flow_log_row(context, responder_attrs)]
  end

  defp seed_flow_log_row(context, attrs) do
    flow_end = Map.fetch!(attrs, :flow_end)
    closed? = not is_nil(flow_end)

    %{
      account_id: context.account.id,
      log_id: LogId.build_flow_log(),
      initiator_device_id: context.initiator.id,
      responder_device_id: context.authorization.receiving_device_id,
      role: Map.fetch!(attrs, :role),
      policy_authorization_id: context.authorization.id,
      policy_id: context.authorization.policy_id,
      resource_id: context.resource.id,
      resource_name: context.resource.name,
      resource_address: context.resource.address,
      authorized_at: context.authorization.inserted_at,
      authorization_expires_at: context.authorization.expires_at,
      initiator_actor_id: context.actor.id,
      initiator_actor_name: context.actor.name,
      initiator_actor_email: context.actor.email,
      initiator_auth_provider_id: context.auth_provider_id,
      initiator_client_version: context.initiator.last_seen_version,
      initiator_device_os_name: "iOS",
      initiator_device_os_version: "18.7.7",
      initiator_device_serial: context.initiator.device_serial,
      initiator_device_uuid: context.initiator.device_uuid,
      initiator_device_identifier_for_vendor: context.initiator.identifier_for_vendor,
      initiator_device_firebase_installation_id: context.initiator.firebase_installation_id,
      protocol: Map.fetch!(attrs, :protocol),
      inner_src_ip: context.initiator.ipv4,
      inner_src_port: Map.fetch!(attrs, :inner_src_port),
      inner_dst_ip: context.inner_dst_ip,
      inner_dst_port: Map.fetch!(attrs, :inner_dst_port),
      domain: context.domain,
      # connlib normalizes both logs to initiator -> responder, including the
      # WireGuard tuple, so paired logs intentionally carry the same values.
      outers:
        if(closed?,
          do: [
            %FlowLog.Outer{
              src_ip: "203.0.113.44",
              src_port: 62_000,
              dst_ip: "189.172.73.153",
              dst_port: 51_820
            }
          ]
        ),
      flow_start: Map.fetch!(attrs, :flow_start),
      flow_end: flow_end,
      last_packet: if(closed?, do: Map.get(attrs, :last_packet, DateTime.add(flow_end, -1, :second))),
      tx_packets: if(closed?, do: Map.get(attrs, :tx_packets, 120)),
      rx_packets: if(closed?, do: Map.get(attrs, :rx_packets, 96)),
      tx_bytes: if(closed?, do: Map.get(attrs, :tx_bytes, 600_000)),
      rx_bytes: if(closed?, do: Map.get(attrs, :rx_bytes, 1_800_000)),
      inserted_at: context.inserted_at
    }
  end

  # Seeds a mix of change_logs, session_logs, and api_request_logs so the
  # Audit UI has realistic entries out of the box: recent admin sign-ins,
  # a few days of REST API traffic, and configuration change history with
  # varied operations, objects, and geographic sources.
  defp seed_audit_logs(account, subjects, api_actor, api_token_id) do
    seq = :atomics.new(1, [])
    now = DateTime.utc_now()

    seed_change_logs(account, subjects, now, seq)
    seed_session_logs(account, subjects, now)
    seed_api_request_logs(account, api_actor, api_token_id, now)
  end

  defp seed_change_logs(account, subjects, now, seq) do
    admin_subj = subjects.admin
    unpriv_subj = subjects.unpriv

    # Each spec: {mins_ago, subject_or_nil, object, op, before_map, after_map}.
    # `before` and `after` mirror what the WAL replicator captures: full row
    # snapshots on both sides of an update, so the diff renders every field
    # (unchanged ones in muted text) instead of just the changed keys. For
    # updates we build a full base row once and derive `after` from it so
    # identity columns (id, account_id, etc.) show as unchanged.
    policy_a = policy_row(description: "Legacy", name: "Engineering full access")
    policy_a_updated = Map.put(policy_a, "description", "Engineering full access")

    resource_a = resource_row(name: "Staging DB", address: "10.0.0.99")
    resource_a_updated = Map.put(resource_a, "address", "10.0.0.100")

    group_a = group_row(name: "engineers")
    group_a_updated = Map.put(group_a, "name", "Engineering")

    actor_a = actor_row(name: "Sam", email: "sam@example.com", type: "account_user")
    actor_a_updated = Map.put(actor_a, "type", "account_admin_user")

    provider_a = provider_row(name: "Google")
    provider_a_updated = Map.put(provider_a, "name", "Google Workspace")

    client_a = client_row(name: "MacBook")
    client_a_updated = Map.put(client_a, "name", "Alex's MacBook")

    policy_b = policy_row(name: "Contractors: region gate", conditions: [])

    policy_b_updated =
      Map.put(policy_b, "conditions", [
        %{"property" => "remote_ip_location_region", "operator" => "is_in"}
      ])

    actor_b = actor_row(name: "Casey", email: "casey@example.com", disabled_at: nil)
    actor_b_updated = Map.put(actor_b, "disabled_at", DateTime.utc_now() |> DateTime.to_iso8601())

    specs = [
      {5, admin_subj, "policies", :update, policy_a, policy_a_updated},
      {8, admin_subj, "resources", :insert, nil,
       resource_row(name: "Prod DB", address: "10.0.0.42", type: "cidr")},
      {17, admin_subj, "groups", :update, group_a, group_a_updated},
      {28, admin_subj, "resources", :update, resource_a, resource_a_updated},
      {42, admin_subj, "policies", :insert, nil,
       policy_row(name: "Contractors read-only")},
      {55, admin_subj, "actors", :update, actor_a, actor_a_updated},
      {70, admin_subj, "auth_providers", :update, provider_a, provider_a_updated},
      {90, admin_subj, "groups", :insert, nil, group_row(name: "Contractors")},
      {120, admin_subj, "actors", :insert, nil,
       actor_row(name: "Alex", email: "alex@example.com", type: "account_user")},
      {180, unpriv_subj, "clients", :update, client_a, client_a_updated},
      {220, admin_subj, "resources", :delete,
       resource_row(name: "Old staging DB", address: "10.0.0.55"), nil},
      {60 * 5, admin_subj, "policies", :update, policy_b, policy_b_updated},
      {60 * 6, admin_subj, "sites", :insert, nil, site_row(name: "us-east-2")},
      {60 * 8, admin_subj, "gateway_tokens", :insert, nil,
       gateway_token_row(name: "us-east-2 provisioning")},
      {60 * 12, admin_subj, "api_tokens", :insert, nil,
       api_token_row(name: "terraform-ci")},
      {60 * 24, admin_subj, "policies", :delete, policy_row(name: "Legacy VPN"), nil},
      {60 * 26, nil, "workers", :delete,
       %{"queue" => "default", "attempts" => 3, "count" => 481}, nil},
      {60 * 30, admin_subj, "actors", :update, actor_b, actor_b_updated},
      {60 * 48, admin_subj, "resources", :insert, nil,
       resource_row(name: "GitHub", address: "github.com", type: "dns")},
      {60 * 72, admin_subj, "auth_providers", :insert, nil, provider_row(name: "Entra")}
    ]

    rows =
      Enum.map(specs, fn {mins_ago, subject, object, op, before_map, after_map} ->
        timestamp = DateTime.add(now, -mins_ago * 60, :second)
        lsn = :atomics.add_get(seq, 1, 1)

        %{
          log_id: LogId.build_change_log(System.os_time(:microsecond), lsn),
          account_id: account.id,
          timestamp: timestamp,
          lsn: lsn,
          object: object,
          operation: op,
          before: before_map,
          after: after_map,
          subject: subject,
          vsn: 0
        }
      end)

    Repo.insert_all(ChangeLog, rows)
  end

  defp seed_session_logs(account, subjects, now) do
    admin_subj = subjects.admin
    unpriv_subj = subjects.unpriv

    # Each spec: {mins_ago, context, subject}
    specs = [
      {2, :portal, admin_subj},
      {15, :client, unpriv_subj},
      {35, :client, subject_at(unpriv_subj, "US-NY", "New York", 40.7128, -74.006)},
      {60, :gateway, gateway_subject(account, "US-CA", "San Francisco", 37.7749, -122.4194)},
      {90, :portal, subject_at(admin_subj, "GB", "London", 51.5074, -0.1278)},
      {150, :client, subject_at(unpriv_subj, "DE", "Berlin", 52.52, 13.405)},
      {180, :gateway, gateway_subject(account, "SG", "Singapore", 1.3521, 103.8198)},
      {60 * 4, :portal, admin_subj},
      {60 * 6, :client, subject_at(unpriv_subj, "FR", "Paris", 48.8566, 2.3522)},
      {60 * 12, :portal, admin_subj},
      {60 * 18, :client, subject_at(unpriv_subj, "JP", "Tokyo", 35.6762, 139.6503)},
      {60 * 24, :gateway, gateway_subject(account, "US-CA", "San Francisco", 37.7749, -122.4194)},
      {60 * 30, :portal, subject_at(admin_subj, "AU", "Sydney", -33.8688, 151.2093)},
      {60 * 40, :client, subject_at(unpriv_subj, "NL", "Amsterdam", 52.3676, 4.9041)},
      {60 * 48, :portal, admin_subj}
    ]

    rows =
      Enum.map(specs, fn {mins_ago, context, subject} ->
        timestamp = DateTime.add(now, -mins_ago * 60, :second)

        %{
          log_id: LogId.build_session_log(),
          account_id: account.id,
          timestamp: timestamp,
          context: context,
          subject: subject
        }
      end)

    Repo.insert_all(SessionLog, rows)
  end

  defp seed_api_request_logs(account, api_actor, api_token_id, now) do
    uas = [
      "curl/8.7.1",
      "terraform/1.6.0 (+https://www.terraform.io) terraform-provider-firezone/0.5.0",
      "python-requests/2.31.0",
      "Go-http-client/1.1",
      "gh/2.42.0"
    ]

    # {method, path, size}
    endpoints = [
      {"GET", "/account", nil},
      {"GET", "/resources", nil},
      {"GET", "/resources?limit=25", nil},
      {"POST", "/resources", 412},
      {"GET", "/policies", nil},
      {"POST", "/policies", 218},
      {"PATCH", "/policies/#{Ecto.UUID.generate()}", 96},
      {"GET", "/actors", nil},
      {"GET", "/actors?limit=25", nil},
      {"GET", "/groups", nil},
      {"POST", "/groups", 84},
      {"DELETE", "/groups/#{Ecto.UUID.generate()}", nil},
      {"GET", "/sites", nil},
      {"GET", "/clients", nil},
      {"GET", "/logs?type=change", nil},
      {"GET", "/logs?type=session", nil},
      {"GET", "/logs?type=api_request", nil},
      {"GET", "/email_otp_auth_providers", nil},
      {"GET", "/oidc_auth_providers", nil},
      {"GET", "/entra_directories", nil}
    ]

    locations = [
      %Postgrex.INET{address: {8, 8, 8, 8}},
      %Postgrex.INET{address: {185, 199, 108, 153}},
      %Postgrex.INET{address: {203, 13, 32, 10}}
    ]

    location_meta = [
      {"US-CA", "Mountain View", 37.4056, -122.0775},
      {"NL", "Amsterdam", 52.3676, 4.9041},
      {"AU", "Sydney", -33.8688, 151.2093}
    ]

    rows =
      for i <- 0..49 do
        {method, path, size} = Enum.at(endpoints, rem(i, length(endpoints)))
        ua = Enum.at(uas, rem(i, length(uas)))
        idx = rem(i, length(locations))
        ip = Enum.at(locations, idx)
        {region, city, lat, lon} = Enum.at(location_meta, idx)
        # Spread across ~4 days, tighter density in the last hour.
        secs_ago = trunc(:math.pow(i + 1, 1.7) * 60)

        %{
          log_id: LogId.build_api_request_log(),
          account_id: account.id,
          actor_id: api_actor.id,
          api_token_id: api_token_id,
          method: method,
          path: path,
          content_length: size,
          request_id: "seed-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
          user_agent: ua,
          ip: ip,
          ip_region: region,
          ip_city: city,
          ip_lat: lat,
          ip_lon: lon,
          inserted_at: DateTime.add(now, -secs_ago, :second)
        }
      end

    Repo.insert_all(APIRequestLog, rows)
  end

  # Rewrites subject IP/geo to a new location so successive session logs from
  # the same actor look plausibly geo-distributed.
  defp subject_at(base_subject, region, city, lat, lon) do
    base_subject
    |> Map.put("ip", ip_from_geo(lat, lon))
    |> Map.put("ip_region", region)
    |> Map.put("ip_city", city)
    |> Map.put("ip_lat", lat)
    |> Map.put("ip_lon", lon)
  end

  defp gateway_subject(account, region, city, lat, lon) do
    %{
      "actor_id" => nil,
      "actor_name" => "Gateway",
      "actor_email" => nil,
      "actor_type" => nil,
      "auth_provider_id" => nil,
      "account_id" => account.id,
      "ip" => ip_from_geo(lat, lon),
      "ip_region" => region,
      "ip_city" => city,
      "ip_lat" => lat,
      "ip_lon" => lon,
      "user_agent" => @ua_gateway
    }
  end

  # Row-snapshot helpers. Mirror the shape the WAL replicator captures so
  # change_log diffs render every column, not just the one that changed.
  # Callers supply keyword overrides for the fields they care about.
  defp policy_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "Engineering full access",
        "description" => "Engineering full access",
        "actor_group_id" => Ecto.UUID.generate(),
        "resource_id" => Ecto.UUID.generate(),
        "conditions" => [],
        "disabled_at" => nil,
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp resource_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "Prod DB",
        "address" => "10.0.0.42",
        "type" => "cidr",
        "filters" => [],
        "site_id" => Ecto.UUID.generate(),
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp group_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "Engineering",
        "type" => "manual",
        "provider_id" => nil,
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp actor_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "Alex",
        "email" => "alex@example.com",
        "type" => "account_user",
        "disabled_at" => nil,
        "allow_email_otp_sign_in" => false,
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp provider_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "Google",
        "adapter" => "google_workspace",
        "disabled_at" => nil,
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp client_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "MacBook",
        "actor_id" => Ecto.UUID.generate(),
        "type" => "client",
        "ipv4" => "100.64.0.5",
        "ipv6" => "fd00:2021:1111::5",
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp site_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "us-east-2",
        "created_at" => "2026-07-01T09:00:00Z",
        "updated_at" => "2026-07-09T12:34:56Z"
      },
      stringify(overrides)
    )
  end

  defp gateway_token_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "name" => "us-east-2 provisioning",
        "site_id" => Ecto.UUID.generate(),
        "created_at" => "2026-07-01T09:00:00Z",
        "expires_at" => "2027-07-01T09:00:00Z"
      },
      stringify(overrides)
    )
  end

  defp api_token_row(overrides) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "account_id" => Ecto.UUID.generate(),
        "actor_id" => Ecto.UUID.generate(),
        "name" => "terraform-ci",
        "created_at" => "2026-07-01T09:00:00Z",
        "expires_at" => "2027-07-01T09:00:00Z",
        "last_seen_at" => nil
      },
      stringify(overrides)
    )
  end

  defp stringify(overrides) do
    Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
  end

  # Deterministic-but-plausible looking source IP derived from lat/lon so each
  # geo pin gets its own address without a real MaxMind lookup.
  defp ip_from_geo(lat, lon) do
    a = Integer.mod(trunc(lat * 3), 223) + 1
    b = Integer.mod(trunc(lon * 3), 254) + 1
    c = Integer.mod(trunc(lat * lon * 7), 254) + 1
    d = Integer.mod(trunc(lat + lon + 100), 254) + 1
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp subject_map_from_authentication(%Authentication.Subject{} = s, region, city, lat, lon) do
    %{
      "actor_id" => s.actor.id,
      "actor_name" => s.actor.name,
      "actor_email" => s.actor.email,
      "actor_type" => to_string(s.actor.type),
      "auth_provider_id" => nil,
      "ip" => ip_from_geo(lat, lon),
      "ip_region" => region,
      "ip_city" => city,
      "ip_lat" => lat,
      "ip_lon" => lon,
      "user_agent" => s.context.user_agent
    }
  end


  # ---------------------------------------------------------------------------
  # Device posture inventory
  # ---------------------------------------------------------------------------

  # One fleet of people, reused across every provider, so the same person shows
  # up consistently wherever a device of theirs is inventoried.
  @posture_people [
    {"Alice Nguyen", "alice"},
    {"Ben Okafor", "ben"},
    {"Carla Ruiz", "carla"},
    {"Dmitri Volkov", "dmitri"},
    {"Elena Petrova", "elena"},
    {"Farhan Ahmed", "farhan"},
    {"Grace Lim", "grace"},
    {"Hugo Martins", "hugo"},
    {"Ingrid Sorensen", "ingrid"},
    {"Jonas Weber", "jonas"},
    {"Keiko Tanaka", "keiko"},
    {"Liam Doyle", "liam"},
    {"Maya Shah", "maya"},
    {"Noah Brenner", "noah"},
    {"Olivia Fontaine", "olivia"},
    {"Priya Raman", "priya"}
  ]

  @posture_domain "contoso.com"

  # Serial numbers are generated rather than listed so the fleet can grow
  # without hand-writing plausible strings. The alphabet drops I and O, which
  # is what real serials do so they cannot be confused with 1 and 0.
  @serial_alphabet ~c"0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"

  defp seed_device_posture(account, clients) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    intune =
      create_posture_provider(account, :intune, "Contoso Intune", Intune.PostureProvider, %{
        tenant_id: "8a1e5f22-4c7b-4a10-9c8e-2f3b6d5a71c4",
        is_verified: true,
        synced_at: DateTime.add(now, -11, :minute)
      })

    iru =
      create_posture_provider(account, :iru, "Iru Apple Fleet", Iru.PostureProvider, %{
        subdomain: "contoso",
        region: :us,
        api_token: "iru_dev_api_token",
        is_verified: true,
        synced_at: DateTime.add(now, -23, :minute)
      })

    defender =
      create_posture_provider(
        account,
        :defender,
        "Defender for Endpoint",
        Defender.PostureProvider,
        %{
          tenant_id: "8a1e5f22-4c7b-4a10-9c8e-2f3b6d5a71c4",
          is_verified: true,
          synced_at: DateTime.add(now, -7, :minute)
        }
      )

    santa =
      create_posture_provider(account, :santa, "Santa Workshop", Santa.PostureProvider, %{
        api_url: "https://contoso.workshop.cloud",
        api_key: "npsws_sk_dev_seed_key",
        is_verified: true,
        synced_at: DateTime.add(now, -4, :minute)
      })

    sentinelone =
      create_posture_provider(
        account,
        :sentinelone,
        "SentinelOne Production",
        SentinelOne.PostureProvider,
        %{
          management_url: "https://contoso.sentinelone.net",
          api_token: "s1_dev_api_token",
          is_verified: true,
          synced_at: DateTime.add(now, -2, :minute)
        }
      )

    # The identifiers the seeded certificates attest. Each is also written into
    # the provider row that should match on it, so the Inventory tab of a
    # seeded Client demonstrates one rung of the matching ladder.
    issuer = posture_issuer_der("Contoso Device CA")
    admin_intune_id = "5f3c1a90-7d24-4b8e-9a61-c0d2e4f68b31"
    surface_entra_id = "b71d2e88-3f56-4c09-8ad4-6e19f7c2a5d0"
    iphone_iru_id = "0c9a4f61-8b23-4de7-95f0-31a8c6b74e29"

    admin = attest_posture_client(clients.admin_laptop, admin_intune_id, "FVFHF246Q72Z", issuer, "3A7F2C91", now)
    surface = attest_posture_client(clients.user_surface, surface_entra_id, "046120283253", issuer, "5B1D8E04", now)
    iphone = attest_posture_client(clients.user_iphone, iphone_iru_id, "DX3QK7WPL9GH", issuer, "9E4C6A72", now)

    # The rendering station never attested anything, so the only serial it has
    # is the one it reports about itself. Its SentinelOne match is the case the
    # panel cautions about.
    rendering = Repo.update!(change(clients.user_rendering_station, device_serial: "PF0J4KX2"))

    # Valid, revoked, and unknown, so the panel's three certificate states are
    # all reachable from seeded data.
    Repo.insert!(%Portal.OcspStatus{
      account_id: account.id,
      issuer: issuer,
      serial: admin.last_attested_cert_serial,
      status: "good",
      produced_at: DateTime.add(now, -90, :minute) |> DateTime.truncate(:second),
      this_update: DateTime.add(now, -90, :minute) |> DateTime.truncate(:second),
      next_update: DateTime.add(now, 3, :day) |> DateTime.truncate(:second),
      updated_at: now
    })

    Repo.insert!(%Portal.CrlRevocation{
      account_id: account.id,
      issuer: issuer,
      serial: iphone.last_attested_cert_serial,
      distribution_point: "http://crl.contoso.com/device-ca.crl",
      revoked_at: DateTime.add(now, -2, :day) |> DateTime.truncate(:second),
      reason: "keyCompromise"
    })

    seed_intune_devices(account, intune, now, admin, surface)
    seed_iru_devices(account, iru, now, iphone)
    seed_defender_devices(account, defender, now, surface)
    seed_santa_devices(account, santa, now, admin)
    seed_sentinelone_devices(account, sentinelone, now, admin, rendering)

    IO.puts("Device posture providers created")
    IO.puts("  Contoso Intune, Iru Apple Fleet, Defender for Endpoint, Santa Workshop, SentinelOne Production")
    IO.puts("  #{admin.name}: attested, matched by MDM device id")
    IO.puts("  #{surface.name}: attested, matched by Entra device id")
    IO.puts("  #{iphone.name}: attested with a revoked certificate")
    IO.puts("  #{rendering.name}: unattested, matched by the serial it reports")
    IO.puts("")
  end

  # Seeded providers are disabled on purpose. Their credentials are made up, so
  # leaving them enabled would have every scheduler run fire a sync at the real
  # vendor API and fail. Disabled keeps the rows and the devices they own
  # visible, which is the whole point of seeding them.
  defp create_posture_provider(account, type, name, typed_module, typed_attrs) do
    id = Ecto.UUID.generate()

    typed_attrs =
      Map.merge(typed_attrs, %{
        is_disabled: true,
        disabled_reason: "Seeded for local development"
      })

    shared =
      %Portal.PostureProvider{}
      |> change(%{id: id, account_id: account.id, type: type, name: name})
      |> Portal.PostureProvider.changeset()
      |> Repo.insert!()

    attrs = Map.merge(typed_attrs, %{id: id, account_id: account.id, name: name})

    typed_module
    |> struct(posture_provider: shared)
    |> cast(attrs, Map.keys(attrs))
    |> typed_module.changeset()
    |> Repo.insert!()
  end

  # Writes what a client certificate would have proved about this device onto
  # the row, so the seeded Clients cover every rung of the matching ladder.
  defp attest_posture_client(client, mdm_device_id, serial, issuer, cert_serial, now) do
    client
    |> change(
      device_serial: serial,
      last_attested_device_serial: serial,
      last_attested_mdm_device_id: mdm_device_id,
      last_attested_cert_serial: cert_serial,
      last_attested_cert_fingerprint: posture_fingerprint(cert_serial),
      last_attested_cert_issuer: issuer,
      last_attested_at: DateTime.add(now, -3, :hour)
    )
    |> Repo.update!()
  end

  defp seed_intune_devices(account, provider, now, admin, surface) do
    matched = [
      %{
        intune_id: admin.last_attested_mdm_device_id,
        device_name: "ENG-MBP-014",
        serial_number: admin.last_attested_device_serial,
        operating_system: "macOS",
        os_version: "15.6.1",
        model: "MacBook Pro 16-inch (M3 Max, 2024)",
        manufacturer: "Apple",
        device_enrollment_type: "appleBulkWithUser",
        compliance_state: "compliant",
        person: 0
      },
      %{
        intune_id: "1d84b7e0-92af-4c35-b6d1-70e5a3c8f429",
        entra_device_id: surface.last_attested_mdm_device_id,
        device_name: "ENG-SURFACE-07",
        serial_number: surface.last_attested_device_serial,
        operating_system: "Windows",
        os_version: "10.0.26100.2894",
        model: "Surface Laptop 6",
        manufacturer: "Microsoft Corporation",
        device_enrollment_type: "windowsAzureADJoin",
        compliance_state: "compliant",
        person: 1
      },
      %{
        intune_id: "6b02f5c4-1e79-4a63-8d50-92fb37e6c184",
        device_name: "ENG-WIN-042",
        serial_number: dell_tag(42),
        operating_system: "Windows",
        os_version: "10.0.26100.2894",
        model: "Latitude 7450",
        manufacturer: "Dell Inc.",
        device_enrollment_type: "windowsAzureADJoin",
        compliance_state: "noncompliant",
        person: 2
      }
    ]

    generated =
      for i <- 1..15 do
        {os, version, model, manufacturer, enrollment, serial} = intune_hardware(i)

        %{
          intune_id: Ecto.UUID.generate(),
          device_name: "#{intune_prefix(os)}-#{String.pad_leading(Integer.to_string(100 + i), 3, "0")}",
          serial_number: serial,
          operating_system: os,
          os_version: version,
          model: model,
          manufacturer: manufacturer,
          device_enrollment_type: enrollment,
          compliance_state: Enum.at(~w[compliant compliant compliant noncompliant inGracePeriod], rem(i, 5)),
          person: i + 2
        }
      end

    for {row, i} <- Enum.with_index(matched ++ generated) do
      {display_name, login} = posture_person(row.person)

      %Intune.Device{}
      |> Intune.Device.changeset(%{
        account_id: account.id,
        posture_provider_id: provider.id,
        intune_id: row.intune_id,
        device_name: row.device_name,
        managed_device_name: "#{login}_#{String.replace(row.model, " ", "")}_#{8 + rem(i, 4)}/#{1 + rem(i, 28)}/2026",
        serial_number: row.serial_number,
        entra_device_id: Map.get(row, :entra_device_id, Ecto.UUID.generate()),
        enrollment_profile_name: "Corporate Devices",
        device_category_display_name: "Engineering",
        user_id: Ecto.UUID.generate(),
        user_principal_name: "#{login}@#{@posture_domain}",
        user_display_name: display_name,
        email_address: "#{login}@#{@posture_domain}",
        operating_system: row.operating_system,
        os_version: row.os_version,
        model: row.model,
        manufacturer: row.manufacturer,
        udid: Ecto.UUID.generate(),
        wifi_mac_address: posture_mac(i),
        ethernet_mac_address: posture_mac(i + 128),
        total_storage_space_bytes: 494_384_795_648 * (1 + rem(i, 3)),
        free_storage_space_bytes: 121_856_204_800 + i * 1_073_741_824,
        physical_memory_bytes: 17_179_869_184 * (1 + rem(i, 2)),
        compliance_state: row.compliance_state,
        management_state: "managed",
        management_agent: "mdm",
        managed_device_owner_type: if(rem(i, 7) == 0, do: "personal", else: "company"),
        device_enrollment_type: row.device_enrollment_type,
        device_registration_state: "registered",
        partner_reported_threat_state: "unknown",
        jail_broken: "False",
        is_encrypted: rem(i, 9) != 0,
        is_supervised: row.operating_system in ["iOS", "macOS"],
        entra_registered: true,
        enrolled_at: DateTime.add(now, -(120 + i * 9), :day),
        last_sync_at: DateTime.add(now, -(17 + i * 13), :minute),
        management_certificate_expires_at: DateTime.add(now, 240 - i, :day),
        synced_at: provider.synced_at
      })
      |> Repo.insert!()
    end
  end

  defp seed_iru_devices(account, provider, now, iphone) do
    matched = [
      %{
        iru_id: iphone.last_attested_mdm_device_id,
        device_name: "ENG-IPHONE-02",
        serial_number: iphone.last_attested_device_serial,
        platform: "iPhone",
        os_name: "iOS",
        os_version: "18.6",
        model: "iPhone 16 Pro",
        model_identifier: "iPhone17,1",
        blueprint_name: "Mobile Standard",
        person: 2
      }
    ]

    generated =
      for i <- 1..11 do
        {platform, os_name, version, model, identifier} = iru_hardware(i)

        %{
          iru_id: Ecto.UUID.generate(),
          device_name: "#{posture_person(i + 3) |> elem(1)}-#{String.downcase(String.replace(model, " ", "-"))}",
          serial_number: apple_serial(i * 31),
          platform: platform,
          os_name: os_name,
          os_version: version,
          model: model,
          model_identifier: identifier,
          blueprint_name: Enum.at(["Standard Laptop", "Engineering Laptop", "Mobile Standard"], rem(i, 3)),
          person: i + 3
        }
      end

    for {row, i} <- Enum.with_index(matched ++ generated) do
      {display_name, login} = posture_person(row.person)
      mac? = row.platform == "Mac"

      %Iru.Device{}
      |> Iru.Device.changeset(%{
        account_id: account.id,
        posture_provider_id: provider.id,
        iru_id: row.iru_id,
        device_name: row.device_name,
        serial_number: row.serial_number,
        platform: row.platform,
        os_name: row.os_name,
        os_version: row.os_version,
        display_os_version: row.os_version,
        os_build: "24G8#{rem(i, 10)}",
        model: row.model,
        model_name: row.model,
        model_identifier: row.model_identifier,
        device_family: row.platform,
        device_capacity_gb: 256.0 * (1 + rem(i, 3)),
        host_name: row.device_name,
        local_hostname: row.device_name,
        apple_silicon: true,
        user_id: Ecto.UUID.generate(),
        user_name: display_name,
        user_email: "#{login}@#{@posture_domain}",
        user_is_archived: false,
        asset_tag: "CT-#{String.pad_leading(Integer.to_string(4200 + i), 4, "0")}",
        blueprint_id: Ecto.UUID.generate(),
        blueprint_name: row.blueprint_name,
        mdm_enabled: true,
        agent_installed: mac?,
        agent_version: if(mac?, do: "5.4.1", else: nil),
        is_missing: false,
        is_removed: false,
        first_enrolled_at: DateTime.add(now, -(200 + i * 11), :day),
        last_enrolled_at: DateTime.add(now, -(200 + i * 11), :day),
        last_check_in_at: DateTime.add(now, -(9 + i * 17), :minute),
        tags: ["engineering"],
        inventory_collected_at: DateTime.add(now, -(30 + i), :minute),
        filevault_enabled: mac? and rem(i, 8) != 0,
        filevault_key_type: if(mac?, do: "Personal", else: nil),
        filevault_key_escrowed: mac?,
        filevault_collected_at: if(mac?, do: DateTime.add(now, -(30 + i), :minute), else: nil),
        firewall_enabled: mac?,
        firewall_stealth_mode: mac? and rem(i, 3) == 0,
        firewall_collected_at: if(mac?, do: DateTime.add(now, -(30 + i), :minute), else: nil),
        gatekeeper_enabled: mac?,
        gatekeeper_trusted_developers: mac?,
        xprotect_version: if(mac?, do: "5312", else: nil),
        gatekeeper_collected_at: if(mac?, do: DateTime.add(now, -(30 + i), :minute), else: nil),
        sip_enabled: mac?,
        ssv_enabled: mac?,
        bootstrap_token_escrowed: mac?,
        secure_boot_level: if(mac?, do: "full", else: nil),
        startup_settings_collected_at: if(mac?, do: DateTime.add(now, -(30 + i), :minute), else: nil),
        activation_lock_supported: true,
        device_activation_lock_enabled: rem(i, 4) == 0,
        activation_lock_collected_at: DateTime.add(now, -(30 + i), :minute),
        synced_at: provider.synced_at
      })
      |> Repo.insert!()
    end
  end

  defp seed_defender_devices(account, provider, now, surface) do
    matched = [
      %{
        defender_id: "2f8c1b47ad9e05c3716b4d820ea935f1c6d704b8",
        entra_device_id: surface.last_attested_mdm_device_id,
        computer_dns_name: "eng-surface-07.#{@posture_domain}",
        os_platform: "Windows11",
        version: "24H2",
        os_build: 26_100,
        health_status: "Active",
        risk_score: "Low",
        exposure_level: "Low"
      }
    ]

    generated =
      for i <- 1..13 do
        {platform, version, build, health, risk, exposure} = defender_posture(i)

        %{
          defender_id: Base.encode16(:crypto.hash(:sha, "defender-seed-#{i}"), case: :lower),
          entra_device_id: Ecto.UUID.generate(),
          computer_dns_name: "#{defender_prefix(platform)}-#{String.pad_leading(Integer.to_string(200 + i), 3, "0")}.#{@posture_domain}",
          os_platform: platform,
          version: version,
          os_build: build,
          health_status: health,
          risk_score: risk,
          exposure_level: exposure
        }
      end

    for {row, i} <- Enum.with_index(matched ++ generated) do
      %Defender.Device{}
      |> Defender.Device.changeset(%{
        account_id: account.id,
        posture_provider_id: provider.id,
        defender_id: row.defender_id,
        computer_dns_name: row.computer_dns_name,
        entra_device_id: row.entra_device_id,
        entra_joined: true,
        machine_tags: ["engineering", "corp-managed"],
        os_platform: row.os_platform,
        version: row.version,
        os_build: row.os_build,
        os_processor: "x64",
        os_architecture: "64-bit",
        last_ip_address: "10.20.#{rem(i, 250)}.#{10 + rem(i * 7, 200)}",
        last_external_ip_address: "203.0.113.#{10 + rem(i * 3, 200)}",
        agent_version: "10.8760.26100.#{2000 + i}",
        health_status: row.health_status,
        onboarding_status: "Onboarded",
        managed_by: "Intune",
        managed_by_status: "Success",
        risk_score: row.risk_score,
        exposure_level: row.exposure_level,
        device_value: if(rem(i, 6) == 0, do: "High", else: "Normal"),
        rbac_group_id: "140",
        rbac_group_name: "Engineering",
        is_potential_duplication: false,
        is_excluded: false,
        ip_addresses: [
          %{
            "ipAddress" => "10.20.#{rem(i, 250)}.#{10 + rem(i * 7, 200)}",
            "macAddress" => String.replace(posture_mac(i), ":", ""),
            "operationalStatus" => "Up",
            "type" => "Ethernet"
          }
        ],
        first_seen_at: DateTime.add(now, -(180 + i * 7), :day),
        last_seen_at: DateTime.add(now, -(5 + i * 11), :minute),
        synced_at: provider.synced_at
      })
      |> Repo.insert!()
    end
  end

  defp seed_santa_devices(account, provider, now, admin) do
    matched = [
      %{
        santa_id: "9C1F4A72-3B6D-4E80-A5C9-27D0F8B1E463",
        hostname: "eng-mbp-014",
        serial_number: admin.last_attested_device_serial,
        machine_model: "Mac16,7",
        os_version: "15.6.1",
        client_mode: "LOCKDOWN",
        person: 0
      }
    ]

    generated =
      for i <- 1..9 do
        %{
          santa_id: String.upcase(Ecto.UUID.generate()),
          hostname: "#{posture_person(i) |> elem(1)}-mbp",
          serial_number: apple_serial(i * 17),
          machine_model: Enum.at(~w[Mac16,7 Mac15,3 Mac14,2 MacBookPro18,3], rem(i, 4)),
          os_version: Enum.at(~w[15.6.1 15.5 14.7.2], rem(i, 3)),
          client_mode: if(rem(i, 3) == 0, do: "MONITOR", else: "LOCKDOWN"),
          person: i
        }
      end

    for {row, i} <- Enum.with_index(matched ++ generated) do
      {_display_name, login} = posture_person(row.person)

      %Santa.Device{}
      |> Santa.Device.changeset(%{
        account_id: account.id,
        posture_provider_id: provider.id,
        santa_id: row.santa_id,
        hostname: row.hostname,
        serial_number: row.serial_number,
        machine_model: row.machine_model,
        os_version: row.os_version,
        os_build: "24G8#{rem(i, 10)}",
        os_type: "OS_TYPE_MACOS",
        sip_status: 1,
        primary_user: "#{login}@#{@posture_domain}",
        primary_user_locked: false,
        primary_user_groups: ["engineering"],
        santa_version: "2026.7",
        santanetd_version: "2026.7",
        last_seen_client_mode: row.client_mode,
        configured_client_mode: row.client_mode,
        last_sync_at: DateTime.add(now, -(6 + i * 13), :minute),
        rule_sync_at: DateTime.add(now, -(6 + i * 13), :minute),
        last_preflight_at: DateTime.add(now, -(6 + i * 13), :minute),
        last_preflight_ip: "10.30.#{rem(i, 250)}.#{20 + rem(i * 5, 200)}",
        tags: ["engineering"],
        tags_locked: false,
        tags_truncated: false,
        first_seen_at: DateTime.add(now, -(150 + i * 8), :day),
        synced_at: provider.synced_at
      })
      |> Repo.insert!()
    end
  end

  defp seed_sentinelone_devices(account, provider, now, admin, rendering) do
    matched = [
      %{
        computer_name: "ENG-MBP-014",
        serial_number: admin.last_attested_device_serial,
        model_name: "MacBookPro16,7",
        machine_type: "laptop",
        os_name: "macOS",
        os_revision: "15.6.1",
        os_type: "macos",
        network_status: "connected",
        person: 0
      },
      %{
        computer_name: "ENG-RENDER-01",
        serial_number: rendering.device_serial,
        model_name: "ThinkStation P620",
        machine_type: "desktop",
        os_name: "Ubuntu",
        os_revision: "24.04.2 LTS",
        os_type: "linux",
        network_status: "connected",
        person: 3
      }
    ]

    generated =
      for i <- 1..13 do
        {os_name, revision, os_type, model, machine_type, serial} = sentinelone_hardware(i)

        %{
          computer_name: "#{sentinelone_prefix(os_type)}-#{String.pad_leading(Integer.to_string(300 + i), 3, "0")}",
          serial_number: serial,
          model_name: model,
          machine_type: machine_type,
          os_name: os_name,
          os_revision: revision,
          os_type: os_type,
          network_status: if(rem(i, 6) == 0, do: "disconnected", else: "connected"),
          person: i + 4
        }
      end

    for {row, i} <- Enum.with_index(matched ++ generated) do
      {_display_name, login} = posture_person(row.person)
      infected? = rem(i, 11) == 0 and i > 0

      %SentinelOne.Device{}
      |> SentinelOne.Device.changeset(%{
        account_id: account.id,
        posture_provider_id: provider.id,
        uuid: Ecto.UUID.generate(),
        sentinelone_id: Integer.to_string(1_845_000_000_000_000_000 + i),
        sentinelone_account_id: "1845000000000000001",
        account_name: "Contoso",
        site_id: "1845000000000000002",
        site_name: "Default site",
        group_id: "1845000000000000003",
        group_name: "Engineering",
        computer_name: row.computer_name,
        serial_number: row.serial_number,
        model_name: row.model_name,
        machine_type: row.machine_type,
        domain: @posture_domain,
        os_name: row.os_name,
        os_revision: row.os_revision,
        os_type: row.os_type,
        os_arch: "64 bit",
        os_username: login,
        last_logged_in_user_name: login,
        agent_version: "24.2.3.#{270 + rem(i, 9)}",
        total_memory: 16_384 * (1 + rem(i, 2)),
        cpu_count: 1,
        core_count: Enum.at([8, 10, 12, 16], rem(i, 4)),
        cpu_id: "Apple M3 Max",
        external_ip: "203.0.113.#{20 + rem(i * 5, 200)}",
        network_status: row.network_status,
        is_active: row.network_status == "connected",
        is_up_to_date: rem(i, 7) != 0,
        infected: infected?,
        active_threats: if(infected?, do: 1, else: 0),
        threat_reboot_required: false,
        encrypted_applications: true,
        firewall_enabled: true,
        scan_status: "finished",
        scan_started_at: DateTime.add(now, -(2 + i), :day),
        scan_finished_at: DateTime.add(now, -(2 + i), :day) |> DateTime.add(41, :minute),
        last_successful_scan_at: DateTime.add(now, -(2 + i), :day),
        mitigation_mode: "protect",
        mitigation_mode_suspicious: "detect",
        is_pending_uninstall: false,
        is_uninstalled: false,
        is_decommissioned: false,
        registered_at: DateTime.add(now, -(160 + i * 6), :day),
        last_active_at: DateTime.add(now, -(3 + i * 9), :minute),
        network_interfaces: [
          %{
            "id" => "1845000000000#{String.pad_leading(Integer.to_string(i), 6, "0")}",
            "name" => "en0",
            "physical" => posture_mac(i),
            "inet" => ["10.40.#{rem(i, 250)}.#{30 + rem(i * 3, 200)}"]
          }
        ],
        tags: [],
        synced_at: provider.synced_at
      })
      |> Repo.insert!()
    end
  end

  defp posture_person(index) do
    Enum.at(@posture_people, rem(index, length(@posture_people)))
  end

  # A DER-encoded X.509 name, which is how the portal stores a certificate
  # issuer: a serial only identifies a certificate together with who issued it.
  defp posture_issuer_der(common_name) do
    :public_key.der_encode(
      :Name,
      {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, common_name}}]]}
    )
  end

  defp posture_fingerprint(cert_serial) do
    :sha256
    |> :crypto.hash(cert_serial)
    |> Base.encode16(case: :lower)
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &List.to_string/1)
  end

  defp posture_mac(index) do
    for offset <- 0..5 do
      :io_lib.format("~2.16.0b", [rem(index * 37 + offset * 61 + 16, 256)]) |> List.to_string()
    end
    |> Enum.join(":")
  end

  defp apple_serial(index), do: "C02" <> serial_chunk(index * 7919, 9)
  defp dell_tag(index), do: serial_chunk(index * 104_729, 7)
  defp lenovo_serial(index), do: "PF" <> serial_chunk(index * 65_537, 6)

  defp serial_chunk(value, size) do
    base = length(@serial_alphabet)

    {_remaining, characters} =
      Enum.reduce(1..size, {value, []}, fn _position, {remaining, acc} ->
        {div(remaining, base), [Enum.at(@serial_alphabet, rem(remaining, base)) | acc]}
      end)

    List.to_string(characters)
  end

  defp intune_hardware(index) do
    case rem(index, 4) do
      0 ->
        {"Windows", "10.0.26100.2894", "Latitude 7450", "Dell Inc.", "windowsAzureADJoin",
         dell_tag(index)}

      1 ->
        {"macOS", "15.6.1", "MacBook Air 15-inch (M3, 2024)", "Apple", "appleBulkWithUser",
         apple_serial(index)}

      2 ->
        {"iOS", "18.6", "iPhone 15", "Apple", "appleUserEnrollment", apple_serial(index * 3)}

      _ ->
        {"Windows", "10.0.22631.4602", "ThinkPad X1 Carbon Gen 12", "LENOVO", "windowsAzureADJoin",
         lenovo_serial(index)}
    end
  end

  defp intune_prefix("Windows"), do: "ENG-WIN"
  defp intune_prefix("macOS"), do: "ENG-MAC"
  defp intune_prefix("iOS"), do: "ENG-IOS"
  defp intune_prefix(_other), do: "ENG-DEV"

  defp iru_hardware(index) do
    case rem(index, 3) do
      0 -> {"Mac", "macOS", "15.6.1", "MacBook Pro 14-inch", "Mac16,1"}
      1 -> {"Mac", "macOS", "14.7.2", "MacBook Air", "Mac14,2"}
      _ -> {"iPad", "iPadOS", "18.6", "iPad Pro 11-inch", "iPad16,3"}
    end
  end

  defp defender_posture(index) do
    case rem(index, 4) do
      0 -> {"Windows11", "24H2", 26_100, "Active", "None", "Low"}
      1 -> {"Windows10", "22H2", 19_045, "Active", "Low", "Medium"}
      2 -> {"macOS", "15.6.1", 0, "Active", "Medium", "Medium"}
      _ -> {"Linux", "24.04", 0, "Inactive", "None", "Low"}
    end
  end

  defp defender_prefix("Windows11"), do: "eng-win11"
  defp defender_prefix("Windows10"), do: "eng-win10"
  defp defender_prefix("macOS"), do: "eng-mac"
  defp defender_prefix(_other), do: "eng-linux"

  defp sentinelone_hardware(index) do
    case rem(index, 4) do
      0 ->
        {"Windows 11 Pro", "24H2", "windows", "Latitude 7450", "laptop", dell_tag(index * 11)}

      1 ->
        {"macOS", "15.6.1", "macos", "MacBookPro16,1", "laptop", apple_serial(index * 13)}

      2 ->
        {"Ubuntu", "24.04.2 LTS", "linux", "PowerEdge R660", "server", dell_tag(index * 19)}

      _ ->
        {"Windows Server 2022", "21H2", "windows", "PowerEdge R750", "server",
         dell_tag(index * 23)}
    end
  end

  defp sentinelone_prefix("windows"), do: "ENG-WIN"
  defp sentinelone_prefix("macos"), do: "ENG-MAC"
  defp sentinelone_prefix(_other), do: "ENG-LNX"

  def seed do
    # Seeds can be run both with MIX_ENV=prod and MIX_ENV=test, for test env we don't have
    # an adapter configured and creation of email provider will fail, so we will override it here.
    System.put_env("OUTBOUND_EMAIL_ADAPTER", "Elixir.Swoosh.Adapters.AzureCommunicationServices")

    # Ensure seeds are deterministic
    :rand.seed(:exsss, {1, 2, 3})

    Repo.query!(
      """
      INSERT INTO features (feature, enabled)
      VALUES ('trust_anchors', true), ('device_posture', true)
      ON CONFLICT (feature) DO UPDATE SET enabled = true
      """
    )

    account =
      %Account{}
      |> cast(
        %{
          name: "Firezone Account",
          legal_name: "Firezone Account",
          slug: "firezone",
          key: Account.new_key(),
          config: %{
            search_domain: "httpbin.search.test"
          }
        },
        [:name, :legal_name, :slug, :key]
      )
      |> cast_embed(:config)
      |> put_change(:id, "c89bcc8c-9392-4dae-a40d-888aef6d28e0")
      |> put_change(:features, %{
        policy_conditions: true,
        idp_sync: true,
        internet_resource: true,
        iceless: System.get_env("FEATURE_ICELESS_ENABLED") == "true",
        log_sinks: true,
        device_posture: true
      })
      |> put_change(:metadata, %{
        stripe: %{
          customer_id: "cus_PZKIfcHB6SSBA4",
          subscription_id: "sub_1OkGm2ADeNU9NGxvbrCCw6m3",
          product_name: "Enterprise",
          billing_email: "fin@firez.one",
          support_type: "email"
        }
      })
      |> put_change(:limits, %{
        users_count: 100,
        monthly_active_users_count: 100,
        service_accounts_count: 10,
        sites_count: 3,
        account_admin_users_count: 5
      })
      |> Repo.insert!()

    other_account =
      %Account{}
      |> cast(
        %{
          name: "Other Corp Account",
          legal_name: "Other Corp Account",
          slug: "not_firezone",
          key: Account.new_key()
        },
        [:name, :legal_name, :slug, :key]
      )
      |> put_change(:id, "9b9290bf-e1bc-4dd3-b401-511908262690")
      |> Repo.insert!()

    IO.puts("Created accounts: ")

    for item <- [account, other_account] do
      IO.puts("  #{item.id}: #{item.name}")
    end

    IO.puts("")

    internet_site =
      %Site{
        account_id: account.id,
        name: "Internet",
        managed_by: :system
      }
      |> Repo.insert!()

    other_internet_site =
      %Site{
        account_id: other_account.id,
        name: "Internet",
        managed_by: :system
      }
      |> Repo.insert!()

    # Create internet resources
    _internet_resource =
      %Resource{
        account_id: account.id,
        name: "Internet",
        type: :internet,
        site_id: internet_site.id
      }
      |> Repo.insert!()

    _other_internet_resource =
      %Resource{
        account_id: other_account.id,
        name: "Internet",
        type: :internet,
        site_id: other_internet_site.id
      }
      |> Repo.insert!()

    IO.puts("")

    everyone_group =
      %Group{
        account_id: account.id,
        name: "Everyone",
        type: :managed
      }
      |> Repo.insert!()

    _everyone_group =
      %Group{
        account_id: other_account.id,
        name: "Everyone",
        type: :managed
      }
      |> Repo.insert!()

    # Create auth providers for main account
    system_subject = %Authentication.Subject{
      account: account,
      actor: %Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
      credential: %Authentication.Credential{type: :token, id: Ecto.UUID.generate()},
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Authentication.Context{
        type: :client,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      }
    }

    {:ok, _email_provider} =
      create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, system_subject)

    {:ok, _x509_provider} =
      create_auth_provider(
        X509.AuthProvider,
        %{name: "X.509", context: :clients_only, is_disabled: true},
        system_subject
      )

    {:ok, userpass_provider} =
      create_auth_provider(
        Userpass.AuthProvider,
        %{name: "Username & Password"},
        system_subject
      )

    {:ok, _oidc_provider} =
      create_auth_provider(
        OIDC.AuthProvider,
        %{
          is_verified: true,
          name: "OIDC",
          issuer: "https://common.auth0.com",
          client_id: "CLIENT_ID",
          client_secret: "CLIENT_SECRET",
          discovery_document_uri: "https://common.auth0.com/.well-known/openid-configuration",
          scope: "openid email profile groups"
        },
        system_subject
      )

    {:ok, _google_provider} =
      create_auth_provider(
        Google.AuthProvider,
        %{
          is_verified: true,
          name: "Google",
          issuer: "https://accounts.google.com",
          domain: "firezone.dev"
        },
        system_subject
      )

    {:ok, _entra_provider} =
      create_auth_provider(
        Entra.AuthProvider,
        %{
          is_verified: true,
          name: "Entra",
          issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
          tenant_id: entra_tenant_id()
        },
        system_subject
      )

    # Create auth providers for other_account
    other_system_subject = %Authentication.Subject{
      account: other_account,
      actor: %Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
      credential: %Authentication.Credential{type: :portal_session, id: Ecto.UUID.generate()},
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Authentication.Context{
        type: :portal,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      }
    }

    {:ok, _other_email_provider} =
      create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, other_system_subject)

    {:ok, _other_x509_provider} =
      create_auth_provider(
        X509.AuthProvider,
        %{name: "X.509", context: :clients_only, is_disabled: true},
        other_system_subject
      )

    {:ok, _other_userpass_provider} =
      create_auth_provider(
        Userpass.AuthProvider,
        %{name: "Username & Password"},
        other_system_subject
      )

    unprivileged_actor_email = "firezone-unprivileged-1@localhost.local"
    admin_actor_email = "firezone@localhost.local"

    {:ok, unprivileged_actor} =
      %Actor{
        account_id: account.id,
        type: :account_user,
        name: "Firezone Unprivileged",
        email: unprivileged_actor_email,
        allow_email_otp_sign_in: true
      }
      |> Repo.insert()

    other_actors_with_emails =
      for i <- 1..10 do
        email = "user-#{i}@localhost.local"

        {:ok, actor} =
          Repo.insert(%Actor{
            account_id: account.id,
            type: :account_user,
            name: "Firezone Unprivileged #{i}",
            email: email
          })

        {actor, email}
      end

    other_actors = Enum.map(other_actors_with_emails, fn {actor, _email} -> actor end)

    {:ok, admin_actor} =
      Repo.insert(%Actor{
        account_id: account.id,
        type: :account_admin_user,
        name: "Firezone Admin",
        email: admin_actor_email,
        allow_email_otp_sign_in: true
      })

    {:ok, service_account_actor} =
      Repo.insert(%Actor{
        account_id: account.id,
        type: :service_account,
        name: "Backup Manager"
      })

    {:ok, pool_member_actor} =
      Repo.insert(%Actor{
        id: "cff1cf0e-0829-4b99-8ba7-0c09580386b4",
        account_id: account.id,
        type: :service_account,
        name: "CI Pool Member Actor"
      })

    # Set password on actors (no identity needed for userpass/email)
    password_hash = Crypto.hash(:argon2, "Firezone1234")

    unprivileged_actor =
      unprivileged_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    admin_actor =
      admin_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    # Create separate OIDC identity (different issuer)
    {:ok, _admin_actor_oidc_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://common.auth0.com",
        idp_id: admin_actor_email,
        name: "Firezone Admin"
      })

    {:ok, _google_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://accounts.google.com",
        idp_id: google_idp_id(),
        name: "Firezone Admin"
      })

    {:ok, _entra_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
        idp_id: entra_idp_id(),
        name: "Firezone Admin"
      })

    for {{actor, email}, actor_index} <- Enum.with_index(other_actors_with_emails, 1) do
      {:ok, identity} =
        Repo.insert(%ExternalIdentity{
          actor_id: actor.id,
          account_id: account.id,
          issuer: "https://common.auth0.com",
          idp_id: email,
          name: actor.name
        })

      {location_region, location_city, location_lat, location_lon} = Enum.random(@locations)

      context = %Authentication.Context{
        type: :client,
        user_agent: @ua_windows,
        remote_ip: {172, 28, 0, 100},
        remote_ip_location_region: location_region,
        remote_ip_location_city: location_city,
        remote_ip_location_lat: location_lat,
        remote_ip_location_lon: location_lon
      }

      {:ok, token} =
        Repo.insert(%ClientToken{
          auth_provider_id: userpass_provider.id,
          account_id: account.id,
          actor_id: identity.actor_id,
          expires_at: DateTime.utc_now() |> DateTime.add(90, :day),
          secret_salt: Crypto.random_token(16),
          secret_hash: "placeholder"
        })

      {:ok, subject} = Authentication.build_subject(token, context)

      count = Enum.random([1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 240])

      for i <- 0..count do
        user_agent =
          Enum.random(@initiator_user_agents)

        client_name = String.split(user_agent, "/") |> List.first()

        # Create the client directly without going through a context module
        # Extract version from user agent (e.g., "Ubuntu/22.4.0 connlib/1.2.2" -> "1.2.2")
        version =
          user_agent |> String.split("/") |> List.last() |> String.split(" ") |> List.first()

        # Keep these deterministic so they cannot collide with later fixed seed fixtures.
        ipv4 = "100.65.#{actor_index}.#{i + 1}"
        ipv6 = "fd00:2021:1111::#{actor_index}:#{i + 1}"

        firezone_id = Ecto.UUID.generate()

        # First create the client
        client =
          %Device{}
          |> Ecto.Changeset.cast(
            %{
              name: "My #{client_name} #{i}",
              firezone_id: firezone_id,
              identifier_for_vendor: Ecto.UUID.generate(),
              ipv4: ipv4,
              ipv6: ipv6
            },
            [:name, :firezone_id, :identifier_for_vendor, :ipv4, :ipv6]
          )
          |> Ecto.Changeset.put_change(:type, :client)
          |> Ecto.Changeset.put_change(:account_id, subject.account.id)
          |> Ecto.Changeset.put_change(:actor_id, subject.actor.id)
          |> Device.changeset()
          |> Safe.unscoped()
          |> Safe.insert()
          |> case do
            {:ok, client} ->
              client

            {:error, changeset} ->
              raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
          end

        {location_region, location_city, location_lat, location_lon} = Enum.random(@locations)

        client
        |> Ecto.Changeset.change(
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          last_seen_user_agent: user_agent,
          last_seen_remote_ip: subject.context.remote_ip,
          last_seen_remote_ip_location_region: location_region,
          last_seen_remote_ip_location_city: location_city,
          last_seen_remote_ip_location_lat: location_lat,
          last_seen_remote_ip_location_lon: location_lon,
          last_seen_version: version,
          last_seen_at: DateTime.utc_now(),
          client_token_id: token.id
        )
        |> Repo.update!()
      end
    end

    # Other Account Users
    other_unprivileged_actor_email = "other-unprivileged-1@localhost.local"
    other_admin_actor_email = "other@localhost.local"

    {:ok, other_unprivileged_actor} =
      Repo.insert(%Actor{
        account_id: other_account.id,
        type: :account_user,
        name: "Other Unprivileged",
        email: other_unprivileged_actor_email
      })

    {:ok, other_admin_actor} =
      Repo.insert(%Actor{
        account_id: other_account.id,
        type: :account_admin_user,
        name: "Other Admin",
        email: other_admin_actor_email
      })

    # Set password on other_account actors (no identity needed for userpass/email)
    password_hash = Crypto.hash(:argon2, "Firezone1234")

    _other_unprivileged_actor =
      other_unprivileged_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    _other_admin_actor =
      other_admin_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    {location_region, location_city, location_lat, location_lon} = Enum.random(@locations)

    _unprivileged_actor_context = %Authentication.Context{
      type: :client,
      user_agent: @ua_ios,
      remote_ip: {172, 28, 0, 100},
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon
    }

    # Create client token for unprivileged actor so policy authorizations can reference it
    {:ok, unprivileged_client_token} =
      Repo.insert(%ClientToken{
        auth_provider_id: userpass_provider.id,
        account_id: account.id,
        actor_id: unprivileged_actor.id,
        secret_nonce: Ecto.UUID.generate(),
        secret_fragment: Ecto.UUID.generate(),
        secret_salt: Ecto.UUID.generate(),
        secret_hash: Ecto.UUID.generate(),
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day)
      })

    # Create client token for admin actor so we can create client sessions
    {:ok, admin_client_token} =
      Repo.insert(%ClientToken{
        auth_provider_id: userpass_provider.id,
        account_id: account.id,
        actor_id: admin_actor.id,
        secret_nonce: Ecto.UUID.generate(),
        secret_fragment: Ecto.UUID.generate(),
        secret_salt: Ecto.UUID.generate(),
        secret_hash: Ecto.UUID.generate(),
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day)
      })

    # For seeds, create a system subject for admin operations
    # In real usage, subjects are created during sign-in flow
    admin_subject = %Authentication.Subject{
      account: account,
      actor: admin_actor,
      credential: %Authentication.Credential{type: :portal_session, id: Ecto.UUID.generate()},
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Authentication.Context{
        type: :portal,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      }
    }

    unprivileged_subject = %Authentication.Subject{
      account: account,
      actor: unprivileged_actor,
      credential: %Authentication.Credential{type: :token, id: unprivileged_client_token.id},
      expires_at: unprivileged_client_token.expires_at,
      context: %Authentication.Context{
        type: :client,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      }
    }

    service_account_token =
      %ClientToken{
        id: "7da7d1cd-111c-44a7-b5ac-4027b9d230e5",
        account_id: service_account_actor.account_id,
        actor_id: service_account_actor.id,
        secret_salt: "kKKA7dtf3TJk0-1O2D9N1w",
        secret_hash: "5c1d6795ea1dd08b6f4fd331eeaffc12032ba171d227f328446f2d26b96437e5",
        expires_at: DateTime.utc_now() |> DateTime.add(365, :day)
      }
      |> Repo.insert!()

    pool_member_token =
      %ClientToken{
        id: "fe2bf22d-0986-433a-85ed-a8f37c90a34b",
        account_id: pool_member_actor.account_id,
        actor_id: pool_member_actor.id,
        secret_salt: "ljWUfZy-6zmpUxijQhjiKg",
        secret_hash: "9c65535e71259350e7cd171b43f4fea42f94e3da4904e4c493b5830b3aed3159",
        expires_at: DateTime.utc_now() |> DateTime.add(365, :day)
      }
      |> Repo.insert!()

    pool_member_subject = %Authentication.Subject{
      account: account,
      actor: pool_member_actor,
      credential: %Authentication.Credential{type: :token, id: pool_member_token.id},
      expires_at: pool_member_token.expires_at,
      context: %Authentication.Context{
        type: :client,
        remote_ip: {127, 0, 0, 1},
        user_agent: @ua_pool_member
      }
    }

    service_account_actor_encoded_token =
      "n" <> Authentication.encode_fragment!(service_account_token)

    # Email tokens are generated during sign-in flow, not pre-generated
    unprivileged_actor_email_token = "<generated during sign-in>"
    admin_actor_email_token = "<generated during sign-in>"

    IO.puts("Created users: ")

    for {type, login, password, email_token} <- [
          {unprivileged_actor.type, unprivileged_actor_email, "Firezone1234",
           unprivileged_actor_email_token},
          {admin_actor.type, admin_actor_email, "Firezone1234", admin_actor_email_token}
        ] do
      IO.puts(
        "  #{login}, #{type}, password: #{password}, email token: #{email_token} (exp in 15m)"
      )
    end

    IO.puts("  #{service_account_actor.name} token: #{service_account_actor_encoded_token}")
    IO.puts("")

    # Pinned so auto-assigned IPs never randomly collide with the pool member's 100.64.0.2.
    {:ok, user_iphone} =
      create_client(
        %{
          name: "FZ User iPhone",
          firezone_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          identifier_for_vendor: "APPL-#{Ecto.UUID.generate()}",
          ipv4: "100.64.0.10",
          ipv6: "fd00:2021:1111::10"
        },
        unprivileged_subject,
        unprivileged_client_token.id,
        @ua_ios
      )

    {:ok, _user_android_phone} =
      create_client(
        %{
          name: "FZ User Android",
          firezone_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          identifier_for_vendor: "GOOG-#{Ecto.UUID.generate()}",
          ipv4: "100.64.0.11",
          ipv6: "fd00:2021:1111::11"
        },
        unprivileged_subject,
        unprivileged_client_token.id,
        @ua_android
      )

    {:ok, user_windows_laptop} =
      create_client(
        %{
          name: "FZ User Surface",
          firezone_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "WIN-#{Ecto.UUID.generate()}",
          device_serial: "046120283253",
          ipv4: "100.64.0.12",
          ipv6: "fd00:2021:1111::12"
        },
        unprivileged_subject,
        unprivileged_client_token.id,
        @ua_windows
      )

    {:ok, user_linux_laptop} =
      create_client(
        %{
          name: "FZ User Rendering Station",
          firezone_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "UB-#{Ecto.UUID.generate()}",
          ipv4: "100.64.0.13",
          ipv6: "fd00:2021:1111::13"
        },
        unprivileged_subject,
        unprivileged_client_token.id,
        @ua_ubuntu
      )

    {:ok, admin_laptop} =
      create_client(
        %{
          name: "FZ Admin Laptop",
          firezone_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_serial: "FVFHF246Q72Z",
          device_uuid: "#{Ecto.UUID.generate()}",
          ipv4: "100.64.0.14",
          ipv6: "fd00:2021:1111::14"
        },
        admin_subject,
        admin_client_token.id,
        @ua_macos
      )

    pool_member_firezone_id = System.get_env("POOL_MEMBER_FIREZONE_ID", Ecto.UUID.generate())

    {:ok, pool_member_device} =
      create_client(
        %{
          name: "CI Pool Member",
          firezone_id: pool_member_firezone_id,
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "POOL-#{Ecto.UUID.generate()}",
          # Pinned so the static-device-pool test can target a known tun IP.
          ipv4: "100.64.0.2",
          ipv6: "fd00:2021:1111::2"
        },
        pool_member_subject,
        pool_member_token.id,
        @ua_pool_member
      )

    admin_encoded_client_token = Authentication.encode_fragment!(admin_client_token)
    unprivileged_encoded_client_token = Authentication.encode_fragment!(unprivileged_client_token)

    IO.puts("Client tokens:")
    IO.puts("  Admin: #{admin_encoded_client_token}")
    IO.puts("  Unprivileged: #{unprivileged_encoded_client_token}")

    IO.puts("Clients created")
    IO.puts("")

    seed_device_posture(account, %{
      admin_laptop: admin_laptop,
      user_surface: user_windows_laptop,
      user_iphone: user_iphone,
      user_rendering_station: user_linux_laptop
    })

    IO.puts("Created Groups: ")

    # Collect all actors for this account
    all_actors = [
      unprivileged_actor,
      admin_actor,
      service_account_actor | other_actors
    ]

    actor_ids = Enum.map(all_actors, & &1.id)
    # Total number of actors
    max_members = length(actor_ids)

    # Create groups in chunks and collect their IDs
    group_ids =
      1..20
      # Process in chunks to manage memory
      |> Enum.chunk_every(1000)
      |> Enum.flat_map(fn chunk ->
        group_attrs =
          Enum.map(chunk, fn i ->
            %{
              name: "#{NameGenerator.generate_slug()}-#{i}",
              type: :static,
              account_id: admin_subject.account.id,
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }
          end)

        {_, inserted_groups} =
          Repo.insert_all(
            Group,
            group_attrs,
            returning: [:id]
          )

        Enum.map(inserted_groups, & &1.id)
      end)

    # Create memberships
    memberships =
      group_ids
      |> Enum.chunk_every(1000)
      |> Enum.flat_map(fn group_chunk ->
        Enum.flat_map(group_chunk, fn group_id ->
          # Determine random number of members (1 to max_members)
          num_members = :rand.uniform(max_members)

          # Select random actor IDs
          member_ids =
            actor_ids
            # Uses seeded random
            |> Enum.shuffle()
            |> Enum.take(num_members)

          # Create membership attributes
          Enum.map(member_ids, fn actor_id ->
            %{
              group_id: group_id,
              actor_id: actor_id,
              account_id: admin_subject.account.id
            }
          end)
        end)
      end)

    # Bulk insert memberships
    memberships
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Membership, chunk)
    end)

    now = DateTime.utc_now()

    group_values = [
      %{
        id: Ecto.UUID.generate(),
        name: "Engineering",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        name: "Finance",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        name: "Synced Group with long name",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now
      }
    ]

    {3, group_results} =
      Repo.insert_all(Group, group_values, returning: [:id, :name])

    for group <- group_results do
      IO.puts("  Name: #{group.name}  ID: #{group.id}")
    end

    # Reload as structs for further use
    [eng_group_id, finance_group_id, synced_group_id] = Enum.map(group_results, & &1.id)

    eng_group = Repo.get_by!(Group, id: eng_group_id)
    finance_group = Repo.get_by!(Group, id: finance_group_id)
    synced_group = Repo.get_by!(Group, id: synced_group_id)

    # Add admin as member of engineering group directly
    %Membership{
      group_id: eng_group.id,
      actor_id: admin_subject.actor.id,
      account_id: admin_subject.account.id
    }
    |> Repo.insert!()

    # Add unprivileged user as member of finance group directly
    %Membership{
      group_id: finance_group.id,
      actor_id: unprivileged_subject.actor.id,
      account_id: unprivileged_subject.account.id
    }
    |> Repo.insert!()

    # Add admin and unprivileged user as members of synced group
    %Membership{
      group_id: synced_group.id,
      actor_id: admin_subject.actor.id,
      account_id: admin_subject.account.id
    }
    |> Repo.insert!()

    %Membership{
      group_id: synced_group.id,
      actor_id: unprivileged_subject.actor.id,
      account_id: unprivileged_subject.account.id
    }
    |> Repo.insert!()

    # Add service account (Backup Manager) to synced group
    %Membership{
      group_id: synced_group.id,
      actor_id: service_account_actor.id,
      account_id: service_account_actor.account_id
    }
    |> Repo.insert!()

    synced_group = synced_group

    extra_group_names = [
      "gcp-logging-viewers",
      "gcp-security-admins",
      "gcp-organization-admins",
      "Admins",
      "Product",
      "Product Engineering",
      "gcp-developers"
    ]

    extra_group_values =
      Enum.map(extra_group_names, fn name ->
        %{
          id: Ecto.UUID.generate(),
          name: name,
          type: :static,
          account_id: account.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, extra_group_results} =
      Repo.insert_all(Group, extra_group_values, returning: [:id])

    # Add admin as member of each extra group
    for %{id: group_id} <- extra_group_results do
      %Membership{
        group_id: group_id,
        actor_id: admin_subject.actor.id,
        account_id: admin_subject.account.id
      }
      |> Repo.insert!()
    end

    IO.puts("")

    # Create relay token with static values
    relay_token =
      %Portal.RelayToken{
        id: "e82fcdc1-057a-4015-b90b-3b18f0f28053",
        secret_fragment: "C14NGA87EJRR03G4QPR07A9C6G784TSSTHSF4TI5T0GD8D6L0VRG====",
        secret_salt: "lZWUdgh-syLGVDsZEu_29A",
        secret_hash: "c3c9a031ae98f111ada642fddae546de4e16ceb85214ab4f1c9d0de1fc472797"
      }
      |> Repo.insert!()

    relay_encoded_token =
      Authentication.encode_fragment!(relay_token)

    IO.puts("Created relay token:")
    IO.puts("  Token: #{relay_encoded_token}")
    IO.puts("")

    site =
      %Site{account: account}
      |> Ecto.Changeset.cast(%{name: "AWS US-East"}, [:name])
      |> Portal.Changeset.trim_change([:name])
      |> Portal.Changeset.put_default_value(:name, &NameGenerator.generate/0)
      |> Ecto.Changeset.validate_required([:name])
      |> Site.changeset()
      |> Portal.Changeset.put_default_value(:managed_by, :account)
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Repo.insert!()

    # Create gateway token with static values
    gateway_token =
      %Portal.GatewayToken{
        id: "2274560b-e97b-45e4-8b34-679c7617e98d",
        account_id: site.account_id,
        site_id: site.id,
        secret_salt: "uQyisyqrvYIIitMXnSJFKQ",
        secret_hash: "876f20e8d4de25d5ffac40733f280782a7d8097347d77415ab6e4e548f13d2ee"
      }
      |> Repo.insert!()

    gateway_encoded_token = Authentication.encode_fragment!(gateway_token)

    IO.puts("Created sites:")
    IO.puts("  #{site.name} token: #{gateway_encoded_token}")
    IO.puts("")

    # Pinned so auto-assigned IPs never randomly collide with the pool member's 100.64.0.2.
    {:ok, gateway1} =
      create_gateway(
        %{
          site_id: site.id,
          firezone_id: Ecto.UUID.generate(),
          name: "gw-#{Crypto.random_token(5, encoder: :user_friendly)}",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          ipv4: "100.64.0.20",
          ipv6: "fd00:2021:1111::20"
        },
        %Authentication.Context{
          type: :gateway,
          user_agent: @ua_gateway,
          remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}}
        }
      )

    {:ok, gateway2} =
      create_gateway(
        %{
          site_id: site.id,
          firezone_id: Ecto.UUID.generate(),
          name: "gw-#{Crypto.random_token(5, encoder: :user_friendly)}",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          ipv4: "100.64.0.21",
          ipv6: "fd00:2021:1111::21"
        },
        %Authentication.Context{
          type: :gateway,
          user_agent: @ua_gateway,
          remote_ip: %Postgrex.INET{address: {164, 112, 78, 62}}
        }
      )

    for i <- 1..10 do
      {:ok, _gateway} =
        create_gateway(
          %{
            site_id: site.id,
            firezone_id: Ecto.UUID.generate(),
            name: "gw-#{Crypto.random_token(5, encoder: :user_friendly)}",
            public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
            ipv4: "100.64.0.#{30 + i}",
            ipv6: "fd00:2021:1111::#{30 + i}"
          },
          %Authentication.Context{
            type: :gateway,
            user_agent: @ua_gateway,
            remote_ip: %Postgrex.INET{address: {164, 112, 78, 62 + i}}
          }
        )
    end

    IO.puts("Created gateways:")
    gateway_name = "#{site.name}-#{gateway1.name}"
    IO.puts("  #{gateway_name}:")
    IO.puts("    Firezone ID: #{gateway1.firezone_id}")
    IO.puts("    IPv4: #{gateway1.ipv4} IPv6: #{gateway1.ipv6}")
    IO.puts("")

    gateway_name = "#{site.name}-#{gateway2.name}"
    IO.puts("  #{gateway_name}:")
    IO.puts("    Firezone ID: #{gateway2.firezone_id}")
    IO.puts("    IPv4: #{gateway2.ipv4} IPv6: #{gateway2.ipv6}")
    IO.puts("")

    {:ok, dns_google_resource} =
      create_resource(
        %{
          type: :dns,
          name: "foobar.com",
          address: "foobar.com",
          address_description: "https://foobar.com/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, firez_one} =
      create_resource(
        %{
          type: :dns,
          name: "**.firez.one",
          address: "**.firez.one",
          address_description: "https://firez.one/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, firezone_dev} =
      create_resource(
        %{
          type: :dns,
          name: "*.firezone.dev",
          address: "*.firezone.dev",
          address_description: "https://www.firezone.dev/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, example_dns} =
      create_resource(
        %{
          type: :dns,
          name: "example.com",
          address: "example.com",
          address_description: "https://example.com:1234/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, ip6only} =
      create_resource(
        %{
          type: :dns,
          name: "ip6only",
          address: "ip6only.me",
          address_description: "https://ip6only.me/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, address_description_null_resource} =
      create_resource(
        %{
          type: :dns,
          name: "Example",
          address: "*.example.com",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, dns_gitlab_resource} =
      create_resource(
        %{
          type: :dns,
          name: "gitlab.mycorp.com",
          address: "gitlab.mycorp.com",
          address_description: "https://gitlab.mycorp.com/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, ip_resource} =
      create_resource(
        %{
          type: :ip,
          name: "Public DNS",
          address: "1.2.3.4",
          address_description: "http://1.2.3.4:3000/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, cidr_resource} =
      create_resource(
        %{
          type: :cidr,
          name: "MyCorp Network",
          address: "10.20.0.0/16",
          address_description: "10.20.0.0/16",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, ipv6_resource} =
      create_resource(
        %{
          type: :cidr,
          name: "MyCorp Network (IPv6)",
          address: "10:20::/64",
          address_description: "10:20::/64",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, dns_httpbin_resource} =
      create_resource(
        %{
          type: :dns,
          name: "**.httpbin",
          address: "**.httpbin",
          address_description: "http://httpbin/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, search_domain_resource} =
      create_resource(
        %{
          type: :dns,
          name: "**.httpbin.search.test",
          address: "**.httpbin.search.test",
          address_description: "http://httpbin/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, iperf_resource} =
      create_resource(
        %{
          type: :dns,
          name: "iperf3.test",
          address: "iperf3.test",
          address_description: "iperf3 server for performance tests",
          site_id: site.id,
          filters: [
            %{ports: ["5201"], protocol: :tcp},
            %{ports: ["5201"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, pool_resource} =
      create_resource(
        %{
          type: :static_device_pool,
          name: "CI Static Pool",
          address_description: "CI integration test static device pool",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    %Portal.StaticDevicePoolMember{
      account_id: account.id,
      resource_id: pool_resource.id,
      device_id: pool_member_device.id,
      device_type: :client
    }
    |> Repo.insert!()

    IO.puts("Created resources:")
    IO.puts("  #{dns_google_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{address_description_null_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{dns_gitlab_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{firez_one.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{firezone_dev.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{example_dns.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{ip_resource.address} - IP - gateways: #{gateway_name}")
    IO.puts("  #{cidr_resource.address} - CIDR - gateways: #{gateway_name}")
    IO.puts("  #{ipv6_resource.address} - CIDR - gateways: #{gateway_name}")
    IO.puts("  #{dns_httpbin_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{search_domain_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{iperf_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("")

    # Helper function to create policy directly without context module
    create_policy = fn attrs, subject ->
      policy =
        %Policy{
          account_id: subject.account.id,
          description: attrs[:description] || attrs["description"],
          group_id: attrs[:group_id] || attrs["group_id"],
          resource_id: attrs[:resource_id] || attrs["resource_id"],
          conditions: attrs[:conditions] || attrs["conditions"] || []
        }
        |> Repo.insert!()

      {:ok, policy}
    end

    {:ok, google_policy} =
      create_policy.(
        %{
          description: "All Access To Google",
          group_id: everyone_group.id,
          resource_id: dns_google_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To firez.one",
          group_id: synced_group.id,
          resource_id: firez_one.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To firez.one",
          group_id: everyone_group.id,
          resource_id: example_dns.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To firezone.dev",
          group_id: everyone_group.id,
          resource_id: firezone_dev.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To ip6only.me",
          group_id: synced_group.id,
          resource_id: ip6only.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All access to Google",
          group_id: everyone_group.id,
          resource_id: address_description_null_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Eng Access To Gitlab",
          group_id: eng_group.id,
          resource_id: dns_gitlab_resource.id
        },
        admin_subject
      )

    {:ok, cidr_policy} =
      create_policy.(
        %{
          description: "All Access To Network",
          group_id: synced_group.id,
          resource_id: cidr_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To Network",
          group_id: synced_group.id,
          resource_id: ipv6_resource.id
        },
        admin_subject
      )

    {:ok, httpbin_policy} =
      create_policy.(
        %{
          description: "All Access To **.httpbin",
          group_id: everyone_group.id,
          resource_id: dns_httpbin_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Synced Group Access To **.httpbin",
          group_id: synced_group.id,
          resource_id: dns_httpbin_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To **.httpbin.search.test",
          group_id: everyone_group.id,
          resource_id: search_domain_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Synced Group Access To **.httpbin.search.test",
          group_id: synced_group.id,
          resource_id: search_domain_resource.id
        },
        admin_subject
      )

    {:ok, iperf_policy} =
      create_policy.(
        %{
          description: "All Access To iperf3.test",
          group_id: everyone_group.id,
          resource_id: iperf_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Synced Group Access To iperf3.test",
          group_id: synced_group.id,
          resource_id: iperf_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To CI Static Pool",
          # synced_group, not everyone_group: service accounts don't auto-join Everyone.
          group_id: synced_group.id,
          resource_id: pool_resource.id
        },
        admin_subject
      )

    IO.puts("Policies Created")
    IO.puts("")

    ops_username = Application.get_env(:portal, :ops_admin_username, "admin")
    ops_password = Application.get_env(:portal, :ops_admin_password, "firezone")
    IO.puts("Ops endpoint: http://localhost:13002")
    IO.puts("  Username: #{ops_username}")
    IO.puts("  Password: #{ops_password}")
    IO.puts("")

    membership =
      Repo.get_by(Membership,
        group_id: synced_group.id,
        actor_id: unprivileged_actor.id
      )

    cidr_authorization =
      create_seed_policy_authorization(
        unprivileged_subject,
        user_iphone,
        gateway1,
        cidr_resource,
        cidr_policy,
        membership
      )

    google_authorization =
      create_seed_policy_authorization(
        unprivileged_subject,
        user_iphone,
        gateway1,
        dns_google_resource,
        google_policy,
        nil
      )

    httpbin_authorization =
      create_seed_policy_authorization(
        unprivileged_subject,
        user_iphone,
        gateway1,
        dns_httpbin_resource,
        httpbin_policy,
        nil
      )

    iperf_authorization =
      create_seed_policy_authorization(
        unprivileged_subject,
        user_iphone,
        gateway1,
        iperf_resource,
        iperf_policy,
        nil
      )

    seed_flow_logs(account, unprivileged_actor, user_iphone, userpass_provider.id, %{
      google: %{
        authorization: google_authorization,
        resource: dns_google_resource,
        inner_dst_ip: {100, 96, 0, 10},
        domain: dns_google_resource.address,
        default_port: 443
      },
      httpbin: %{
        authorization: httpbin_authorization,
        resource: dns_httpbin_resource,
        inner_dst_ip: {100, 96, 0, 20},
        domain: "api.httpbin",
        default_port: 443
      },
      network: %{
        authorization: cidr_authorization,
        resource: cidr_resource,
        inner_dst_ip: {172, 20, 10, 25},
        domain: nil,
        default_port: 22
      },
      iperf: %{
        authorization: iperf_authorization,
        resource: iperf_resource,
        inner_dst_ip: {100, 96, 0, 30},
        domain: iperf_resource.address,
        default_port: 5_201
      }
    })

    # Populate the audit log tables so /logs pages have realistic data on
    # first boot. Uses a spread of recent timestamps across the seeded
    # actors and a rotation of world locations.
    api_token_id = Ecto.UUID.generate()

    subjects = %{
      admin:
        subject_map_from_authentication(
          admin_subject,
          "US-CA",
          "San Francisco",
          37.7749,
          -122.4194
        ),
      unpriv:
        subject_map_from_authentication(
          unprivileged_subject,
          "US-NY",
          "New York",
          40.7128,
          -74.006
        )
    }

    seed_audit_logs(account, subjects, service_account_actor, api_token_id)
  end
end

Portal.Repo.Seeds.seed()
