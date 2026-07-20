defmodule Portal.QueueTest do
  use Portal.DataCase, async: true

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.Queue
  alias Portal.Repo.Batch
  alias Portal.PolicyAuthorization
  alias PortalAPI.Sockets

  defp unique_name(prefix), do: :"#{prefix}_#{inspect(make_ref())}"

  defp client_session_opts(extra) do
    {cb_opts, queue_opts} = Keyword.split(extra, [:on_failed, :on_confirmed])

    Keyword.merge(
      [
        flush_interval: :timer.seconds(5),
        flush_threshold: 1_000,
        label: "client session",
        on_flush: &flush_upsert(&1, :client_token_id, cb_opts)
      ],
      queue_opts
    )
  end

  defp gateway_session_opts(extra) do
    {cb_opts, queue_opts} = Keyword.split(extra, [:on_failed, :on_confirmed])

    Keyword.merge(
      [
        flush_interval: :timer.seconds(5),
        flush_threshold: 1_000,
        label: "gateway session",
        on_flush: &flush_upsert(&1, :gateway_token_id, cb_opts)
      ],
      queue_opts
    )
  end

  defp policy_authorization_opts(extra) do
    {batch_opts, queue_opts} =
      Keyword.split(extra, [:on_failed, :on_confirmed, :failed_log_level])

    batch_opts =
      Keyword.merge(
        [
          schema: Portal.PolicyAuthorization,
          label: "policy authorization",
          failed_log_level: :warning,
          fk_partitions: %{
            "policy_authorizations_account_id_fkey" => {:simple, :account_id, Portal.Account},
            "policy_authorizations_policy_id_fkey" => {:composite, :policy_id, Portal.Policy},
            "policy_authorizations_resource_id_fkey" =>
              {:composite, :resource_id, Portal.Resource},
            "policy_authorizations_token_id_fkey" =>
              {:composite, :token_id, Portal.ClientToken},
            "policy_authorizations_membership_id_fkey" =>
              {:composite_optional, :membership_id, Portal.Membership},
            "policy_authorizations_initiating_device_id_fkey" =>
              {:composite, :initiating_device_id, Portal.Device},
            "policy_authorizations_receiving_device_id_fkey" =>
              {:composite, :receiving_device_id, Portal.Device}
          }
        ],
        batch_opts
      )

    Keyword.merge(
      [
        flush_interval: :timer.seconds(1),
        flush_threshold: 10_000,
        label: "policy authorization",
        on_flush: &flush_batch(&1, batch_opts)
      ],
      queue_opts
    )
  end

  defp flush_batch(entries, batch_opts) do
    {inserted, failed} =
      batch_opts
      |> Keyword.fetch!(:schema)
      |> Batch.insert_all(entries, batch_opts)

    dispatch_failed(failed, batch_opts)
    dispatch_confirmed(entries, failed, batch_opts, :id)

    inserted
  end

  defp flush_upsert(entries, token_field, cb_opts) do
    {persisted, failed} = Sockets.LatestSession.upsert_all(entries, token_field)

    dispatch_failed(failed, cb_opts)
    dispatch_confirmed(entries, failed, cb_opts, :conn_id)

    persisted
  end

  defp reload_device(device) do
    Repo.get_by!(Portal.Device, account_id: device.account_id, id: device.id)
  end

  defp dispatch_failed(entries, batch_opts) do
    on_failed = Keyword.get(batch_opts, :on_failed, fn _attrs, _metadata -> :ok end)

    for {attrs, metadata} <- entries do
      safe_callback(fn -> on_failed.(attrs, metadata) end)
    end
  end

  defp dispatch_confirmed(entries, failed, batch_opts, key) do
    on_confirmed = Keyword.get(batch_opts, :on_confirmed, fn _attrs -> :ok end)
    failed_keys = MapSet.new(failed, fn {attrs, _metadata} -> attrs[key] end)

    for {attrs, _metadata} <- entries, not MapSet.member?(failed_keys, attrs[key]) do
      safe_callback(fn -> on_confirmed.(attrs) end)
    end
  end

  defp safe_callback(fun) do
    fun.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  describe "client_session config" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      queue =
        start_supervised!(
          {Queue, client_session_opts(name: unique_name(:cs), callers: [self()])}
        )

      %{queue: queue, account: account, client: client, token: token}
    end

    defp client_session_attrs(ctx, overrides \\ %{}) do
      defaults = %{
        conn_id: make_ref(),
        account_id: ctx.account.id,
        device_id: ctx.client.id,
        client_token_id: ctx.token.id,
        user_agent: "macOS/14.0 apple-client/1.3.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        remote_ip_location_city: "New York",
        remote_ip_location_lat: 40.7128,
        remote_ip_location_lon: -74.006,
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        version: "1.3.0"
      }

      Map.merge(defaults, overrides)
    end

    test "upserts the latest session onto the device on flush", ctx do
      attrs = client_session_attrs(ctx)

      Queue.enqueue(ctx.queue, attrs)
      Queue.flush(ctx.queue)

      device = reload_device(ctx.client)
      assert device.client_token_id == ctx.token.id
      assert device.public_key == attrs.public_key
      assert device.last_seen_user_agent == attrs.user_agent
      assert device.last_seen_version == attrs.version
      assert device.last_seen_remote_ip == %Postgrex.INET{address: {100, 64, 0, 1}}
      assert device.last_seen_at
    end

    test "keeps the newest entry when a batch has several sessions for one device", ctx do
      now = DateTime.utc_now()

      older = client_session_attrs(ctx, %{version: "1.0.0"})
      newer = client_session_attrs(ctx, %{version: "1.3.1"})

      Queue.enqueue(ctx.queue, newer, metadata: %{timestamp: now})
      Queue.enqueue(ctx.queue, older, metadata: %{timestamp: DateTime.add(now, -60, :second)})
      Queue.flush(ctx.queue)

      device = reload_device(ctx.client)
      assert device.last_seen_version == "1.3.1"
      assert device.last_seen_at == now
    end

    test "does not roll a device back to an older session across flushes", ctx do
      now = DateTime.utc_now()

      newer = client_session_attrs(ctx, %{version: "1.3.1"})
      Queue.enqueue(ctx.queue, newer, metadata: %{timestamp: now})
      Queue.flush(ctx.queue)

      older = client_session_attrs(ctx, %{version: "1.0.0"})
      Queue.enqueue(ctx.queue, older, metadata: %{timestamp: DateTime.add(now, -60, :second)})
      Queue.flush(ctx.queue)

      device = reload_device(ctx.client)
      assert device.last_seen_version == "1.3.1"
      assert device.last_seen_at == now
    end

    test "flush is a no-op when buffer is empty", ctx do
      Queue.flush(ctx.queue)
      assert is_nil(reload_device(ctx.client).last_seen_at)
    end

    test "flush clears the buffer so a subsequent flush is a no-op", ctx do
      Queue.enqueue(ctx.queue, client_session_attrs(ctx))
      Queue.flush(ctx.queue)

      device = reload_device(ctx.client)
      Queue.flush(ctx.queue)

      assert reload_device(ctx.client).last_seen_at == device.last_seen_at
    end

    test "persists the session even when its token was deleted", ctx do
      other_token = client_token_fixture(account: ctx.account)
      attrs = client_session_attrs(ctx, %{client_token_id: other_token.id})
      Repo.delete!(other_token)

      Queue.enqueue(ctx.queue, attrs)
      Queue.flush(ctx.queue)

      device = reload_device(ctx.client)
      assert device.client_token_id == other_token.id
      assert device.last_seen_at
    end

    test "skips sessions whose device was deleted", ctx do
      valid = client_session_attrs(ctx)

      actor = actor_fixture(account: ctx.account)
      other_client = client_fixture(account: ctx.account, actor: actor)
      orphan = client_session_attrs(ctx, %{device_id: other_client.id})

      other_device =
        Repo.get_by!(Portal.Device, account_id: other_client.account_id, id: other_client.id)

      Repo.delete!(other_device)

      Queue.enqueue(ctx.queue, orphan)
      Queue.enqueue(ctx.queue, valid)
      Queue.flush(ctx.queue)

      assert Process.alive?(ctx.queue)
      assert reload_device(ctx.client).last_seen_at
    end

    test "does not crash when all devices are deleted", ctx do
      actor = actor_fixture(account: ctx.account)
      other_client = client_fixture(account: ctx.account, actor: actor)
      orphan = client_session_attrs(ctx, %{device_id: other_client.id})

      other_device =
        Repo.get_by!(Portal.Device, account_id: other_client.account_id, id: other_client.id)

      Repo.delete!(other_device)

      Queue.enqueue(ctx.queue, orphan)
      Queue.flush(ctx.queue)

      assert Process.alive?(ctx.queue)
      assert is_nil(reload_device(ctx.client).last_seen_at)

      Queue.enqueue(ctx.queue, client_session_attrs(ctx))
      Queue.flush(ctx.queue)

      assert reload_device(ctx.client).last_seen_at
    end
  end

  describe "gateway_session config" do
    setup do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)

      queue =
        start_supervised!(
          {Queue, gateway_session_opts(name: unique_name(:gs), callers: [self()])}
        )

      %{queue: queue, account: account, site: site, gateway: gateway, token: token}
    end

    defp gateway_session_attrs(ctx, overrides \\ %{}) do
      defaults = %{
        conn_id: make_ref(),
        account_id: ctx.account.id,
        device_id: ctx.gateway.id,
        gateway_token_id: ctx.token.id,
        public_key: ctx.gateway.public_key,
        user_agent: "Linux/6.1.0 connlib/1.3.0 (x86_64)",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        version: "1.3.0"
      }

      Map.merge(defaults, overrides)
    end

    test "upserts gateway sessions and skips deleted devices", ctx do
      valid = gateway_session_attrs(ctx)

      other_gateway = gateway_fixture(account: ctx.account, site: ctx.site)
      orphan = gateway_session_attrs(ctx, %{device_id: other_gateway.id})

      other_device =
        Repo.get_by!(Portal.Device, account_id: other_gateway.account_id, id: other_gateway.id)

      Repo.delete!(other_device)

      Queue.enqueue(ctx.queue, orphan)
      Queue.enqueue(ctx.queue, valid)
      Queue.flush(ctx.queue)

      device = reload_device(ctx.gateway)
      assert device.gateway_token_id == ctx.token.id
      assert device.last_seen_user_agent == valid.user_agent
    end
  end

  describe "policy_authorization config" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      test_pid = self()

      on_failed = fn attrs, channel_pid ->
        send(test_pid, {:on_failed, attrs, channel_pid})
        :ok
      end

      queue =
        start_supervised!(
          {Queue,
           policy_authorization_opts(
             name: unique_name(:pa),
             on_failed: on_failed,
             callers: [self()]
           )}
        )

      %{
        queue: queue,
        account: account,
        client: client,
        gateway: gateway,
        resource: resource,
        policy: policy,
        membership: membership,
        token: token
      }
    end

    defp policy_authorization_attrs(ctx, overrides \\ %{}) do
      defaults = %{
        id: Ecto.UUID.generate(),
        token_id: ctx.token.id,
        policy_id: ctx.policy.id,
        initiating_device_id: ctx.client.id,
        receiving_device_id: ctx.gateway.id,
        resource_id: ctx.resource.id,
        membership_id: ctx.membership.id,
        account_id: ctx.account.id,
        initiator_remote_ip: {100, 64, 0, 1},
        initiator_user_agent: "test-agent",
        receiver_remote_ip: %Postgrex.INET{address: {100, 64, 0, 2}},
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      }

      Map.merge(defaults, overrides)
    end

    test "inserts a single policy_authorization on flush", ctx do
      attrs = policy_authorization_attrs(ctx)

      Queue.enqueue(ctx.queue, attrs, metadata: self())
      Queue.flush(ctx.queue)

      [persisted] = Repo.all(PolicyAuthorization)
      assert persisted.id == attrs.id
      assert persisted.policy_id == ctx.policy.id
      assert persisted.inserted_at
    end

    test "accepts nil membership_id (composite_optional partition)", ctx do
      attrs = policy_authorization_attrs(ctx, %{membership_id: nil})

      Queue.enqueue(ctx.queue, attrs, metadata: self())
      Queue.flush(ctx.queue)

      [persisted] = Repo.all(PolicyAuthorization)
      assert is_nil(persisted.membership_id)
    end

    test "invokes on_failed for entries with invalid policy reference", ctx do
      attrs = policy_authorization_attrs(ctx, %{policy_id: Ecto.UUID.generate()})
      attrs_id = attrs.id

      Queue.enqueue(ctx.queue, attrs, metadata: self())
      Queue.flush(ctx.queue)

      caller = self()
      assert_received {:on_failed, %{id: ^attrs_id}, ^caller}
      assert Repo.all(PolicyAuthorization) == []
    end

    test "invokes on_failed for entries with invalid token reference", ctx do
      attrs = policy_authorization_attrs(ctx, %{token_id: Ecto.UUID.generate()})
      attrs_id = attrs.id

      Queue.enqueue(ctx.queue, attrs, metadata: self())
      Queue.flush(ctx.queue)

      assert_received {:on_failed, %{id: ^attrs_id}, _pid}
    end

    test "invokes on_failed for entries with invalid receiving device", ctx do
      attrs = policy_authorization_attrs(ctx, %{receiving_device_id: Ecto.UUID.generate()})
      attrs_id = attrs.id

      Queue.enqueue(ctx.queue, attrs, metadata: self())
      Queue.flush(ctx.queue)

      assert_received {:on_failed, %{id: ^attrs_id}, _pid}
    end

    test "inserts valid entries while invoking on_failed for the failed one", ctx do
      valid = policy_authorization_attrs(ctx)
      invalid = policy_authorization_attrs(ctx, %{policy_id: Ecto.UUID.generate()})
      invalid_id = invalid.id

      Queue.enqueue(ctx.queue, invalid, metadata: self())
      Queue.enqueue(ctx.queue, valid, metadata: self())
      Queue.flush(ctx.queue)

      assert_received {:on_failed, %{id: ^invalid_id}, _pid}
      [persisted] = Repo.all(PolicyAuthorization)
      assert persisted.id == valid.id
    end

    test "buffer survives FK errors and continues processing", ctx do
      bad = policy_authorization_attrs(ctx, %{policy_id: Ecto.UUID.generate()})

      Queue.enqueue(ctx.queue, bad, metadata: self())
      Queue.flush(ctx.queue)

      assert Process.alive?(ctx.queue)

      Queue.enqueue(ctx.queue, policy_authorization_attrs(ctx), metadata: self())
      Queue.flush(ctx.queue)

      assert length(Repo.all(PolicyAuthorization)) == 1
    end

    test "does not invoke on_failed on successful inserts", ctx do
      Queue.enqueue(ctx.queue, policy_authorization_attrs(ctx), metadata: self())
      Queue.flush(ctx.queue)

      refute_received {:on_failed, _, _}
    end
  end

  describe "timer-based flush" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      queue =
        start_supervised!(
          {Queue, client_session_opts(name: unique_name(:cs), callers: [self()])}
        )

      %{queue: queue, account: account, client: client, token: token}
    end

    test "flushes buffered entries when timer fires", ctx do
      attrs = %{
        conn_id: make_ref(),
        account_id: ctx.account.id,
        device_id: ctx.client.id,
        client_token_id: ctx.token.id,
        user_agent: "test/1.0",
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        version: "1.3.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        remote_ip_location_city: "NYC",
        remote_ip_location_lat: 40.0,
        remote_ip_location_lon: -74.0
      }

      Queue.enqueue(ctx.queue, attrs)
      send(ctx.queue, :flush)
      Queue.flush(ctx.queue)

      assert reload_device(ctx.client).last_seen_at
    end
  end

  describe "sender-pid ordering invariant" do
    # These tests are the safety net for the cross-pid race that motivated the
    # Queue rename: if `:allow_access` is sent from one pid and `:reject_access`
    # from another, Erlang gives no signal-ordering guarantee and the gateway
    # can see them out of order. The Queue closes this gap by running BOTH the
    # `:dispatch` callback and the `:on_failed` callback inside its own
    # GenServer process — same sender pid → per-pid FIFO holds.
    #
    # The tests below try to force out-of-order delivery: they stage a
    # dispatch that sends one tag, then trigger an FK violation so `on_failed`
    # sends another tag, and finally drain the receiver's mailbox in order.
    # The receiver also records the sender pid embedded in each message so we
    # catch a regression that splits the senders even if mailbox order would
    # otherwise mask it.

    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      test_pid = self()

      on_failed = fn attrs, _ ->
        send(test_pid, {:reject, attrs.id, attrs.receiving_device_id, self()})
        :ok
      end

      queue =
        start_supervised!(
          {Queue,
           policy_authorization_opts(
             name: unique_name(:pa_order),
             on_failed: on_failed,
             callers: [self()]
           )}
        )

      %{
        queue: queue,
        account: account,
        client: client,
        gateway: gateway,
        resource: resource,
        policy: policy,
        membership: membership,
        token: token
      }
    end

    defp ordering_attrs(ctx, overrides \\ %{}) do
      defaults = %{
        id: Ecto.UUID.generate(),
        token_id: ctx.token.id,
        policy_id: ctx.policy.id,
        initiating_device_id: ctx.client.id,
        receiving_device_id: ctx.gateway.id,
        resource_id: ctx.resource.id,
        membership_id: ctx.membership.id,
        account_id: ctx.account.id,
        initiator_remote_ip: {100, 64, 0, 1},
        initiator_user_agent: "test-agent",
        receiver_remote_ip: %Postgrex.INET{address: {100, 64, 0, 2}},
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      }

      Map.merge(defaults, overrides)
    end

    test "allow and reject both originate from the Queue pid", ctx do
      caller = self()
      queue_pid = ctx.queue

      # Force the insert to fail later: invalid policy_id. Dispatch records the
      # sender pid via `self()`, captured inside the closure so it's evaluated
      # when the closure runs (in the Queue process).
      attrs = ordering_attrs(ctx, %{policy_id: Ecto.UUID.generate()})

      Queue.enqueue(ctx.queue, attrs,
        dispatch: fn ->
          send(caller, {:allow, attrs.id, attrs.receiving_device_id, self()})
        end
      )

      Queue.flush(ctx.queue)

      attrs_id = attrs.id
      assert_received {:allow, ^attrs_id, _, allow_from}
      assert_received {:reject, ^attrs_id, _, reject_from}

      assert allow_from == queue_pid,
             "expected :allow to come from the Queue pid, got #{inspect(allow_from)}"

      assert reject_from == queue_pid,
             "expected :reject to come from the Queue pid, got #{inspect(reject_from)}"
    end

    test "receiver sees :allow before :reject when insert fails", ctx do
      attrs = ordering_attrs(ctx, %{policy_id: Ecto.UUID.generate()})
      attrs_id = attrs.id
      device_id = attrs.receiving_device_id
      caller = self()

      Queue.enqueue(ctx.queue, attrs,
        dispatch: fn ->
          send(caller, {:allow, attrs.id, attrs.receiving_device_id, self()})
        end
      )

      # Drain in strict order to confirm :allow precedes :reject in the mailbox.
      assert_receive {:allow, ^attrs_id, ^device_id, _allow_from}

      # The flush triggers on_failed which queues :reject after :allow.
      Queue.flush(ctx.queue)
      assert_receive {:reject, ^attrs_id, ^device_id, _reject_from}
    end

    test "interleaved enqueues from many callers still emit allow-before-reject per entry",
         ctx do
      caller = self()

      # Mix valid and invalid policy_authorizations from multiple Task pids so
      # that several concurrent enqueues hit the Queue. Each invalid entry
      # produces a paired (:allow, :reject); each valid produces only :allow.
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            attrs =
              if rem(i, 2) == 0 do
                ordering_attrs(ctx, %{policy_id: Ecto.UUID.generate()})
              else
                ordering_attrs(ctx)
              end

            Queue.enqueue(ctx.queue, attrs,
              dispatch: fn ->
                send(caller, {:allow, attrs.id, attrs.receiving_device_id, self()})
              end
            )

            attrs.id
          end)
        end

      ids = Task.await_many(tasks)
      Queue.flush(ctx.queue)

      messages = drain_mailbox([])

      allow_idx =
        messages
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {{:allow, id, _device, _from}, i} -> [{id, i}]
          _ -> []
        end)
        |> Map.new()

      reject_idx =
        messages
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {{:reject, id, _device, _from}, i} -> [{id, i}]
          _ -> []
        end)
        |> Map.new()

      for id <- ids do
        assert Map.has_key?(allow_idx, id), "missing :allow for #{inspect(id)}"

        if Map.has_key?(reject_idx, id) do
          assert allow_idx[id] < reject_idx[id],
                 ":reject arrived before :allow for #{inspect(id)}"
        end
      end
    end

    defp drain_mailbox(acc) do
      receive do
        msg -> drain_mailbox([msg | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end
  end

  describe "dispatch error handling" do
    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      test_pid = self()
      on_failed = fn attrs, _meta -> send(test_pid, {:on_failed, attrs}) end

      queue =
        start_supervised!(
          {Queue,
           client_session_opts(
             name: unique_name(:cs_err),
             on_failed: on_failed,
             callers: [self()]
           )}
        )

      %{queue: queue, account: account, client: client, token: token}
    end

    defp err_session_attrs(ctx) do
      %{
        conn_id: make_ref(),
        account_id: ctx.account.id,
        device_id: ctx.client.id,
        client_token_id: ctx.token.id,
        user_agent: "test/1.0",
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        version: "1.3.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        remote_ip_location_city: "NYC",
        remote_ip_location_lat: 40.0,
        remote_ip_location_lon: -74.0
      }
    end

    test "{:error, _} dispatch return is propagated and skips the buffer", ctx do
      attrs = err_session_attrs(ctx)
      attrs_conn_id = attrs.conn_id

      assert {:error, :not_found} =
               Queue.enqueue(ctx.queue, attrs, dispatch: fn -> {:error, :not_found} end)

      Queue.flush(ctx.queue)

      # The device must not be updated — the dispatch never reached the
      # receiver, so persisting authorization state would create a stale row
      # that no `:allow` is on the wire for.
      assert is_nil(reload_device(ctx.client).last_seen_at)

      # And on_failed must NOT fire — there's nothing to revoke.
      refute_received {:on_failed, %{conn_id: ^attrs_conn_id}}
    end

    test ":ok dispatch return buffers the entry", ctx do
      Queue.enqueue(ctx.queue, err_session_attrs(ctx), dispatch: fn -> :ok end)
      Queue.flush(ctx.queue)

      assert reload_device(ctx.client).last_seen_at
    end

    test "dispatch runs in the Queue process so its sender is the Queue pid", ctx do
      queue_pid = ctx.queue
      caller = self()

      Queue.enqueue(ctx.queue, err_session_attrs(ctx),
        dispatch: fn ->
          send(caller, {:dispatched_from, self()})
          :ok
        end
      )

      assert_received {:dispatched_from, ^queue_pid}
    end
  end

  describe "on_confirmed callback" do
    # The receiver-side authz durability timer depends on the Queue firing
    # `on_confirmed` for every entry that successfully persisted, so the
    # receiver can cancel its timer. Verifies: confirms fire for successful
    # entries, NOT for failed ones, and a misbehaving callback can't kill
    # the queue.

    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      resource = resource_fixture(account: account, site: site)
      group = group_fixture(account: account)
      policy = policy_fixture(account: account, group: group, resource: resource)
      membership = membership_fixture(account: account, actor: actor, group: group)
      token = client_token_fixture(account: account, actor: actor)

      test_pid = self()
      on_confirmed = fn attrs -> send(test_pid, {:on_confirmed, attrs.id}) end
      on_failed = fn attrs, _ -> send(test_pid, {:on_failed, attrs.id}) end

      queue =
        start_supervised!(
          {Queue,
           policy_authorization_opts(
             name: unique_name(:pa_conf),
             on_failed: on_failed,
             on_confirmed: on_confirmed,
             callers: [self()]
           )}
        )

      %{
        queue: queue,
        account: account,
        client: client,
        gateway: gateway,
        resource: resource,
        policy: policy,
        membership: membership,
        token: token
      }
    end

    defp conf_attrs(ctx, overrides \\ %{}) do
      defaults = %{
        id: Ecto.UUID.generate(),
        token_id: ctx.token.id,
        policy_id: ctx.policy.id,
        initiating_device_id: ctx.client.id,
        receiving_device_id: ctx.gateway.id,
        resource_id: ctx.resource.id,
        membership_id: ctx.membership.id,
        account_id: ctx.account.id,
        initiator_remote_ip: {100, 64, 0, 1},
        initiator_user_agent: "test-agent",
        receiver_remote_ip: %Postgrex.INET{address: {100, 64, 0, 2}},
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      }

      Map.merge(defaults, overrides)
    end

    test "fires on_confirmed for entries that successfully persist", ctx do
      attrs = conf_attrs(ctx)
      attrs_id = attrs.id

      Queue.enqueue(ctx.queue, attrs)
      Queue.flush(ctx.queue)

      assert_received {:on_confirmed, ^attrs_id}
      refute_received {:on_failed, _}
    end

    test "does NOT fire on_confirmed for entries that fail to persist", ctx do
      attrs = conf_attrs(ctx, %{policy_id: Ecto.UUID.generate()})
      attrs_id = attrs.id

      Queue.enqueue(ctx.queue, attrs)
      Queue.flush(ctx.queue)

      assert_received {:on_failed, ^attrs_id}
      refute_received {:on_confirmed, _}
    end

    test "fires on_confirmed only for the successful subset of a mixed batch", ctx do
      good = conf_attrs(ctx)
      bad = conf_attrs(ctx, %{policy_id: Ecto.UUID.generate()})
      good_id = good.id
      bad_id = bad.id

      Queue.enqueue(ctx.queue, bad)
      Queue.enqueue(ctx.queue, good)
      Queue.flush(ctx.queue)

      assert_received {:on_confirmed, ^good_id}
      assert_received {:on_failed, ^bad_id}
      refute_received {:on_confirmed, ^bad_id}
      refute_received {:on_failed, ^good_id}
    end

    test "on_confirmed that raises does not crash the queue or skip remaining confirms",
         ctx do
      test_pid = self()

      bad_id_1 = Ecto.UUID.generate()
      bad_id_2 = Ecto.UUID.generate()

      on_confirmed = fn attrs ->
        send(test_pid, {:on_confirmed_attempt, attrs.id})

        if attrs.id == bad_id_1 do
          raise "boom from on_confirmed"
        else
          send(test_pid, {:on_confirmed_succeeded, attrs.id})
        end
      end

      queue =
        start_supervised!(
          {Queue,
           policy_authorization_opts(
             name: unique_name(:pa_conf_raise),
             on_confirmed: on_confirmed,
             callers: [self()]
           )},
          id: :pa_conf_raise_queue
        )

      Queue.enqueue(queue, conf_attrs(ctx, %{id: bad_id_1}))
      Queue.enqueue(queue, conf_attrs(ctx, %{id: bad_id_2}))
      Queue.flush(queue)

      assert Process.alive?(queue)
      assert_received {:on_confirmed_attempt, ^bad_id_1}
      assert_received {:on_confirmed_attempt, ^bad_id_2}
      assert_received {:on_confirmed_succeeded, ^bad_id_2}
    end
  end

  describe "crash resilience" do
    # These tests guard the contract: state.buffer must survive any single
    # ill-behaved callback (dispatch, on_failed, or a non-FK DB error). The
    # queue would otherwise crash, the supervisor would restart it with an
    # empty buffer, and any allow-equivalent already on the wire would be
    # orphaned — gateway with stale cache, no follow-up reject_access.

    setup do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      %{account: account, client: client, token: token}
    end

    defp resilience_session_attrs(ctx, overrides \\ %{}) do
      defaults = %{
        conn_id: make_ref(),
        account_id: ctx.account.id,
        device_id: ctx.client.id,
        client_token_id: ctx.token.id,
        user_agent: "macOS/14.0 apple-client/1.3.0",
        remote_ip: {100, 64, 0, 1},
        remote_ip_location_region: "US",
        remote_ip_location_city: "NYC",
        remote_ip_location_lat: 40.0,
        remote_ip_location_lon: -74.0,
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        version: "1.3.0"
      }

      Map.merge(defaults, overrides)
    end

    test "dispatch that raises does not crash the queue or evaporate state.buffer",
         ctx do
      test_pid = self()

      on_failed = fn attrs, _ ->
        send(test_pid, {:on_failed, attrs.conn_id})
        :ok
      end

      queue =
        start_supervised!(
          {Queue,
           client_session_opts(
             name: unique_name(:cs_disp_raise),
             on_failed: on_failed,
             callers: [self()]
           )}
        )

      # Pre-load the buffer with a valid entry so we can observe that the
      # state.buffer survives the bad call.
      valid_attrs = resilience_session_attrs(ctx)
      Queue.enqueue(queue, valid_attrs)

      # This call's dispatch raises. The queue must not crash; the caller
      # gets a tagged error reply; the previously buffered entry remains.
      raising_attrs = resilience_session_attrs(ctx)

      result =
        Queue.enqueue(queue, raising_attrs,
          dispatch: fn -> raise "boom" end
        )

      assert {:error, :dispatch_crashed} = result
      assert Process.alive?(queue)

      # The raising entry should NOT be buffered (error replies skip buffer).
      # The previously-enqueued valid entry should still flush successfully.
      Queue.flush(queue)
      device = reload_device(ctx.client)
      assert device.last_seen_at
      assert device.public_key == valid_attrs.public_key

      # No on_failed should have fired — the valid entry persisted, and the
      # raising entry was never buffered.
      refute_received {:on_failed, _}
    end

    test "on_flush that raises does not crash the queue" do
      queue =
        start_supervised!(
          {Queue,
           name: unique_name(:flush_raise),
           flush_interval: :timer.seconds(5),
           flush_threshold: 1_000,
           label: "raising flush",
           on_flush: fn _entries -> raise "boom from on_flush" end}
        )

      Queue.enqueue(queue, %{id: Ecto.UUID.generate()})

      assert capture_log(fn ->
               Queue.flush(queue)
             end) =~ "Queue raising flush on_flush crashed"

      assert Process.alive?(queue)
    end

    test "on_failed that raises does not crash the queue or skip remaining on_faileds",
         ctx do
      test_pid = self()

      bad_conn_id_1 = make_ref()
      bad_conn_id_2 = make_ref()

      on_failed = fn attrs, _ ->
        send(test_pid, {:on_failed_attempt, attrs.conn_id})
        # First entry raises; subsequent ones must still run.
        if attrs.conn_id == bad_conn_id_1 do
          raise "boom from on_failed"
        else
          send(test_pid, {:on_failed_succeeded, attrs.conn_id})
          :ok
        end
      end

      queue =
        start_supervised!(
          {Queue,
           client_session_opts(
             name: unique_name(:cs_on_failed_raise),
             on_failed: on_failed,
             callers: [self()]
           )}
        )

      # Both entries reference a since-deleted device → both fail → both
      # entries flow through on_failed.
      actor = actor_fixture(account: ctx.account)
      other_client = client_fixture(account: ctx.account, actor: actor)
      attrs1 = resilience_session_attrs(ctx, %{conn_id: bad_conn_id_1, device_id: other_client.id})
      attrs2 = resilience_session_attrs(ctx, %{conn_id: bad_conn_id_2, device_id: other_client.id})

      other_device =
        Repo.get_by!(Portal.Device, account_id: other_client.account_id, id: other_client.id)

      Repo.delete!(other_device)

      Queue.enqueue(queue, attrs1)
      Queue.enqueue(queue, attrs2)
      Queue.flush(queue)

      assert Process.alive?(queue)

      # Both on_failed callbacks must have been attempted, even though the
      # first one raised.
      assert_received {:on_failed_attempt, ^bad_conn_id_1}
      assert_received {:on_failed_attempt, ^bad_conn_id_2}

      # The second one must have completed successfully (the raise in the
      # first must not have aborted the loop).
      assert_received {:on_failed_succeeded, ^bad_conn_id_2}
    end

    test "terminate/2 flushes remaining buffered entries through on_failed",
         ctx do
      # Best-effort terminate/2: if the queue is shut down with buffered
      # entries still present, on_failed must fire for each so that the
      # already-dispatched allow-equivalent on the wire can be reverted.
      test_pid = self()

      on_failed = fn attrs, _ ->
        send(test_pid, {:terminate_on_failed, attrs.conn_id})
        :ok
      end

      queue =
        start_supervised!(
          {Queue,
           client_session_opts(
             name: unique_name(:cs_term),
             on_failed: on_failed,
             callers: [self()]
           )},
          id: :cs_term_queue
        )

      # Buffer two entries that reference a deleted device so the final
      # flush in terminate/2 fails and routes both through on_failed.
      actor = actor_fixture(account: ctx.account)
      other_client = client_fixture(account: ctx.account, actor: actor)
      attrs1 = resilience_session_attrs(ctx, %{device_id: other_client.id})
      attrs2 = resilience_session_attrs(ctx, %{device_id: other_client.id})

      other_device =
        Repo.get_by!(Portal.Device, account_id: other_client.account_id, id: other_client.id)

      Repo.delete!(other_device)

      Queue.enqueue(queue, attrs1)
      Queue.enqueue(queue, attrs2)

      # Stop the queue gracefully — triggers terminate/2.
      :ok = stop_supervised(:cs_term_queue)

      attrs1_conn_id = attrs1.conn_id
      attrs2_conn_id = attrs2.conn_id
      assert_received {:terminate_on_failed, ^attrs1_conn_id}
      assert_received {:terminate_on_failed, ^attrs2_conn_id}
    end
  end

  describe "start_link/1" do
    test "registers under the given name" do
      name = unique_name(:custom)

      pid =
        start_supervised!(
          {Queue, client_session_opts(name: name, callers: [self()])},
          id: :custom_name_queue
        )

      assert Process.alive?(pid)
      assert GenServer.whereis(name) == pid
    end

    test "raises when :name is missing" do
      assert_raise KeyError, fn -> Queue.start_link([]) end
    end
  end
end
