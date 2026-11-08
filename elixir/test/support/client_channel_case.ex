defmodule PortalAPI.Client.ChannelCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use PortalAPI.ChannelCase, async: true
      import Ecto.Query, only: [from: 2]
      import ExUnit.CaptureLog
      alias Portal.Changes
      alias Portal.Fixture
      alias Portal.Presence
      alias Portal.{PG, PubSub}

      import Portal.AccountFixtures
      import Portal.ActorFixtures
      import Portal.AuthProviderFixtures
      import Portal.DeviceFixtures
      import Portal.GroupFixtures
      import Portal.IdentityFixtures
      import Portal.MembershipFixtures
      import Portal.PolicyFixtures
      import Portal.RelayFixtures
      import Portal.ResourceFixtures
      import Portal.SiteFixtures
      import Portal.SubjectFixtures
      import Portal.TokenFixtures
      import Portal.TrustAnchorFixtures

      import PortalAPI.Client.ChannelFixtures

      setup :setup_fixtures
    end
  end
end

defmodule PortalAPI.Client.ChannelFixtures do
  @moduledoc false
  @endpoint PortalAPI.Endpoint
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Phoenix.ChannelTest
  alias Portal.Repo
  alias Portal.Presence

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  def join_channel(client, subject, opts \\ []) do
    channel = Keyword.get(opts, :channel, PortalAPI.Client.Channel)

    socket_module =
      case channel do
        PortalAPI.Client.V2.Channel -> PortalAPI.Client.V2.Socket
        PortalAPI.Client.V3.Channel -> PortalAPI.Client.V3.Socket
        PortalAPI.Client.Channel -> PortalAPI.Client.Socket
      end

    client_version =
      Keyword.get_lazy(opts, :client_version, fn ->
        case Portal.Version.fetch_version(subject.context.user_agent) do
          {:ok, version} -> version
          _ -> nil
        end
      end)

    session_ref = Keyword.get_lazy(opts, :session_ref, fn -> make_ref() end)

    # Apply the connection snapshot onto the Device struct to match what
    # Socket.connect does
    device = %{
      fetch_device!(client)
      | client_token_id: subject.credential.id,
        public_key: Portal.DeviceFixtures.generate_public_key(),
        last_seen_user_agent: subject.context.user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_remote_ip_location_region: subject.context.remote_ip_location_region,
        last_seen_remote_ip_location_city: subject.context.remote_ip_location_city,
        last_seen_remote_ip_location_lat: subject.context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: subject.context.remote_ip_location_lon,
        last_seen_version: client_version,
        last_seen_at: DateTime.utc_now(),
        attested?: Keyword.get(opts, :attested?, false),
        posture: Keyword.get(opts, :posture, %{})
    }

    {:ok, _reply, socket} =
      socket_module
      |> socket("client:#{client.id}", %{
        client: device,
        session_ref: session_ref,
        subject: subject,
        client_version: client_version,
        attestation: Keyword.get(opts, :attestation),
        previous_public_key: Keyword.get(opts, :previous_public_key)
      })
      |> subscribe_and_join(channel, "client")

    socket
  end

  # Mirrors what Portal.Changes.Hooks.Devices builds from a WAL row: the
  # latest-session columns still hold what the last flush persisted, and virtual
  # fields and associations are not in the row at all.
  def broadcast_struct(client) do
    Portal.SchemaHelpers.struct_from_params(
      Portal.Device,
      Map.from_struct(%{client | public_key: nil, client_token_id: nil, last_seen_version: nil})
    )
  end

  # Mirrors Socket.connect's apply_session: the connection snapshot lives on
  # the Device struct.
  def with_session(client, subject, version) do
    %{
      client
      | client_token_id: subject.credential.id,
        public_key: Portal.DeviceFixtures.generate_public_key(),
        last_seen_user_agent: subject.context.user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_remote_ip_location_region: subject.context.remote_ip_location_region,
        last_seen_remote_ip_location_city: subject.context.remote_ip_location_city,
        last_seen_remote_ip_location_lat: subject.context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: subject.context.remote_ip_location_lon,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now()
    }
  end

  def connect_gateway_presence(gateway, token_id) do
    session_meta = %{
      site_id: gateway.site_id,
      public_key: gateway.public_key,
      psk_base: gateway.psk_base,
      version: gateway.last_seen_version,
      remote_ip: gateway.last_seen_remote_ip,
      remote_ip_location_lat: gateway.last_seen_remote_ip_location_lat,
      remote_ip_location_lon: gateway.last_seen_remote_ip_location_lon
    }

    Presence.Devices.connect(gateway, token_id, session_meta)
  end

  def put_user_agent(subject, user_agent) do
    %{subject | context: %{subject.context | user_agent: user_agent}}
  end

  def assert_x509_account_disable_disconnects_channel(
         %{account: account, client: client, subject: subject},
         channel
       ) do
    Process.flag(:trap_exit, true)
    provider = x509_provider_fixture(account: account, is_disabled: false)

    credential = %Portal.Authentication.Credential.X509{
      id: Ecto.UUID.generate(),
      auth_provider_id: provider.id
    }

    join_channel(client, %{subject | credential: credential}, channel: channel)
    assert_push "init", _init_payload

    account |> Ecto.Changeset.change(is_disabled: true) |> Repo.update!()

    old_data = %{
      "id" => account.id,
      "is_disabled" => false
    }

    assert :ok =
             Portal.Changes.Hooks.Accounts.on_update(
               1,
               old_data,
               %{old_data | "is_disabled" => true}
             )

    assert_push "disconnect", %{reason: "token_expired"}
    assert_receive :socket_drain
    assert_receive {:EXIT, _pid, :shutdown}
  end

  def gateway_authorization_generation(channel_pid, resource_id) do
    {generation, _timer_ref, _initiator_token, _address} =
      :sys.get_state(channel_pid).assigns.pending_authorizations |> Map.fetch!(resource_id)

    generation
  end

  def fire_authorization_creation_timeout(channel_pid, resource_id) do
    send(
      channel_pid,
      {:authorization_creation_timeout, resource_id, gateway_authorization_generation(channel_pid, resource_id)}
    )
  end

  def setup_fixtures(tags) do
    for queue <- [:client_session_queue, :policy_authorization_queue] do
      Portal.Config.put_env_override(queue,
        name: {:via, Registry, {Portal.Test.QueueRegistry, {self(), queue}}}
      )
    end

    if constant_time = tags[:device_lookup_constant_time] do
      Portal.Config.put_env_override(PortalAPI.Client.Channel.Shared,
        device_lookup_constant_time: constant_time
      )
    end

    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Client.Channel.policy_authorization_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Client.Socket.client_session_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    account =
      account_fixture(
        config: %{
          clients_upstream_dns: %{
            type: :custom,
            addresses: [
              %{address: "1:2:3:4:5:6:7:8"},
              %{address: "1.1.1.1"},
              %{address: "8.8.8.8"}
            ]
          },
          search_domain: "example.com"
        },
        features: %{
          internet_resource: true,
          iceless: true
        }
      )

    group = group_fixture(account: account)
    actor = actor_fixture(type: :account_admin_user, account: account)

    membership =
      membership_fixture(account: account, actor: actor, group: group)

    identity = identity_fixture(actor: actor, account: account)

    subject =
      subject_fixture(
        account: account,
        actor: actor,
        type: :client,
        user_agent: "Linux/24.04 connlib/1.3.0"
      )

    client = client_fixture(account: account, actor: actor) |> fetch_device!()

    site = site_fixture(account: account)
    gateway_token = gateway_token_fixture(account: account, site: site)
    gateway = gateway_fixture(account: account, site: site)

    internet_site = internet_site_fixture(account: account)

    internet_gateway_token =
      gateway_token_fixture(account: account, site: internet_site)

    internet_gateway =
      gateway_fixture(account: account, site: internet_site)

    default_filters = [
      %{protocol: :tcp, ports: ["80", "433"]},
      %{protocol: :udp, ports: ["100-200"]},
      %{protocol: :icmp}
    ]

    dns_resource =
      dns_resource_fixture(
        account: account,
        ip_stack: :ipv4_only,
        site: site,
        filters: default_filters
      )

    cidr_resource =
      cidr_resource_fixture(
        address: "192.168.1.1/28",
        account: account,
        site: site,
        filters: default_filters
      )

    ip_resource =
      ip_resource_fixture(
        address: "192.168.100.1",
        account: account,
        site: site,
        filters: default_filters
      )

    internet_resource =
      internet_resource_fixture(
        account: account,
        site: internet_site
      )

    unauthorized_resource =
      resource_fixture(
        account: account,
        site: site
      )

    nonconforming_resource =
      resource_fixture(
        account: account,
        site: site
      )

    offline_resource =
      resource_fixture(account: account)
      |> Ecto.Changeset.change(site_id: nil)
      |> Repo.update!()

    dns_resource_policy =
      policy_fixture(
        account: account,
        group: group,
        resource: dns_resource
      )

    policy_fixture(
      account: account,
      group: group,
      resource: cidr_resource
    )

    policy_fixture(
      account: account,
      group: group,
      resource: ip_resource
    )

    policy_fixture(
      account: account,
      group: group,
      resource: nonconforming_resource,
      conditions: [
        %{
          property: :remote_ip_location_region,
          operator: :is_not_in,
          values: [subject.context.remote_ip_location_region]
        }
      ]
    )

    internet_resource_policy =
      policy_fixture(
        account: account,
        group: group,
        resource: internet_resource
      )

    policy_fixture(
      account: account,
      group: group,
      resource: offline_resource
    )

    expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

    subject = %{subject | expires_at: expires_at}

    global_relay = relay_fixture(%{lat: 37.0, lon: -120.0})

    %{
      account: account,
      actor: actor,
      group: group,
      identity: identity,
      subject: subject,
      client: client,
      gateway_token: gateway_token,
      site: site,
      membership: membership,
      gateway: gateway,
      internet_site: internet_site,
      internet_gateway_token: internet_gateway_token,
      internet_gateway: internet_gateway,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      ip_resource: ip_resource,
      internet_resource: internet_resource,
      unauthorized_resource: unauthorized_resource,
      nonconforming_resource: nonconforming_resource,
      offline_resource: offline_resource,
      dns_resource_policy: dns_resource_policy,
      internet_resource_policy: internet_resource_policy,
      global_relay: global_relay
    }
  end

  def time_access(socket, resource_id, address) do
    ipv4 = if is_binary(address), do: address, else: Portal.Types.INET.to_string(address)
    started_at = System.monotonic_time(:millisecond)

    push(socket, "request_access", %{"resource_ids" => [resource_id], "ipv4" => ipv4})
    assert_push "client_device_access_denied", payload

    {System.monotonic_time(:millisecond) - started_at, payload}
  end

  # Milliseconds between asking for a name and the answer landing.
  def time_push(socket, domain, event) do
    started_at = System.monotonic_time(:millisecond)
    push(socket, "resolve_device_domain", %{"domain" => domain})
    assert_push ^event, %{domain: ^domain}
    System.monotonic_time(:millisecond) - started_at
  end

  # Milliseconds between asking what a name lists and the answer landing.
  def time_browse(socket, domain, event) do
    started_at = System.monotonic_time(:millisecond)
    push(socket, "browse_device_domain", %{"domain" => domain})
    assert_push ^event, %{domain: ^domain}
    System.monotonic_time(:millisecond) - started_at
  end

  def put_inbound_authorization(socket, %Portal.PolicyAuthorization{} = pa) do
    :sys.replace_state(socket.channel_pid, fn state ->
      cache =
        Portal.Cache.Client.Authorizations.put(
          state.assigns.authorizations_cache,
          pa.id,
          pa.initiating_device_id,
          pa.resource_id,
          pa.expires_at
        )

      put_in(state.assigns.authorizations_cache, cache)
    end)
  end

  def put_inbound_authorization(socket, initiating_client_id) do
    put_inbound_authorization(socket, %Portal.PolicyAuthorization{
      id: Ecto.UUID.generate(),
      initiating_device_id: initiating_client_id,
      resource_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
  end

  def put_outbound_authorization(socket, %Portal.PolicyAuthorization{} = pa) do
    :sys.replace_state(socket.channel_pid, fn state ->
      cache =
        Portal.Cache.Client.Authorizations.put(
          state.assigns.outbound_authorizations_cache,
          pa.id,
          pa.receiving_device_id,
          pa.resource_id,
          pa.expires_at
        )

      put_in(state.assigns.outbound_authorizations_cache, cache)
    end)
  end

  def outbound_policy_authorization(account, client, target_client_id) do
    %Portal.PolicyAuthorization{
      id: Ecto.UUID.generate(),
      account_id: account.id,
      initiating_device_id: client.id,
      receiving_device_id: target_client_id,
      resource_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end
end
