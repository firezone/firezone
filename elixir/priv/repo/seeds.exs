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
    ClientSession,
    Crypto,
    EmailOTP,
    Entra,
    ExternalIdentity,
    Device,
    PolicyAuthorization,
    GatewaySession,
    Google,
    Group,
    Membership,
    NameGenerator,
    OIDC,
    Policy,
    Resource,
    Safe,
    SessionLog,
    Site,
    ClientToken,
    Userpass
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

    # Create a gateway session
    {location_region, location_city, location_lat, location_lon} = Enum.random(@locations)

    %GatewaySession{
      account_id: site.account_id,
      device_id: gateway.id,
      gateway_token_id: gateway_token.id,
      public_key: public_key,
      user_agent: context.user_agent,
      remote_ip: context.remote_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon,
      version: version
    }
    |> Repo.insert!()

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

    # Create a client session
    Repo.insert!(%ClientSession{
      account_id: subject.account.id,
      device_id: client.id,
      client_token_id: client_token_id,
      public_key: public_key,
      user_agent: user_agent,
      remote_ip: subject.context.remote_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon,
      version: version
    })

    {:ok, client}
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
  defp policy_row(overrides \\ []) do
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

  defp resource_row(overrides \\ []) do
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

  defp group_row(overrides \\ []) do
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

  defp actor_row(overrides \\ []) do
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

  defp provider_row(overrides \\ []) do
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

  defp client_row(overrides \\ []) do
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

  defp site_row(overrides \\ []) do
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

  defp gateway_token_row(overrides \\ []) do
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

  defp api_token_row(overrides \\ []) do
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

  def seed do
    # Seeds can be run both with MIX_ENV=prod and MIX_ENV=test, for test env we don't have
    # an adapter configured and creation of email provider will fail, so we will override it here.
    System.put_env("OUTBOUND_EMAIL_ADAPTER", "Elixir.Swoosh.Adapters.AzureCommunicationServices")

    # Ensure seeds are deterministic
    :rand.seed(:exsss, {1, 2, 3})

    Repo.query!(
      "INSERT INTO features (feature, enabled) VALUES ('client_to_client', true) ON CONFLICT (feature) DO UPDATE SET enabled = true"
    )

    Repo.query!(
      "INSERT INTO features (feature, enabled) VALUES ('trust_anchors', true) ON CONFLICT (feature) DO UPDATE SET enabled = true"
    )

    Repo.query!(
      "INSERT INTO features (feature, enabled) VALUES ('flow_logs', true) ON CONFLICT (feature) DO UPDATE SET enabled = true"
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
        traffic_filters: true,
        idp_sync: true,
        rest_api: true,
        internet_resource: true,
        client_to_client: true,
        iceless: System.get_env("FEATURE_ICELESS_ENABLED") == "true",
        log_sinks: true
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

        # Create a client session
        Repo.insert!(%ClientSession{
          account_id: subject.account.id,
          device_id: client.id,
          client_token_id: token.id,
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          user_agent: user_agent,
          remote_ip: subject.context.remote_ip,
          remote_ip_location_region: location_region,
          remote_ip_location_city: location_city,
          remote_ip_location_lat: location_lat,
          remote_ip_location_lon: location_lon,
          version: version
        })
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

    {:ok, _user_windows_laptop} =
      create_client(
        %{
          name: "FZ User Surface",
          firezone_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "WIN-#{Ecto.UUID.generate()}",
          ipv4: "100.64.0.12",
          ipv6: "fd00:2021:1111::12"
        },
        unprivileged_subject,
        unprivileged_client_token.id,
        @ua_windows
      )

    {:ok, _user_linux_laptop} =
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

    {:ok, _admin_laptop} =
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
          address: "172.20.0.0/16",
          address_description: "172.20.0.0/16",
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
          address: "172:20::/64",
          address_description: "172:20::/64",
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

    {:ok, policy} =
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

    {:ok, _} =
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

    {:ok, _} =
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

    {:ok, _} =
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

    # Create policy_authorization directly without context module
    _policy_authorization =
      %PolicyAuthorization{
        initiating_device_id: user_iphone.id,
        receiving_device_id: gateway1.id,
        resource_id: cidr_resource.id,
        policy_id: policy.id,
        membership_id: membership.id,
        account_id: unprivileged_subject.account.id,
        token_id: unprivileged_subject.credential.id,
        initiator_remote_ip: {127, 0, 0, 1},
        initiator_user_agent: @ua_ios,
        receiver_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}, netmask: nil},
        expires_at: unprivileged_subject.expires_at || DateTime.utc_now() |> DateTime.add(3600)
      }
      |> Repo.insert!()

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
