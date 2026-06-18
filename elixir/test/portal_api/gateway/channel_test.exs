defmodule PortalAPI.Gateway.ChannelTest do
  use PortalAPI.ChannelCase, async: true
  alias Portal.Cache
  alias Portal.Changes
  alias Portal.PG
  import Portal.Cache.Cacheable, only: [to_cache: 1]
  import Portal.SchemaHelpers, only: [struct_from_params: 2]
  import ExUnit.CaptureLog

  @test_user_agent "macOS/14.0 apple-client/1.3.0"

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures
  import Portal.TokenFixtures

  defp join_channel(gateway, site, token, opts \\ []) do
    device = fetch_device!(gateway)
    session = build_gateway_session(gateway, token, opts)

    {:ok, _reply, socket} =
      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: device,
        site: site,
        session: session,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

    socket
  end

  # Joins the gateway channel with a custom transport pid instead of the test
  # process, so the channel's `Process.link(transport_pid)` targets our fake
  # trapping transport. Mirrors `join_channel/4` otherwise.
  defp join_channel_with_transport(gateway, site, token, transport_pid) do
    device = fetch_device!(gateway)
    session = build_gateway_session(gateway, token)

    base =
      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: device,
        site: site,
        session: session,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })

    {:ok, _reply, socket} =
      %{base | transport_pid: transport_pid}
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

    socket
  end

  # Models the production transport: traps exits, and records every message it
  # receives so tests can assert the channel drained it.
  defp start_trapping_transport do
    parent = self()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:ready, self()})
        trapping_transport_loop(parent)
      end)

    assert_receive {:ready, ^pid}
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp trapping_transport_loop(parent) do
    receive do
      msg ->
        send(parent, {:transport_got, msg})
        trapping_transport_loop(parent)
    end
  end

  defp build_gateway_session(gateway, token, opts \\ []) do
    %Portal.GatewaySession{
      id: Keyword.get_lazy(opts, :session_id, &Ecto.UUID.generate/0),
      device_id: gateway.id,
      account_id: gateway.account_id,
      gateway_token_id: token.id,
      public_key: gateway.latest_session && gateway.latest_session.public_key,
      user_agent: "Firezone-Gateway/1.3.0",
      remote_ip: gateway.latest_session && gateway.latest_session.remote_ip,
      remote_ip_location_region:
        gateway.latest_session && gateway.latest_session.remote_ip_location_region,
      remote_ip_location_city:
        gateway.latest_session && gateway.latest_session.remote_ip_location_city,
      remote_ip_location_lat:
        gateway.latest_session && gateway.latest_session.remote_ip_location_lat,
      remote_ip_location_lon:
        gateway.latest_session && gateway.latest_session.remote_ip_location_lon,
      version: (gateway.latest_session && gateway.latest_session.version) || "1.3.0"
    }
  end

  setup do
    start_supervised!(
      {Portal.Queue,
       Keyword.merge(PortalAPI.Gateway.Socket.gateway_session_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )

    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    group = group_fixture(account: account)
    membership = membership_fixture(account: account, actor: actor, group: group)

    subject = subject_fixture(account: account, actor: actor, type: :client)
    client_record = client_fixture(account: account, actor: actor)
    client = fetch_device!(client_record)

    site = site_fixture(account: account)
    gateway_record = gateway_fixture(account: account, site: site)
    gateway = fetch_device!(gateway_record)
    gateway = %{gateway | latest_session: gateway_record.latest_session}

    resource =
      dns_resource_fixture(
        account: account,
        site: site
      )

    policy = policy_fixture(account: account, group: group, resource: resource)

    token = gateway_token_fixture(site: site, account: account)

    relay = relay_fixture()
    global_relay = relay_fixture()

    %{
      account: account,
      actor: actor,
      group: group,
      membership: membership,
      subject: subject,
      client: client,
      site: site,
      gateway: gateway,
      resource: resource,
      policy: policy,
      relay: relay,
      global_relay: global_relay,
      token: token
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      join_channel(gateway, site, token)
      assert_push "init", _init_payload

      presence = Portal.Presence.Gateways.Account.list(account.id)

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, gateway.id)
      assert is_number(online_at)
    end

    test "after_join enqueues the session and a flush persists it", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      session_id = Ecto.UUID.generate()
      socket = join_channel(gateway, site, token, session_id: session_id)
      assert_push "init", _init_payload

      Portal.Queue.flush(:gateway_session_queue)

      persisted = Portal.Repo.get_by!(Portal.GatewaySession, id: session_id)
      assert persisted.device_id == gateway.id
      assert persisted.account_id == gateway.account_id
      assert persisted.gateway_token_id == token.id
      assert persisted.public_key == socket.assigns.session.public_key
      assert persisted.user_agent == socket.assigns.session.user_agent
      assert persisted.version == socket.assigns.session.version
    end

    test "session_durability timer is cancelled by the queue's confirm message", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      session_id = Ecto.UUID.generate()
      socket = join_channel(gateway, site, token, session_id: session_id)
      assert_push "init", _init_payload

      assert {^session_id, _generation, _timer_ref} =
               :sys.get_state(socket.channel_pid).assigns.session_durability

      Portal.Queue.flush(:gateway_session_queue)

      refute :sys.get_state(socket.channel_pid).assigns.session_durability
    end

    # These tests inject a separate trapping process as the transport, because
    # `Phoenix.ChannelTest` otherwise makes the test process the transport and
    # links the channel to it.

    test "an abnormal channel crash drains the trapping transport", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      transport = start_trapping_transport()
      socket = join_channel_with_transport(gateway, site, token, transport)
      channel_pid = socket.channel_pid

      # Drop the harness link so the crash below doesn't kill the test.
      Process.unlink(channel_pid)
      ref = Process.monitor(channel_pid)

      # An abnormal stop runs terminate/2, modeling an in-process crash (e.g. a
      # Postgrex query raising on timeout).
      capture_log(fn ->
        GenServer.stop(channel_pid, :boom)
        assert_receive {:DOWN, ^ref, :process, ^channel_pid, :boom}
      end)

      # The drain reaches the real trapping transport, closing the WebSocket.
      assert_receive {:transport_got, :socket_drain}
    end

    test "transport death takes the channel down with it (no orphan channel)", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      transport = start_trapping_transport()
      socket = join_channel_with_transport(gateway, site, token, transport)
      channel_pid = socket.channel_pid

      Process.unlink(channel_pid)
      ref = Process.monitor(channel_pid)

      # :kill is the one signal a trapping process cannot trap, so the transport
      # actually dies here (modeling a real WebSocket teardown).
      capture_log(fn ->
        Process.exit(transport, :kill)
        assert_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}
      end)

      # The channel does not outlive its transport. With the explicit link gone,
      # this is enforced by `Phoenix.Channel.Server`, which monitors the transport
      # pid on join and stops the channel on its :DOWN.
      refute Process.alive?(channel_pid)
    end

    test "a graceful channel stop does NOT drain the transport", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      transport = start_trapping_transport()
      socket = join_channel_with_transport(gateway, site, token, transport)
      channel_pid = socket.channel_pid

      Process.unlink(channel_pid)
      ref = Process.monitor(channel_pid)

      # A :shutdown stop already sends phx_close, which connlib treats as a clean
      # reconnect, so terminate/2 must NOT additionally drain the transport.
      GenServer.stop(channel_pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^channel_pid, :shutdown}

      refute_receive {:transport_got, :socket_drain}
    end

    test "sends init message after join", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      join_channel(gateway, site, token)

      assert_push "init", %{
        account_slug: account_slug,
        interface: interface,
        relays: relays,
        config: %{
          ipv4_masquerade_enabled: true,
          ipv6_masquerade_enabled: true
        }
      }

      assert account_slug == account.slug
      assert relays == []

      assert interface == %{
               ipv4: gateway.ipv4,
               ipv6: gateway.ipv6
             }
    end
  end

  describe "handle_info/2 pg scope crash" do
    test "registers exactly once per key on join", %{
      gateway: gateway,
      site: site,
      token: token,
      pg_scope: scope
    } do
      join_channel(gateway, site, token)
      assert_push "init", _init_payload

      assert [_] = :pg.get_members(scope, gateway.id)
      assert [_] = :pg.get_members(scope, token.id)
    end

    test "re-registers with the pg scope after it crashes", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      join_channel(gateway, site, token)
      assert_push "init", _init_payload

      assert :ok = PG.deliver(gateway.id, :ping)

      # Kill the pg scope — the supervisor restarts it, wiping all group memberships
      old_pid = PG.scope_pid()
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}

      # Channel receives the same :DOWN and re-joins the restarted scope.
      wait_for(fn ->
        assert :ok = PG.deliver(gateway.id, :ping)
      end)
    end

    test "retries re-registration when the scope is still restarting", %{
      gateway: gateway,
      site: site,
      token: token,
      pg_scope: scope
    } do
      join_channel(gateway, site, token)
      assert_push "init", _init_payload

      assert :ok = PG.deliver(gateway.id, :ping)

      # Stop the scope completely so it stays down (no supervisor restarts it)
      old_pid = PG.scope_pid()
      ref = Process.monitor(old_pid)
      stop_supervised!(scope)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _}

      # Channel's :DOWN handler fires — scope is nil, schedules :reregister_pg_scope retry
      # Delivery fails while scope is down
      assert {:error, :not_found} = PG.deliver(gateway.id, :ping)

      # Start a fresh scope under the same name so the retry succeeds
      start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})

      wait_for(fn ->
        assert :ok = PG.deliver(gateway.id, :ping)
      end)
    end

    test "ignores :register when already registered to the current scope", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      # Send :register while already registered — scope pid matches, noop
      send(socket.channel_pid, :register)
      :sys.get_state(socket.channel_pid)

      assert :ok = PG.deliver(gateway.id, :ping)
    end

    test "retries :register when pg scope is not yet running", %{
      gateway: gateway,
      site: site,
      token: token,
      pg_scope: scope
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      # Stop the scope so PG.scope_pid() returns nil
      old_pid = PG.scope_pid()
      ref = Process.monitor(old_pid)
      stop_supervised!(scope)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _}

      # Send :register while scope is nil — triggers nil path (log + retry in 50ms)
      send(socket.channel_pid, :register)
      :sys.get_state(socket.channel_pid)

      # Start a fresh scope so the scheduled retry can succeed
      start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})

      wait_for(fn ->
        assert :ok = PG.deliver(gateway.id, :ping)
      end)
    end
  end

  describe "handle_info/2 :reject_access" do
    # The internal `:reject_access` message now carries a synthetic
    # `%Portal.PolicyAuthorization{}` so the handler can evict per-authz_id
    # (same path as the CDC delete handler). The three branches below match
    # the three outcomes of `Cache.Gateway.reauthorize_deleted_policy_authorization/2`.

    test "with no other cached authz for the pair, pushes reject_access and clears the cache",
         %{
           gateway: gateway,
           site: site,
           token: token,
           client: client,
           resource: resource,
           account: account
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      ghost_paid = Ecto.UUID.generate()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      :sys.replace_state(socket.channel_pid, fn state ->
        cache =
          Cache.Gateway.put(
            state.assigns.cache,
            client.id,
            Ecto.UUID.dump!(resource.id),
            ghost_paid,
            expires_at
          )

        put_in(state.assigns.cache, cache)
      end)

      policy_authorization = %Portal.PolicyAuthorization{
        id: ghost_paid,
        account_id: account.id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: expires_at
      }

      send(socket.channel_pid, {:reject_access, policy_authorization})
      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{client_id: client_id, resource_id: resource_id}
      assert client_id == client.id
      assert resource_id == resource.id

      key = {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)}
      refute Map.has_key?(:sys.get_state(socket.channel_pid).assigns.cache, key),
             "expected the cache entry to be cleared when no other authz remains"
    end

    test "with another valid cached authz, pushes expiry update instead of reject_access",
         %{
           gateway: gateway,
           site: site,
           token: token,
           client: client,
           resource: resource,
           account: account
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      # Pre-populate TWO authz_ids for the same pair — only the ghost is rejected;
      # the surviving authz must keep the cache entry alive and trigger an
      # expiry update rather than a reject.
      ghost_paid = Ecto.UUID.generate()
      surviving_paid = Ecto.UUID.generate()
      ghost_expiry = DateTime.utc_now() |> DateTime.add(1800, :second)
      surviving_expiry = DateTime.utc_now() |> DateTime.add(3600, :second)

      :sys.replace_state(socket.channel_pid, fn state ->
        cache =
          state.assigns.cache
          |> Cache.Gateway.put(client.id, Ecto.UUID.dump!(resource.id), ghost_paid, ghost_expiry)
          |> Cache.Gateway.put(
            client.id,
            Ecto.UUID.dump!(resource.id),
            surviving_paid,
            surviving_expiry
          )

        put_in(state.assigns.cache, cache)
      end)

      policy_authorization = %Portal.PolicyAuthorization{
        id: ghost_paid,
        account_id: account.id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: ghost_expiry
      }

      send(socket.channel_pid, {:reject_access, policy_authorization})
      :sys.get_state(socket.channel_pid)

      refute_push "reject_access", _

      assert_push "access_authorization_expiry_updated", push_payload
      assert push_payload.expires_at == DateTime.to_unix(surviving_expiry, :second)

      # Cache still holds the surviving authz_id for the pair.
      key = {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)}
      paid_map = :sys.get_state(socket.channel_pid).assigns.cache |> Map.fetch!(key)
      assert Map.has_key?(paid_map, Ecto.UUID.dump!(surviving_paid))
      refute Map.has_key?(paid_map, Ecto.UUID.dump!(ghost_paid))
    end

    test "when the authz is not in the cache, no push and no crash",
         %{
           gateway: gateway,
           site: site,
           token: token,
           client: client,
           resource: resource,
           account: account
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      # No cache pre-population — the channel cache is empty for this pair.
      policy_authorization = %Portal.PolicyAuthorization{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      }

      send(socket.channel_pid, {:reject_access, policy_authorization})
      :sys.get_state(socket.channel_pid)

      refute_push "reject_access", _
      refute_push "access_authorization_expiry_updated", _
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "authz durability timer" do
    # When a cached authz isn't acknowledged within the timeout by either
    # `:confirm_authz_durability` (queue flush success) or `:reject_access` (queue
    # flush failure), the receiver fail-closes: runs the same eviction path
    # used for `:reject_access`. Guards against scenarios where the queue's
    # `on_failed` never fires (node crash, OOM, hard kill, netsplit) and
    # avoids leaving a phantom authz cached on the receiver until the next
    # gateway reconnect.

    test "on :confirm_authz_durability, cancels the timer so no revoke fires",
         %{gateway: gateway, site: site, token: token, client: client, resource: resource} do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      pa = %Portal.PolicyAuthorization{
        id: Ecto.UUID.generate(),
        account_id: gateway.account_id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      }

      # Manually seed a pending timer for this authz_id so we can observe
      # the cancellation without waiting 15s.
      generation = make_ref()

      ref =
        Process.send_after(
          socket.channel_pid,
          {:authz_durability_timeout, pa, generation},
          :timer.seconds(15)
        )

      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns[:authz_durability], %{pa.id => {generation, ref}})
      end)

      send(socket.channel_pid, {:confirm_authz_durability, pa.id})
      :sys.get_state(socket.channel_pid)

      state = :sys.get_state(socket.channel_pid)
      refute Map.has_key?(state.assigns.authz_durability, pa.id)

      # No revoke push should have fired (and won't, since the timer was
      # cancelled before its 15s deadline).
      refute_push "reject_access", _
    end

    test "on :reject_access, cancels the authz durability timer AND runs revoke",
         %{gateway: gateway, site: site, token: token, client: client, resource: resource} do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      pa = %Portal.PolicyAuthorization{
        id: Ecto.UUID.generate(),
        account_id: gateway.account_id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      }

      generation = make_ref()

      :sys.replace_state(socket.channel_pid, fn state ->
        cache =
          Cache.Gateway.put(
            state.assigns.cache,
            client.id,
            Ecto.UUID.dump!(resource.id),
            pa.id,
            pa.expires_at
          )

        ref =
          Process.send_after(
            socket.channel_pid,
            {:authz_durability_timeout, pa, generation},
            :timer.seconds(15)
          )

        state
        |> put_in([Access.key!(:assigns), :cache], cache)
        |> put_in([Access.key!(:assigns), :authz_durability], %{pa.id => {generation, ref}})
      end)

      send(socket.channel_pid, {:reject_access, pa})
      :sys.get_state(socket.channel_pid)

      # Reject fired, AND the authz durability timer is no longer pending.
      assert_push "reject_access", _
      state = :sys.get_state(socket.channel_pid)
      refute Map.has_key?(state.assigns.authz_durability, pa.id)
    end

    test "timer expiry fires :authz_durability_timeout which runs the same eviction as reject_access",
         %{gateway: gateway, site: site, token: token, client: client, resource: resource} do
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      pa = %Portal.PolicyAuthorization{
        id: Ecto.UUID.generate(),
        account_id: gateway.account_id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      }

      generation = make_ref()

      :sys.replace_state(socket.channel_pid, fn state ->
        cache =
          Cache.Gateway.put(
            state.assigns.cache,
            client.id,
            Ecto.UUID.dump!(resource.id),
            pa.id,
            pa.expires_at
          )

        # The handler validates the message's generation against
        # authz_durability — seed both so the synthesized message matches
        # the current entry.
        ref =
          Process.send_after(
            socket.channel_pid,
            {:authz_durability_timeout, pa, generation},
            :timer.hours(1)
          )

        state
        |> put_in([Access.key!(:assigns), :cache], cache)
        |> put_in([Access.key!(:assigns), :authz_durability], %{pa.id => {generation, ref}})
      end)

      # Synthesize the timer firing directly (avoids waiting for the real
      # timer). The generation in the message matches pending → handler acts.
      send(socket.channel_pid, {:authz_durability_timeout, pa, generation})
      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{client_id: client_id, resource_id: resource_id}
      assert client_id == client.id
      assert resource_id == resource.id

      # Cache entry for the pair is gone.
      key = {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)}
      refute Map.has_key?(:sys.get_state(socket.channel_pid).assigns.cache, key)
    end

    test "stale :authz_durability_timeout arriving after :confirm_authz_durability is ignored",
         %{gateway: gateway, site: site, token: token, client: client, resource: resource} do
      # The race we're guarding against: the timer fires (its message lands
      # in the mailbox), and `:confirm_authz_durability` arrives right after.
      # `Process.cancel_timer/1` can't take back a message already delivered,
      # so the stale `:authz_durability_timeout` would otherwise evict a valid authz.
      # The generation token in the message must NOT match the current entry
      # in `authz_durability` after the confirm-driven cancellation, so
      # the handler ignores it.
      socket = join_channel(gateway, site, token)
      assert_push "init", _

      pa = %Portal.PolicyAuthorization{
        id: Ecto.UUID.generate(),
        account_id: gateway.account_id,
        initiating_device_id: client.id,
        receiving_device_id: gateway.id,
        resource_id: resource.id,
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      }

      stale_generation = make_ref()

      :sys.replace_state(socket.channel_pid, fn state ->
        cache =
          Cache.Gateway.put(
            state.assigns.cache,
            client.id,
            Ecto.UUID.dump!(resource.id),
            pa.id,
            pa.expires_at
          )

        # `authz_durability` is empty — simulating the case where the
        # confirm/reject already came in and cleared the entry, but the
        # stale timer message is still in our mailbox.
        state
        |> put_in([Access.key!(:assigns), :cache], cache)
        |> put_in([Access.key!(:assigns), :authz_durability], %{})
      end)

      send(socket.channel_pid, {:authz_durability_timeout, pa, stale_generation})
      :sys.get_state(socket.channel_pid)

      # Must NOT have pushed reject — the message was stale.
      refute_push "reject_access", _

      # Cache entry for the pair must still be present.
      key = {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)}
      assert Map.has_key?(:sys.get_state(socket.channel_pid).assigns.cache, key)
    end
  end

  describe "handle_info/2 presence shard crash" do
    test "re-tracks presence when it receives :DOWN from a monitored presence pid", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      assert Portal.Presence.Gateways.Account.list(gateway.account_id)
             |> Map.has_key?(gateway.id)

      # Simulate a Presence shard crash by sending a :DOWN for one of the
      # monitored presence pids. We can't kill real shards in async tests
      # because they're shared across all tests.
      channel_state = :sys.get_state(socket.channel_pid)
      [{shard_pid, _ref} | _] = channel_state.assigns.presence_monitors
      send(socket.channel_pid, {:DOWN, make_ref(), :process, shard_pid, :killed})
      :sys.get_state(socket.channel_pid)

      assert Portal.Presence.Gateways.Account.list(gateway.account_id)
             |> Map.has_key?(gateway.id)
    end

    test "retries tracking when Presence supervisor name is temporarily unregistered", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      # Temporarily unregister the Presence name so track_presence hits the nil branch
      presence_pid = Process.whereis(Portal.Presence)
      Process.unregister(Portal.Presence)

      send(socket.channel_pid, :track_presence)
      :sys.get_state(socket.channel_pid)

      # Re-register before the 50ms retry fires
      Process.register(presence_pid, Portal.Presence)

      wait_for(fn ->
        :sys.get_state(socket.channel_pid)

        assert Portal.Presence.Gateways.Account.list(gateway.account_id)
               |> Map.has_key?(gateway.id)
      end)
    end

    test "re-tracks presence when already tracked (idempotent)", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      # Send :track_presence while already tracked — should not crash
      send(socket.channel_pid, :track_presence)
      :sys.get_state(socket.channel_pid)

      assert Portal.Presence.Gateways.Account.list(gateway.account_id)
             |> Map.has_key?(gateway.id)
    end
  end

  describe "handle_info/2 :disconnect" do
    test "pushes disconnect event and closes the channel", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      Process.flag(:trap_exit, true)
      join_channel(gateway, site, token)

      assert_push "init", _init_payload

      PG.deliver(gateway.id, :disconnect)

      assert_push "disconnect", %{reason: "token_expired"}
      assert_receive {:EXIT, _pid, :shutdown}
    end

    test "duplicate connection evicts the first gateway", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      Process.flag(:trap_exit, true)
      join_channel(gateway, site, token)

      assert_push "init", _init_payload

      # Simulate a second connection registering for the same gateway
      PG.register(gateway.id)

      assert_push "disconnect", %{reason: "token_expired"}
      assert_receive {:EXIT, _pid, :shutdown}
    end
  end

  describe "session durability fail-safe" do
    test "confirmation cancels the session durability timeout", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      session_id = Ecto.UUID.generate()
      socket = join_channel(gateway, site, token, session_id: session_id)
      assert_push "init", _

      state = :sys.get_state(socket.channel_pid)
      assert {^session_id, generation, _timer_ref} = state.assigns.session_durability

      send(socket.channel_pid, {:confirm_session_durability, session_id})

      state = :sys.get_state(socket.channel_pid)
      assert state.assigns.session_durability == nil

      send(socket.channel_pid, {:session_durability_timeout, session_id, generation})
      refute_push "disconnect", _
    end

    test "matching session durability timeout disconnects the gateway without pushing token_expired",
         %{
           gateway: gateway,
           site: site,
           token: token
         } do
      Process.flag(:trap_exit, true)

      session_id = Ecto.UUID.generate()
      socket = join_channel(gateway, site, token, session_id: session_id)
      assert_push "init", _

      state = :sys.get_state(socket.channel_pid)
      assert {^session_id, generation, _timer_ref} = state.assigns.session_durability

      send(socket.channel_pid, {:session_durability_timeout, session_id, generation})

      assert_receive {:EXIT, _pid, :shutdown}
      refute_push "disconnect", _
    end
  end

  describe "handle_info/2 :disconnect regression — shared token" do
    test "multiple gateways sharing a token are not disconnected by each other", %{
      account: account,
      site: site,
      token: token
    } do
      Process.flag(:trap_exit, true)

      gateway1 = gateway_fixture(account: account, site: site)
      gateway2 = gateway_fixture(account: account, site: site)

      socket1 = join_channel(gateway1, site, token)
      assert_push "init", _

      socket2 = join_channel(gateway2, site, token)
      assert_push "init", _

      # Both channels should still be alive — sharing a token must not
      # cause one to evict the other (regression: PG.register on token_id
      # used to send :disconnect to all existing members)
      assert Process.alive?(socket1.channel_pid)
      assert Process.alive?(socket2.channel_pid)

      # Neither channel should have received a disconnect push
      refute_push "disconnect", _
    end
  end

  describe "handle_info/2" do
    test "ignores out of order %Change{}", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      send(socket.channel_pid, %Changes.Change{lsn: 100})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)

      send(socket.channel_pid, %Changes.Change{lsn: 50})

      assert %{assigns: %{last_lsn: 100}} = :sys.get_state(socket.channel_pid)
    end

    test ":prune_cache removes key completely when all policy authorizations are expired", %{
      account: account,
      actor: actor,
      client: client,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      expired_policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      expired_expiration = DateTime.utc_now() |> DateTime.add(-30, :second)
      channel_pid = self()
      socket_ref = make_ref()
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: expired_policy_authorization.id,
           authorization_expires_at: expired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", _payload

      cid_bytes = Ecto.UUID.dump!(client.id)
      rid_bytes = Ecto.UUID.dump!(resource.id)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => _policy_authorizations
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      send(socket.channel_pid, :prune_cache)

      assert %{
               assigns: %{
                 cache: %{}
               }
             } = :sys.get_state(socket.channel_pid)
    end

    test ":prune_cache prunes only expired policy authorizations from the cache", %{
      account: account,
      actor: actor,
      client: client,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      expired_policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      unexpired_policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      expired_expiration = DateTime.utc_now() |> DateTime.add(-30, :second)
      unexpired_expiration = DateTime.utc_now() |> DateTime.add(30, :second)

      channel_pid = self()
      socket_ref = make_ref()
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: expired_policy_authorization.id,
           authorization_expires_at: expired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", _payload

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: unexpired_policy_authorization.id,
           authorization_expires_at: unexpired_expiration,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      cid_bytes = Ecto.UUID.dump!(client.id)
      rid_bytes = Ecto.UUID.dump!(resource.id)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => authorizations
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      assert authorizations == %{
               Ecto.UUID.dump!(expired_policy_authorization.id) =>
                 DateTime.to_unix(expired_expiration, :second),
               Ecto.UUID.dump!(unexpired_policy_authorization.id) =>
                 DateTime.to_unix(unexpired_expiration, :second)
             }

      send(socket.channel_pid, :prune_cache)

      assert %{
               assigns: %{
                 cache: %{
                   {^cid_bytes, ^rid_bytes} => authorizations
                 }
               }
             } = :sys.get_state(socket.channel_pid)

      assert authorizations == %{
               Ecto.UUID.dump!(unexpired_policy_authorization.id) =>
                 DateTime.to_unix(unexpired_expiration, :second)
             }
    end

    test "resends init when account slug changes", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: account,
        struct: %{account | slug: "new-slug"}
      })

      :sys.get_state(socket.channel_pid)

      assert_push "init", payload

      assert payload.account_slug == "new-slug"
    end

    test "resends init when gateway tunnel IPs change", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      new_ipv4 = valid_ipv4_address_attrs().address
      new_ipv6 = valid_ipv6_address_attrs().address
      updated_gateway = %{gateway | ipv4: new_ipv4, ipv6: new_ipv6}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: gateway,
        struct: updated_gateway
      })

      assert_push "init", %{interface: %{ipv4: ^new_ipv4, ipv6: ^new_ipv6}}

      assert %{
               assigns: %{
                 gateway: %{ipv4: ^new_ipv4, ipv6: ^new_ipv6}
               }
             } = :sys.get_state(socket.channel_pid)
    end

    test "updates gateway state without resending init when tunnel IPs are unchanged", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      lsn = System.unique_integer([:positive, :monotonic])
      updated_gateway = %{gateway | name: "Renamed gateway"}

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: gateway,
        struct: updated_gateway
      })

      :sys.get_state(socket.channel_pid)

      refute_push "init", _

      assert %{assigns: %{gateway: %{name: "Renamed gateway"}}} =
               :sys.get_state(socket.channel_pid)
    end

    test "ignores DOWN messages from unrelated processes", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      stranger = spawn(fn -> :ok end)

      send(socket.channel_pid, {:DOWN, make_ref(), :process, stranger, :normal})

      # Channel should keep running and remain joined.
      assert :sys.get_state(socket.channel_pid)
    end

    test "load-balances relays with mixed nil and non-nil locations", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Mix of relays with and without lat/lon to exercise the nils_last comparator
      # in both pairwise orders during sort.
      relay_with_loc = relay_fixture(%{lat: 37.0, lon: -120.0})
      :ok = Portal.Presence.Relays.connect(relay_with_loc)

      relay_no_lat = relay_fixture(%{lat: nil, lon: -121.0})
      :ok = Portal.Presence.Relays.connect(relay_no_lat)

      relay_no_lon = relay_fixture(%{lat: 37.5, lon: nil})
      :ok = Portal.Presence.Relays.connect(relay_no_lon)

      _socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: relays}

      assert is_list(relays)
    end

    test "pushes disconnect event and closes when the token is deleted", %{
      account: account,
      gateway: gateway,
      site: site,
      token: token
    } do
      Process.flag(:trap_exit, true)
      join_channel(gateway, site, token)

      assert_push "init", _init_payload

      data = %{
        "id" => token.id,
        "account_id" => account.id,
        "type" => "site"
      }

      lsn = System.unique_integer([:positive, :monotonic])
      Changes.Hooks.GatewayTokens.on_delete(lsn, data)

      assert_push "disconnect", %{reason: "token_expired"}
      assert_receive {:EXIT, _pid, :shutdown}
    end

    test "disconnect socket when gateway is deleted", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      Process.flag(:trap_exit, true)

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: gateway
      })

      assert_receive {:EXIT, _pid, _reason}
    end

    test "pushes allow_access message", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", payload

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: []
             }

      assert payload.ref
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4
      assert payload.client_ipv6 == client.ipv6
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "pushes allow_access message for internet resource", %{
      account: account,
      actor: actor,
      client: client,
      gateway: gateway,
      relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      # Consume the init message from join
      assert_push "init", _init_payload

      internet_site = internet_site_fixture(account: account)

      resource =
        internet_resource_fixture(
          account: account,
          site: internet_site
        )

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      :ok = Portal.Presence.Relays.connect(relay)

      # Consume the relays_presence message from relay connection
      assert_push "relays_presence", _relays_presence

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", payload

      assert payload.resource == %{
               id: resource.id,
               type: :internet
             }

      assert payload.ref
      assert payload.client_id == client.id
      assert payload.client_ipv4 == client.ipv4
      assert payload.client_ipv6 == client.ipv6
      assert DateTime.from_unix!(payload.expires_at) == DateTime.truncate(expires_at, :second)
    end

    test "does nothing when resource is incompatible with gateway version", %{
      account: account,
      actor: actor,
      client: client,
      site: site,
      token: token,
      group: group
    } do
      # Gateway with version 1.2.0 cannot handle internet resources (requires >= 1.3.0)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_version: "1.2.0"
        )

      internet_site = internet_site_fixture(account: account)

      resource =
        internet_resource_fixture(
          account: account,
          site: internet_site
        )

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: "DNS_Q"
         }}
      )

      :sys.get_state(socket.channel_pid)
      refute_push "allow_access", _
    end

    test "does not send reject_access if another policy authorization is granting access to the same client and resource",
         %{
           account: account,
           actor: actor,
           client: client,
           resource: resource,
           gateway: gateway,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      client_payload = "RTC_SD_or_DNS_Q"

      in_one_hour = DateTime.utc_now() |> DateTime.add(1, :hour)
      in_one_day = DateTime.utc_now() |> DateTime.add(1, :day)

      policy_authorization1 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          gateway: gateway,
          resource: resource,
          expires_at: in_one_hour,
          group: group
        )

      policy_authorization2 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          gateway: gateway,
          resource: resource,
          expires_at: in_one_day,
          group: group
        )

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization1.id,
           authorization_expires_at: policy_authorization1.expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization2.id,
           authorization_expires_at: policy_authorization2.expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: policy_authorization1
      })

      :sys.get_state(socket.channel_pid)

      refute_push "allow_access", _payload
      refute_push "reject_access", %{}

      assert_push "access_authorization_expiry_updated", payload

      assert payload == %{
               client_id: client.id,
               resource_id: resource.id,
               expires_at: DateTime.to_unix(policy_authorization2.expires_at, :second)
             }
    end

    test "handles policy authorization deletion event when access is removed", %{
      account: account,
      actor: actor,
      client: client,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)

      # Consume init message from join
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: policy_authorization
      })

      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "does nothing when deleted policy authorization is not in the cache",
         %{
           account: account,
           actor: actor,
           client: client,
           resource: resource,
           gateway: gateway,
           site: site,
           token: token,
           group: group
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      # Create a policy_authorization but do NOT send :allow_access, so the
      # gateway cache never learns about it.
      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: policy_authorization
      })

      :sys.get_state(socket.channel_pid)

      refute_push "reject_access", _
      refute_push "allow_access", _
    end

    test "ignores policy authorization deletion for other policy authorizations",
         %{
           account: account,
           actor: actor,
           client: client,
           resource: resource,
           gateway: gateway,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      other_client = client_fixture(account: account, actor: actor) |> then(&fetch_device!/1)

      other_resource =
        resource_fixture(
          account: account,
          site: site
        )

      other_policy_authorization1 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: other_client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      other_policy_authorization2 =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: other_resource,
          gateway: gateway,
          group: group
        )

      # Build up policy authorization cache
      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: other_client.id,
           client_ipv4: other_client.ipv4,
           client_ipv6: other_client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: other_policy_authorization1.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(other_resource),
           policy_authorization_id: other_policy_authorization2.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      assert %{assigns: %{cache: cache}} =
               :sys.get_state(socket.channel_pid)

      assert cache == %{
               {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(resource.id)} => %{
                 Ecto.UUID.dump!(policy_authorization.id) => DateTime.to_unix(expires_at, :second)
               },
               {Ecto.UUID.dump!(other_client.id), Ecto.UUID.dump!(resource.id)} => %{
                 Ecto.UUID.dump!(other_policy_authorization1.id) =>
                   DateTime.to_unix(expires_at, :second)
               },
               {Ecto.UUID.dump!(client.id), Ecto.UUID.dump!(other_resource.id)} => %{
                 Ecto.UUID.dump!(other_policy_authorization2.id) =>
                   DateTime.to_unix(expires_at, :second)
               }
             }

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: other_policy_authorization1
      })

      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == other_client.id
      assert resource_id == resource.id

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: other_policy_authorization2
      })

      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == other_resource.id

      refute_push "reject_access", _payload
    end

    test "ignores other resource updates", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: resource,
        struct: %{resource | name: "New Resource Name"}
      })

      cid_bytes = Ecto.UUID.dump!(client.id)
      rid_bytes = Ecto.UUID.dump!(resource.id)
      paid_bytes = Ecto.UUID.dump!(policy_authorization.id)
      expires_at_unix = DateTime.to_unix(expires_at, :second)

      assert %{
               assigns: %{
                 cache: %{{^cid_bytes, ^rid_bytes} => %{^paid_bytes => ^expires_at_unix}}
               }
             } = :sys.get_state(socket.channel_pid)

      refute_push "resource_updated", _payload
    end

    test "sends reject_access when resource addressability changes", %{
      client: client,
      gateway: gateway,
      account: account,
      actor: actor,
      resource: resource,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: resource,
        struct: %{resource | address: "new-address"}
      })

      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", payload

      assert payload == %{
               client_id: client.id,
               resource_id: resource.id
             }
    end

    test "sends resource_updated when filters change", %{
      client: client,
      gateway: gateway,
      account: account,
      actor: actor,
      resource: resource,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"

      send(
        socket.channel_pid,
        {:allow_access, {channel_pid, socket_ref},
         %{
           client_id: client.id,
           client_ipv4: client.ipv4,
           client_ipv6: client.ipv6,
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           client_payload: client_payload
         }}
      )

      assert_push "allow_access", %{}

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      filters = [
        %{"protocol" => "tcp", "ports" => ["80", "433"]},
        %{"protocol" => "udp", "ports" => ["100-200"]},
        %{"protocol" => "icmp"}
      ]

      data = Map.put(old_data, "filters", filters)

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: struct_from_params(Portal.Resource, old_data),
        struct: struct_from_params(Portal.Resource, data)
      })

      :sys.get_state(socket.channel_pid)

      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_start: 100, port_range_end: 200},
                 %{protocol: :icmp}
               ]
             }
    end

    test "sends resource_updated when filters change even without resource in cache", %{
      resource: resource,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      # The resource is already connected to the gateway via the setup
      # No policy authorizations exist yet, so the resource isn't in the cache

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      filters = [
        %{"protocol" => "tcp", "ports" => ["443"]},
        %{"protocol" => "udp", "ports" => ["53"]}
      ]

      data = Map.put(old_data, "filters", filters)

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: struct_from_params(Portal.Resource, old_data),
        struct: struct_from_params(Portal.Resource, data)
      })

      :sys.get_state(socket.channel_pid)

      # Should still receive the update even though resource isn't in cache
      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_start: 443, port_range_end: 443},
                 %{protocol: :udp, port_range_start: 53, port_range_end: 53}
               ]
             }
    end

    test "handles resource_updated with version adaptation for old gateways", %{
      gateway: gateway,
      resource: resource,
      site: site,
      token: token
    } do
      # Create a new socket with the session set to an old version (< 1.2.0)
      session = %{build_gateway_session(gateway, token) | version: "1.1.0"}

      {:ok, _, socket} =
        PortalAPI.Gateway.Socket
        |> socket("gateway:#{gateway.id}", %{
          token_id: token.id,
          gateway: gateway,
          session: session,
          site: site,
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
        })
        |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", _init_payload

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => resource.address,
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      filters = [
        %{"protocol" => "tcp", "ports" => ["443"]},
        %{"protocol" => "udp", "ports" => ["53"]}
      ]

      data = Map.put(old_data, "filters", filters)

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: struct_from_params(Portal.Resource, old_data),
        struct: struct_from_params(Portal.Resource, data)
      })

      :sys.get_state(socket.channel_pid)

      # Gateway with version 1.1.0 should receive the adapted resource
      assert_push "resource_updated", payload

      assert payload == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_start: 443, port_range_end: 443},
                 %{protocol: :udp, port_range_start: 53, port_range_end: 53}
               ]
             }
    end

    test "does not send resource_updated when DNS adaptation fails", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      # Update the channel process state to use an old gateway version (< 1.2.0)
      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns.session.version, "1.1.0")
      end)

      # Create a DNS resource with an address that can't be adapted
      # For pre-1.2.0, addresses with wildcards not at the beginning get dropped
      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          address: "example.*.com"
        )

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => "example.*.com",
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      # Only change filters to trigger the filter-change handler
      data = Map.put(old_data, "filters", [%{"protocol" => "tcp", "ports" => ["443"]}])

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: struct_from_params(Portal.Resource, old_data),
        struct: struct_from_params(Portal.Resource, data)
      })

      :sys.get_state(socket.channel_pid)

      # Should not receive any update since the address can't be adapted for version < 1.2.0
      refute_push "resource_updated", _payload
    end

    test "adapts DNS resource address for old gateway versions", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      # Update the channel process state to use an old gateway version (< 1.2.0)
      :sys.replace_state(socket.channel_pid, fn state ->
        put_in(state.assigns.session.version, "1.1.0")
      end)

      # Create a DNS resource with an address that needs adaptation for old versions
      # Use the existing account from setup so the channel receives the update
      resource =
        dns_resource_fixture(
          account: account,
          site: site,
          address: "**.example.com"
        )

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "address" => "**.example.com",
        "name" => resource.name,
        "type" => "dns",
        "filters" => [],
        "ip_stack" => "dual"
      }

      # Only change filters, not address, to trigger the filter-change handler
      data = Map.put(old_data, "filters", [%{"protocol" => "tcp", "ports" => ["443"]}])

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: struct_from_params(Portal.Resource, old_data),
        struct: struct_from_params(Portal.Resource, data)
      })

      :sys.get_state(socket.channel_pid)

      # Should receive the update with the adapted address (** becomes * for pre-1.2.0)
      assert_push "resource_updated", payload

      assert payload == %{
               # ** was converted to *
               address: "*.example.com",
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: [
                 %{protocol: :tcp, port_range_start: 443, port_range_end: 443}
               ]
             }
    end

    test "does not send resource_updated for static_device_pool filter changes", %{
      gateway: gateway,
      site: site,
      token: token,
      account: account
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      resource = static_device_pool_resource_fixture(account: account)

      old_data = %{
        "id" => resource.id,
        "account_id" => resource.account_id,
        "name" => resource.name,
        "type" => "static_device_pool",
        "filters" => [],
        "ip_stack" => nil
      }

      filters = [%{"protocol" => "tcp", "ports" => ["80"]}]
      data = Map.put(old_data, "filters", filters)

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :update,
        old_struct: struct_from_params(Portal.Resource, old_data),
        struct: struct_from_params(Portal.Resource, data)
      })

      :sys.get_state(socket.channel_pid)

      refute_push "resource_updated", _
    end

    test "subscribes for relays presence", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Use a small non-zero debounce to avoid timing races in presence_diff handling.
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 50)

      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})
      :ok = Portal.Presence.Relays.connect(relay1)

      relay2 = relay_fixture(%{lat: 38.0, lon: -121.0})
      :ok = Portal.Presence.Relays.connect(relay2)

      session = build_gateway_session(gateway, token)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        session: session,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view | _] = relays}
      relay_view_ids = Enum.map(relays, & &1.id) |> Enum.uniq() |> Enum.sort()
      relay_ids = [relay1.id, relay2.id] |> Enum.sort()
      assert relay_view_ids == relay_ids

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      # Untrack from global topic to trigger presence change notification
      Portal.Presence.Relays.disconnect(relay1)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: [relay_view1, relay_view2]
                  },
                  200

      assert relay_view1.id == relay2.id
      assert relay_view2.id == relay2.id
      assert relay1_id == relay1.id
    end

    test "subscribes for account relays presence if there were no relays online", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Use a small non-zero debounce to make presence updates deterministic.
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 50)

      relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      session = build_gateway_session(gateway, token)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        session: session,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: []}

      :ok = Portal.Presence.Relays.connect(relay)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [relay_view, _relay_view]
                  },
                  200

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      # Connect a second relay - should receive relays_presence since we have < 2 relays
      other_relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(other_relay)

      # Should receive update for second relay since we only had 1 relay cached
      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: _connected
                  },
                  200

      # Now connect a third relay - should NOT receive relays_presence since we have >= 2 relays
      third_relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(third_relay)
      third_relay_id = third_relay.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [%{id: ^third_relay_id} | _]
                  },
                  200
    end

    test "relay credentials are stable across reconnects", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay = relay_fixture(%{lat: 37.0, lon: -120.0})
      :ok = Portal.Presence.Relays.connect(relay)

      Process.flag(:trap_exit, true)

      socket1 = join_channel(gateway, site, token)
      assert_push "init", %{relays: relays1}

      Process.exit(socket1.channel_pid, :shutdown)
      assert_receive {:EXIT, _, :shutdown}

      socket2 = join_channel(gateway, site, token)
      assert_push "init", %{relays: relays2}

      Process.exit(socket2.channel_pid, :shutdown)
      assert_receive {:EXIT, _, :shutdown}

      assert relays1 == relays2
    end

    test "pushes ice_candidates message", %{
      client: client,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {:ice_candidates, client.id, candidates}
      )

      assert_push "ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               client_id: client.id
             }
    end

    test "pushes invalidate_ice_candidates message", %{
      client: client,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {:invalidate_ice_candidates, client.id, candidates}
      )

      assert_push "invalidate_ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               client_id: client.id
             }
    end

    test "pushes request_connection message", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      global_relay: relay,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      client_payload = "RTC_SD"
      public_key = Portal.DeviceFixtures.generate_public_key()

      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render_legacy(
               client,
               public_key,
               client_payload,
               preshared_key
             ),
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at
         }}
      )

      assert_push "request_connection", payload

      assert is_binary(payload.ref)

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: []
             }

      assert payload.client == %{
               id: client.id,
               peer: %{
                 ipv4: client.ipv4,
                 ipv6: client.ipv6,
                 persistent_keepalive: 25,
                 preshared_key: preshared_key,
                 public_key: public_key
               },
               payload: client_payload
             }

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "does nothing when resource is incompatible with gateway version (request_connection)",
         %{
           account: account,
           actor: actor,
           client: client,
           site: site,
           token: token,
           group: group
         } do
      # Gateway with version 1.2.0 cannot handle internet resources (requires >= 1.3.0)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_version: "1.2.0"
        )

      internet_site = internet_site_fixture(account: account)

      resource =
        internet_resource_fixture(
          account: account,
          site: internet_site
        )

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render_legacy(
               client,
               public_key,
               "RTC_SD",
               preshared_key
             ),
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at
         }}
      )

      :sys.get_state(socket.channel_pid)
      refute_push "request_connection", _
    end

    test "request_connection tracks policy authorization and sends reject_access when policy authorization is deleted",
         %{
           account: account,
           actor: actor,
           client: client,
           gateway: gateway,
           resource: resource,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      client_payload = "RTC_SD_or_DNS_Q"
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render_legacy(
               client,
               public_key,
               client_payload,
               preshared_key
             ),
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at
         }}
      )

      assert_push "request_connection", %{}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: policy_authorization
      })

      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end

    test "pushes authorize_flow message", %{
      client: client,
      account: account,
      actor: actor,
      gateway: gateway,
      resource: resource,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", payload

      assert is_binary(payload.ref)

      assert payload.resource == %{
               address: resource.address,
               id: resource.id,
               name: resource.name,
               type: :dns,
               filters: []
             }

      assert payload.client == %{
               id: client.id,
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               preshared_key: preshared_key,
               public_key: public_key,
               version: "1.3.0",
               device_serial: client.device_serial,
               device_uuid: client.device_uuid,
               identifier_for_vendor: client.identifier_for_vendor,
               firebase_installation_id: client.firebase_installation_id,
               # These are parsed from the user agent
               device_os_name: "macOS",
               device_os_version: "14.0"
             }

      assert payload.subject == PortalAPI.Gateway.Views.Subject.render(subject)

      assert payload.client_ice_credentials == ice_credentials.initiator
      assert payload.gateway_ice_credentials == ice_credentials.receiver

      assert DateTime.from_unix!(payload.expires_at) ==
               DateTime.truncate(expires_at, :second)
    end

    test "authorize_flow tracks policy authorization and sends reject_access when policy authorization is deleted",
         %{
           account: account,
           actor: actor,
           client: client,
           gateway: gateway,
           resource: resource,
           site: site,
           token: token,
           subject: subject,
           group: group
         } do
      socket = join_channel(gateway, site, token)
      assert_push "init", _init_payload

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          subject: subject,
          client: client,
          resource: resource,
          gateway: gateway,
          group: group
        )

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", %{}

      lsn = System.unique_integer([:positive, :monotonic])

      send(socket.channel_pid, %Changes.Change{
        lsn: lsn,
        op: :delete,
        old_struct: policy_authorization
      })

      :sys.get_state(socket.channel_pid)

      assert_push "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      }

      assert client_id == client.id
      assert resource_id == resource.id
    end
  end

  describe "handle_in/3" do
    test "for unknown messages it doesn't crash", %{gateway: gateway, site: site, token: token} do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end

    test "no_relays sends relays_presence with 2 selected relays", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})
      :ok = Portal.Presence.Relays.connect(relay1)

      relay2 = relay_fixture(%{lat: 38.0, lon: -121.0})
      :ok = Portal.Presence.Relays.connect(relay2)

      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      push(socket, "no_relays", %{})

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [relay_view | _] = relays
                  }

      assert length(relays) == 4

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq() |> Enum.sort()
      assert relay_ids == [relay1.id, relay2.id] |> Enum.sort()
    end

    test "no_relays sends relays_presence with empty connected when no relays are online", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: []}

      push(socket, "no_relays", %{})

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: []
                  }
    end

    test "flow_authorized forwards reply to the client channel", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()
      site_id = gateway.site_id
      gateway_id = gateway.id
      gateway_public_key = gateway.latest_session.public_key
      gateway_ipv4 = gateway.ipv4
      gateway_ipv6 = gateway.ipv6
      rid_bytes = Ecto.UUID.dump!(resource.id)

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", %{ref: ref}
      push_ref = push(socket, "flow_authorized", %{"ref" => ref})

      assert_reply push_ref, :ok

      assert_receive {
        :connect,
        ^socket_ref,
        ^rid_bytes,
        ^site_id,
        ^gateway_id,
        ^gateway_public_key,
        ^gateway_ipv4,
        ^gateway_ipv6,
        ^preshared_key,
        ^ice_credentials,
        _iceless
      }
    end

    test "authorize_policy intersects gateway and client snownet capabilities", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      # Gateway advertises iceless capability via the dedicated channel message.
      push(socket, "set_snownet_capabilities", %{"iceless" => true})

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      # Both sides advertise iceless → negotiated set is iceless: true.
      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           client_iceless: true
         }}
      )

      assert_push "authorize_flow", %{
        ref: ref,
        snownet_capabilities: %{iceless: true}
      }

      push_ref = push(socket, "flow_authorized", %{"ref" => ref})
      assert_reply push_ref, :ok

      assert_receive {:connect, ^socket_ref, _, _, _, _, _, _, _, _, iceless}
      assert iceless == true
    end

    test "authorize_policy with mismatched iceless flag intersects to false", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      # Gateway is iceless-capable; client isn't.
      push(socket, "set_snownet_capabilities", %{"iceless" => true})

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key,
           client_iceless: false
         }}
      )

      assert_push "authorize_flow", %{
        ref: _,
        snownet_capabilities: %{iceless: false}
      }
    end

    test "authorize_policy without client_iceless defaults to false", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      gateway: gateway,
      site: site,
      token: token,
      subject: subject,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      # Even with iceless-capable gateway, missing client caps → false.
      push(socket, "set_snownet_capabilities", %{"iceless" => true})

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()

      ice_credentials = %{
        initiator: %{username: "A", password: "B"},
        receiver: %{username: "C", password: "D"}
      }

      send(
        socket.channel_pid,
        {:authorize_policy, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render(
               client,
               public_key,
               preshared_key,
               @test_user_agent
             ),
           subject: PortalAPI.Gateway.Views.Subject.render(subject),
           resource: PortalAPI.Gateway.Views.Resource.render(to_cache(resource)),
           resource_id: to_cache(resource).id,
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at,
           ice_credentials: ice_credentials,
           preshared_key: preshared_key
         }}
      )

      assert_push "authorize_flow", %{
        ref: _,
        snownet_capabilities: %{iceless: false}
      }
    end

    test "flow_authorized pushes an error when ref is invalid", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      push_ref =
        push(socket, "flow_authorized", %{
          "ref" => "foo"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
    end

    test "connection ready forwards RFC session description to the client channel", %{
      client: client,
      account: account,
      actor: actor,
      resource: resource,
      relay: relay,
      gateway: gateway,
      site: site,
      token: token,
      group: group
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      policy_authorization =
        policy_authorization_fixture(
          account: account,
          actor: actor,
          client: client,
          resource: resource,
          group: group
        )

      channel_pid = self()
      socket_ref = make_ref()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :second)
      preshared_key = "PSK"
      public_key = Portal.DeviceFixtures.generate_public_key()
      gateway_public_key = gateway.latest_session.public_key
      payload = "RTC_SD"

      :ok = Portal.Presence.Relays.connect(relay)

      send(
        socket.channel_pid,
        {:request_connection, {channel_pid, socket_ref},
         %{
           client:
             PortalAPI.Gateway.Views.Client.render_legacy(
               client,
               public_key,
               payload,
               preshared_key
             ),
           resource: to_cache(resource),
           policy_authorization_id: policy_authorization.id,
           authorization_expires_at: expires_at
         }}
      )

      assert_push "request_connection", %{
        ref: ref,
        client: %{
          peer: peer,
          id: client_id
        },
        resource: re,
        expires_at: ex
      }

      assert is_binary(ref)
      assert client_id == client.id
      assert peer.ipv4 == client.ipv4
      assert peer.ipv6 == client.ipv6
      assert peer.public_key == public_key
      assert peer.persistent_keepalive == 25
      assert peer.preshared_key == preshared_key
      assert re.id == resource.id
      assert DateTime.from_unix!(ex) == DateTime.truncate(expires_at, :second)

      push_ref =
        push(socket, "connection_ready", %{
          "ref" => ref,
          "gateway_payload" => payload
        })

      assert_reply push_ref, :ok
      assert_receive {:connect, ^socket_ref, rid_bytes, ^gateway_public_key, ^payload}
      assert Ecto.UUID.load!(rid_bytes) == resource.id
    end

    test "connection_ready pushes an error when ref is invalid", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      push_ref =
        push(socket, "connection_ready", %{
          "ref" => "foo",
          "gateway_payload" => "bar"
        })

      assert_reply push_ref, :error, %{reason: :invalid_ref}
    end

    test "broadcast ice candidates does nothing when gateways list is empty", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => []
      }

      push(socket, "broadcast_ice_candidates", attrs)
      refute_receive {:ice_candidates, _client_id, _candidates}
    end

    test "broadcasts :ice_candidates message to the target gateway", %{
      client: client,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      :ok = PG.register(client.id)

      push(socket, "broadcast_ice_candidates", attrs)

      assert_receive {:ice_candidates, gateway_id, ^candidates},
                     200

      assert gateway.id == gateway_id
    end

    test "broadcast_invalidated_ice_candidates does nothing when gateways list is empty", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => []
      }

      push(socket, "broadcast_invalidated_ice_candidates", attrs)
      refute_receive {:invalidate_ice_candidates, _gateway_id, _candidates}
    end

    test "broadcasts :invalidate_ice_candidates message to all gateways", %{
      client: client,
      gateway: gateway,
      site: site,
      token: token
    } do
      socket = join_channel(gateway, site, token)
      assert_push "init", %{relays: _}

      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "client_ids" => [client.id]
      }

      :ok = PG.register(client.id)

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      assert_receive {:invalidate_ice_candidates, gateway_id, ^candidates},
                     200

      assert gateway.id == gateway_id
    end
  end

  # Relay presence tests (CRDT-based, no debouncing)
  describe "handle_info/3 for presence events" do
    test "does not send disconnect when relay reconnects with same stamp secret", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Use a non-zero debounce so disconnect + reconnect with the same relay ID
      # are coalesced into a single presence check.
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 50)

      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay1)

      session = build_gateway_session(gateway, token)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        session: session,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect then reconnect with same stamp secret (simulating transient disconnect)
      Portal.Presence.Relays.disconnect(relay1)
      :ok = Portal.Presence.Relays.connect(relay1)

      # Should not receive any disconnect since relay is still online with same secret
      relay_id = relay1.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [^relay_id]
                  },
                  200
    end

    test "sends disconnect when relay reconnects with different stamp secret", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Use a non-zero debounce so both disconnect and reconnect presence_diff events
      # are captured in the same window and delivered as one combined message.
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 10)

      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay1)

      session = build_gateway_session(gateway, token)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        session: session,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Reconnect with a different stamp secret (relay process restarted)
      Portal.Presence.Relays.disconnect(relay1)
      new_stamp_secret = Portal.Crypto.random_token()

      relay1_reconnected = %{
        relay1
        | stamp_secret: new_stamp_secret,
          id: Portal.Relay.generate_id(new_stamp_secret)
      }

      :ok = Portal.Presence.Relays.connect(relay1_reconnected)

      # Should receive disconnect since stamp_secret changed (new ID for connected, old ID for disconnected)
      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: [relay_id]
                  },
                  100

      # The connected relay views have the NEW ID (from the new stamp_secret)
      assert relay_view1.id == relay1_reconnected.id
      assert relay_view2.id == relay1_reconnected.id
      # The disconnected ID is the OLD ID
      assert relay_id == relay1.id
    end

    test "sends disconnect when relay goes offline", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      relay1 = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay1)

      session = build_gateway_session(gateway, token)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        session: session,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [relay_view1, relay_view2]}
      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      # Disconnect relay - should send disconnect immediately (no debouncing)
      Portal.Presence.Relays.disconnect(relay1)

      assert_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [relay_id]
                  },
                  100

      assert relay_id == relay1.id
    end

    test "disconnected_ids only contains relays that are truly offline", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # This test validates that disconnected_ids only contains relays that are
      # no longer in presence (truly offline), not relays that happen to not be
      # selected by load balancing.
      #
      # The fix uses a single presence snapshot for both:
      # 1. Determining which cached relays are now offline (disconnected_ids)
      # 2. Selecting the best relays to send to the gateway (connected)
      #
      # This ensures a relay can never appear in both lists due to CRDT
      # eventual consistency during rapid disconnect/reconnect cycles.

      relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      :ok = Portal.Presence.Relays.connect(relay)

      session = build_gateway_session(gateway, token)

      PortalAPI.Gateway.Socket
      |> socket("gateway:#{gateway.id}", %{
        token_id: token.id,
        gateway: gateway,
        session: session,
        site: site,
        opentelemetry_ctx: OpenTelemetry.Ctx.new(),
        opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test")
      })
      |> subscribe_and_join(PortalAPI.Gateway.Channel, "gateway")

      assert_push "init", %{relays: [_, _]}

      # Disconnect and immediately reconnect - without the fix, this could cause
      # the relay to appear in both connected and disconnected_ids
      Portal.Presence.Relays.disconnect(relay)
      :ok = Portal.Presence.Relays.connect(relay)

      # If we receive any relays_presence message, verify the invariant:
      # a relay should NEVER appear in both connected and disconnected_ids
      receive do
        %Phoenix.Socket.Message{event: "relays_presence", payload: payload} ->
          connected_ids = MapSet.new(payload.connected, & &1.id)
          disconnected_ids = MapSet.new(payload.disconnected_ids)

          intersection = MapSet.intersection(connected_ids, disconnected_ids)

          assert MapSet.size(intersection) == 0,
                 "Relay IDs #{inspect(MapSet.to_list(intersection))} appear in both " <>
                   "connected and disconnected_ids - disconnected_ids should only " <>
                   "contain relays that are truly offline"
      after
        100 ->
          # No message received is also acceptable - relay reconnected before
          # the presence check ran, so no update was needed
          :ok
      end
    end

    test "selects closest relays by distance when gateway has location", %{
      account: account,
      site: site,
      token: token
    } do
      # Create gateway in Texas (Houston area)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Create relays at different distances from Texas
      # Kansas (~930km from Houston)
      relay_kansas = relay_fixture(%{lat: 38.0, lon: -97.0})

      # Mexico (~1100km from Houston)
      relay_mexico = relay_fixture(%{lat: 20.59, lon: -100.39})

      # Sydney, Australia (~13700km from Houston)
      relay_sydney = relay_fixture(%{lat: -33.87, lon: 151.21})

      # Connect all relays
      :ok = Portal.Presence.Relays.connect(relay_kansas)
      :ok = Portal.Presence.Relays.connect(relay_mexico)
      :ok = Portal.Presence.Relays.connect(relay_sydney)

      join_channel(gateway, site, token)

      # Should receive the 2 closest relays (Kansas and Mexico), not Sydney
      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      assert relay_kansas.id in relay_ids
      assert relay_mexico.id in relay_ids
      refute relay_sydney.id in relay_ids
    end

    test "selects closest relays even when multiple relays share the same location", %{
      account: account,
      site: site,
      token: token
    } do
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # 2 relays in Kansas at the SAME coordinates (~930km from Houston)
      relay_kansas_1 = relay_fixture(%{lat: 38.0, lon: -97.0})
      relay_kansas_2 = relay_fixture(%{lat: 38.0, lon: -97.0})

      # 8 distant relays
      distant_locations = [
        {-33.87, 151.21},
        {35.68, 139.69},
        {51.51, -0.13},
        {-33.93, 18.42},
        {19.08, 72.88},
        {1.35, 103.82},
        {-36.85, 174.76},
        {55.76, 37.62}
      ]

      distant_relays =
        Enum.map(distant_locations, fn {lat, lon} ->
          relay_fixture(%{lat: lat, lon: lon})
        end)

      :ok = Portal.Presence.Relays.connect(relay_kansas_1)
      :ok = Portal.Presence.Relays.connect(relay_kansas_2)

      for relay <- distant_relays do
        :ok = Portal.Presence.Relays.connect(relay)
      end

      join_channel(gateway, site, token)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()
      distant_relay_ids = Enum.map(distant_relays, & &1.id)

      assert relay_kansas_1.id in relay_ids
      assert relay_kansas_2.id in relay_ids

      for distant_id <- distant_relay_ids do
        refute distant_id in relay_ids
      end
    end

    test "prefers relays with location over relays without location", %{
      account: account,
      site: site,
      token: token
    } do
      # Create gateway in Texas (Houston area)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Create relays with location
      relay_with_location_1 = relay_fixture(%{lat: 38.0, lon: -97.0})
      relay_with_location_2 = relay_fixture(%{lat: 20.59, lon: -100.39})

      # Create relay without location (nil lat/lon)
      relay_without_location = relay_fixture()

      :ok = Portal.Presence.Relays.connect(relay_with_location_1)
      :ok = Portal.Presence.Relays.connect(relay_with_location_2)
      :ok = Portal.Presence.Relays.connect(relay_without_location)

      join_channel(gateway, site, token)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      # Should prefer relays with location over relays without location
      assert relay_with_location_1.id in relay_ids
      assert relay_with_location_2.id in relay_ids
      refute relay_without_location.id in relay_ids
    end

    test "shuffles relays when gateway has no location", %{
      account: account,
      site: site,
      token: token
    } do
      # Create gateway without location
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: nil,
          last_seen_remote_ip_location_lon: nil
        )

      relay1 = relay_fixture(%{lat: 37.0, lon: -122.0})
      relay2 = relay_fixture(%{lat: 40.0, lon: -74.0})

      :ok = Portal.Presence.Relays.connect(relay1)
      :ok = Portal.Presence.Relays.connect(relay2)

      join_channel(gateway, site, token)

      # Should still receive 2 relays (randomly selected)
      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()
      assert length(relay_ids) <= 2
    end

    test "load_balance_relays defers relays with lat but nil lon", %{
      account: account,
      site: site,
      token: token
    } do
      # Create a gateway with a known location (Houston area)
      gateway =
        gateway_fixture(
          account: account,
          site: site,
          last_seen_remote_ip_location_lat: 29.69,
          last_seen_remote_ip_location_lon: -95.90
        )

      # Two relays with full coordinates — distances can be computed; these fill the 2 slots
      relay_near_1 = relay_fixture(%{lat: 38.0, lon: -97.0})
      relay_near_2 = relay_fixture(%{lat: 20.59, lon: -100.39})

      # Relay with lat set but lon nil — hits the {_, nil} -> {nil, relay} branch;
      # treated as having no location and deferred behind relays with full coords
      relay_nil_lon = relay_fixture(%{lat: 1.0, lon: nil})

      :ok = Portal.Presence.Relays.connect(relay_near_1)
      :ok = Portal.Presence.Relays.connect(relay_near_2)
      :ok = Portal.Presence.Relays.connect(relay_nil_lon)

      join_channel(gateway, site, token)

      assert_push "init", %{relays: relays}

      relay_ids = Enum.map(relays, & &1.id) |> Enum.uniq()

      # The relays with full coordinates should fill the 2 available slots
      assert relay_near_1.id in relay_ids
      assert relay_near_2.id in relay_ids
      # The relay with nil lon should be deferred (treated as no-location)
      refute relay_nil_lon.id in relay_ids
    end

    test "debounces multiple rapid presence_diff events", %{
      gateway: gateway,
      site: site,
      token: token
    } do
      # Set debounce to 50ms so the test is fast but we can still observe coalescing
      Portal.Config.put_env_override(:portal, :relay_presence_debounce_ms, 50)

      join_channel(gateway, site, token)

      assert_push "init", %{relays: []}

      relay = relay_fixture(%{lat: 37.0, lon: -120.0})

      # Connect the relay - this triggers a presence_diff
      :ok = Portal.Presence.Relays.connect(relay)

      # Should receive exactly one relays_presence after debounce period
      assert_push "relays_presence", %{connected: [_, _], disconnected_ids: []}, 200

      # Rapidly disconnect and reconnect the relay multiple times
      # Each triggers a presence_diff, but they should be coalesced
      for _ <- 1..3 do
        Portal.Presence.Relays.disconnect(relay)
        :ok = Portal.Presence.Relays.connect(relay)
      end

      # After debounce, should receive exactly one update reflecting final state
      # Since the relay is online with the same stamp_secret, no disconnects should be reported
      refute_push "relays_presence", %{disconnected_ids: [_]}, 200
    end
  end
end
