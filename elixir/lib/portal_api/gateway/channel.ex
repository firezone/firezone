defmodule PortalAPI.Gateway.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Gateway.Views
  alias __MODULE__.Database

  alias Portal.{
    Cache,
    Changes.Change,
    Authentication,
    PubSub,
    Resource,
    Presence
  }

  require Logger

  # The interval at which the policy authorization cache is pruned.
  @prune_cache_every :timer.minutes(1)

  # All relayed connections are dropped when this expires, so use
  # a long expiration time to avoid frequent disconnections.
  @relay_credentials_expire_in_hours 90 * 24

  @impl true
  def join("gateway", _payload, socket) do
    # If we crash, take the transport process down with us since connlib expects the WebSocket to close on error
    Process.link(socket.transport_pid)

    send(self(), :after_join)
    {:ok, socket}
  end

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def handle_info(:after_join, socket) do
    # Initialize the cache
    socket = assign(socket, cache: Cache.Gateway.hydrate(socket.assigns.gateway))
    Process.send_after(self(), :prune_cache, @prune_cache_every)

    # Track gateway's presence
    gateway = socket.assigns.gateway

    Logger.debug("Tracking gateway presence",
      gateway_id: gateway.id,
      site_id: gateway.site_id,
      account_id: gateway.account_id,
      token_id: socket.assigns.token_id
    )

    :ok = Presence.Gateways.connect(gateway, socket.assigns.token_id)

    # Subscribe to all account updates
    :ok = PubSub.Account.subscribe(socket.assigns.gateway.account_id)
    :ok = PubSub.Changes.subscribe(socket.assigns.gateway.account_id)

    # Return all connected relays and subscribe to global relay presence
    {:ok, relays} = select_relays(socket)
    :ok = Presence.Relays.Global.subscribe()

    account = Database.get_account_by_id!(socket.assigns.gateway.account_id)

    init(socket, account, relays)

    # Cache relay IDs and stamp secrets for tracking
    socket = cache_relays(socket, relays)

    {:noreply, socket}
  end

  def handle_info(:prune_cache, socket) do
    Process.send_after(self(), :prune_cache, @prune_cache_every)
    {:noreply, assign(socket, cache: Cache.Gateway.prune(socket.assigns.cache))}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  def handle_info(%Change{lsn: lsn} = change, socket) do
    last_lsn = Map.get(socket.assigns, :last_lsn, 0)

    if lsn > last_lsn do
      case handle_change(change, socket) do
        {:noreply, socket} ->
          {:noreply, assign(socket, last_lsn: lsn)}

        result ->
          result
      end
    else
      # Change already processed; ignore to prevent replaying it
      {:noreply, socket}
    end
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  # Handle relay presence changes from global topic.
  # Instead of reacting immediately, we debounce by scheduling a delayed check.
  # This avoids spurious updates during transient relay disconnections.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:global_relays" <> _
        },
        socket
      ) do
    # Cancel any existing debounce timer to implement true debouncing
    # (only the last event in a burst triggers the check)
    if timer_ref = socket.assigns[:relay_presence_timer_ref] do
      Process.cancel_timer(timer_ref)
    end

    # Use a unique reference to identify this timer. When handling the message,
    # we check if it matches the current ref to prevent processing stale messages
    # that were already in the mailbox when the timer was cancelled.
    ref = make_ref()
    debounce_ms = Portal.Config.get_env(:portal, :relay_presence_debounce_ms, 1_000)
    timer_ref = Process.send_after(self(), {:check_relay_presence, ref}, debounce_ms)

    socket =
      socket
      |> assign(:relay_presence_timer_ref, timer_ref)
      |> assign(:relay_presence_ref, ref)

    {:noreply, socket}
  end

  # Debounced relay presence check - queries the CRDT state after the debounce period.
  # cached_relay_ids is a MapSet of relay IDs we've sent to the gateway.
  # Presence is keyed by relay ID.
  def handle_info({:check_relay_presence, ref}, socket) do
    # Only process if the ref matches the current active timer.
    # This prevents processing stale messages that were already in the mailbox
    # when Process.cancel_timer/1 was called.
    if ref != socket.assigns[:relay_presence_ref] do
      {:noreply, socket}
    else
      # Clear the timer references since we're processing now
      socket =
        socket
        |> assign(:relay_presence_timer_ref, nil)
        |> assign(:relay_presence_ref, nil)

      cached_relay_ids = socket.assigns[:cached_relay_ids] || MapSet.new()

      # Query presence ONCE - use this single snapshot for both determining
      # disconnected relays and selecting connected relays. This avoids a race
      # condition where CRDT state changes between queries during rapid
      # disconnect/reconnect cycles.
      {:ok, all_online_relays} = Presence.Relays.all_connected_relays()
      online_relay_ids = MapSet.new(all_online_relays, & &1.id)

      # Find which cached relays are now truly offline (ID no longer in presence)
      disconnected_ids =
        cached_relay_ids
        |> Enum.reject(&MapSet.member?(online_relay_ids, &1))
        |> Enum.to_list()

      # Send relays_presence if any cached relays are disconnected OR if we have fewer than 2 relays
      # and more are now available
      needs_update =
        disconnected_ids != [] or
          (MapSet.size(cached_relay_ids) < 2 and MapSet.size(online_relay_ids) > 0)

      if needs_update do
        # Select best relays from the SAME snapshot we used for disconnected_ids
        location = {
          socket.assigns.gateway.last_seen_remote_ip_location_lat,
          socket.assigns.gateway.last_seen_remote_ip_location_lon
        }

        relays = load_balance_relays(location, all_online_relays)
        socket = cache_relays(socket, relays)

        relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(90, :day)

        push(socket, "relays_presence", %{
          disconnected_ids: disconnected_ids,
          connected:
            Views.Relay.render_many(
              relays,
              socket.assigns.gateway.public_key,
              relay_credentials_expire_at
            )
        })

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end
  end

  ###########################
  #### Connection setup #####
  ###########################

  def handle_info(
        {{:ice_candidates, gateway_id}, client_id, candidates},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    push(socket, "ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:invalidate_ice_candidates, gateway_id}, client_id, candidates},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    push(socket, "invalidate_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:authorize_policy, gateway_id}, {channel_pid, socket_ref}, payload},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at,
      ice_credentials: ice_credentials,
      preshared_key: preshared_key,
      subject: %Authentication.Subject{} = subject
    } = payload

    # Preload addresses in case client was received via PubSub without them
    client = Database.preload_client_addresses(client)

    ref =
      encode_ref(socket, {
        channel_pid,
        socket_ref,
        resource.id,
        preshared_key,
        ice_credentials
      })

    push(socket, "authorize_flow", %{
      ref: ref,
      resource: Views.Resource.render(resource),
      gateway_ice_credentials: ice_credentials.gateway,
      client: Views.Client.render(client, preshared_key),
      client_ice_credentials: ice_credentials.client,
      expires_at: DateTime.to_unix(authorization_expires_at, :second),
      subject: Views.Subject.render(subject)
    })

    cache =
      socket.assigns.cache
      |> Cache.Gateway.put(
        client.id,
        resource.id,
        policy_authorization_id,
        authorization_expires_at
      )

    {:noreply, assign(socket, cache: cache)}
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:allow_access, gateway_id}, {channel_pid, socket_ref}, attrs},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    # Preload addresses in case client was received via PubSub without them
    client = Database.preload_client_addresses(client)

    case Resource.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      resource ->
        ref =
          encode_ref(
            socket,
            {channel_pid, socket_ref, resource.id}
          )

        push(socket, "allow_access", %{
          ref: ref,
          client_id: client.id,
          resource: Views.Resource.render(resource),
          expires_at: DateTime.to_unix(authorization_expires_at, :second),
          payload: payload,
          client_ipv4: client.ipv4_address.address,
          client_ipv6: client.ipv6_address.address
        })

        cache =
          socket.assigns.cache
          |> Cache.Gateway.put(
            client.id,
            resource.id,
            policy_authorization_id,
            authorization_expires_at
          )

        {:noreply, assign(socket, cache: cache)}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:request_connection, gateway_id}, {channel_pid, socket_ref}, attrs},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    %{
      client: client,
      resource: %Cache.Cacheable.Resource{} = resource,
      policy_authorization_id: policy_authorization_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload,
      client_preshared_key: preshared_key
    } = attrs

    # Preload addresses in case client was received via PubSub without them
    client = Database.preload_client_addresses(client)

    case Resource.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      resource ->
        ref =
          encode_ref(
            socket,
            {channel_pid, socket_ref, resource.id}
          )

        push(socket, "request_connection", %{
          ref: ref,
          resource: Views.Resource.render(resource),
          client: Views.Client.render(client, payload, preshared_key),
          expires_at: DateTime.to_unix(authorization_expires_at, :second)
        })

        cache =
          socket.assigns.cache
          |> Cache.Gateway.put(
            client.id,
            resource.id,
            policy_authorization_id,
            authorization_expires_at
          )

        {:noreply, assign(socket, cache: cache)}
    end
  end

  # Helper to directly send reject_access in integration tests
  def handle_info(
        {{:reject_access, gateway_id}, client_id, resource_id},
        %{assigns: %{gateway: %{id: gateway_id}}} = socket
      ) do
    push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
    {:noreply, socket}
  end

  # Catch-all for messages we don't handle
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_in("flow_authorized", %{"ref" => signed_ref}, socket) do
    case decode_ref(socket, signed_ref) do
      {:ok,
       {
         channel_pid,
         socket_ref,
         resource_id,
         preshared_key,
         ice_credentials
       }} ->
        send(
          channel_pid,
          {
            :connect,
            socket_ref,
            resource_id,
            socket.assigns.gateway.site_id,
            socket.assigns.gateway.id,
            socket.assigns.gateway.public_key,
            socket.assigns.gateway.ipv4_address.address,
            socket.assigns.gateway.ipv6_address.address,
            preshared_key,
            ice_credentials
          }
        )

        {:reply, :ok, socket}

      {:error, :invalid_ref} ->
        Logger.error("Gateway replied with an invalid ref")
        {:reply, {:error, %{reason: :invalid_ref}}, socket}
    end
  end

  # DEPRECATED IN 1.4
  @impl true
  def handle_in(
        "connection_ready",
        %{
          "ref" => signed_ref,
          "gateway_payload" => payload
        },
        socket
      ) do
    case decode_ref(socket, signed_ref) do
      {:ok, {channel_pid, socket_ref, rid_bytes}} ->
        send(
          channel_pid,
          {:connect, socket_ref, rid_bytes, socket.assigns.gateway.public_key, payload}
        )

        {:reply, :ok, socket}

      {:error, :invalid_ref} ->
        Logger.error("Gateway replied with an invalid ref")
        {:reply, {:error, %{reason: :invalid_ref}}, socket}
    end
  end

  #####################################
  ##### Gateway-initiated actions #####
  #####################################

  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    :ok =
      Enum.each(client_ids, fn client_id ->
        PubSub.Account.broadcast(
          socket.assigns.gateway.account_id,
          {{:ice_candidates, client_id}, socket.assigns.gateway.id, candidates}
        )
      end)

    {:noreply, socket}
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    :ok =
      Enum.each(client_ids, fn client_id ->
        PubSub.Account.broadcast(
          socket.assigns.gateway.account_id,
          {{:invalidate_ice_candidates, client_id}, socket.assigns.gateway.id, candidates}
        )
      end)

    {:noreply, socket}
  end

  # Catch-all for unknown messages
  def handle_in(message, payload, socket) do
    Logger.error("Unknown gateway message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp encode_ref(socket, tuple) do
    ref =
      tuple
      |> :erlang.term_to_binary()
      |> Base.url_encode64()

    key_base = socket.endpoint.config(:secret_key_base)
    Plug.Crypto.sign(key_base, "gateway_reply_ref", ref)
  end

  defp decode_ref(socket, signed_ref) do
    key_base = socket.endpoint.config(:secret_key_base)

    with {:ok, ref} <-
           Plug.Crypto.verify(key_base, "gateway_reply_ref", signed_ref, max_age: :infinity) do
      tuple =
        ref
        |> Base.url_decode64!()
        |> Plug.Crypto.non_executable_binary_to_term([:safe])

      {:ok, tuple}
    else
      {:error, :invalid} -> {:error, :invalid_ref}
    end
  end

  defp select_relays(socket, except_ids \\ []) do
    {:ok, relays} =
      Presence.Relays.all_connected_relays(except_ids)

    location = {
      socket.assigns.gateway.last_seen_remote_ip_location_lat,
      socket.assigns.gateway.last_seen_remote_ip_location_lon
    }

    relays = load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp cache_relays(socket, relays) do
    cached_relay_ids = MapSet.new(relays, fn relay -> relay.id end)
    assign(socket, :cached_relay_ids, cached_relay_ids)
  end

  defp init(socket, account, relays) do
    relay_credentials_expire_at =
      DateTime.utc_now() |> DateTime.add(@relay_credentials_expire_in_hours, :hour)

    push(socket, "init", %{
      authorizations: Views.PolicyAuthorization.render_many(socket.assigns.cache),
      account_slug: account.slug,
      interface: Views.Interface.render(socket.assigns.gateway),
      relays:
        Views.Relay.render_many(
          relays,
          socket.assigns.gateway.public_key,
          relay_credentials_expire_at
        ),
      # These aren't used but needed for API compatibility
      config: %{
        ipv4_masquerade_enabled: true,
        ipv6_masquerade_enabled: true
      }
    })
  end

  ##########################################
  #### Handling changes from the domain ####
  ##########################################

  # ACCOUNTS

  # Resend init when config changes so that new slug may be applied
  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Account{slug: old_slug},
           struct: %Portal.Account{slug: slug} = account
         },
         socket
       )
       when old_slug != slug do
    {:ok, relays} = select_relays(socket)
    init(socket, account, relays)

    {:noreply, socket}
  end

  # POLICY_AUTHORIZATIONS

  defp handle_change(
         %Change{
           op: :delete,
           old_struct:
             %Portal.PolicyAuthorization{
               gateway_id: gateway_id,
               client_id: client_id,
               resource_id: resource_id
             } =
               policy_authorization
         },
         %{
           assigns: %{gateway: %{id: gateway_id}}
         } = socket
       ) do
    socket.assigns.cache
    |> Cache.Gateway.reauthorize_deleted_policy_authorization(policy_authorization)
    |> case do
      {:ok, expires_at_unix, cache} ->
        Logger.info("Updating authorization expiration for deleted policy authorization",
          deleted_policy_authorization: inspect(policy_authorization),
          new_expires_at: DateTime.from_unix!(expires_at_unix, :second)
        )

        push(
          socket,
          "access_authorization_expiry_updated",
          Views.PolicyAuthorization.render(policy_authorization, expires_at_unix)
        )

        {:noreply, assign(socket, cache: cache)}

      {:error, :unauthorized, cache} ->
        Logger.info(
          "No authorizations remaining for deleted policy authorization, revoking access",
          deleted_policy_authorization: inspect(policy_authorization)
        )

        # Note: There is an edge case here:
        #   - Client authorizes policy authorization for resource
        #   - Client's websocket temporarily gets cut
        #   - Admin deletes the policy
        #   - We send reject_access to the gateway
        #   - Admin recreates the same policy (same access)
        #   - Client connection resumes
        #   - Client sees exactly the same resource list
        #   - Client now has lost the ability to recreate the policy authorization because from its perspective,
        #     it is still connected to this gateway.
        #   - Packets to gateway are essentially blackholed until the client signs out and back in

        # This will be fixed when the client responds to the ICMP prohibited by filter message:
        # https://github.com/firezone/firezone/issues/10074
        push(
          socket,
          "reject_access",
          %{client_id: client_id, resource_id: resource_id}
        )

        {:noreply, assign(socket, cache: cache)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # GATEWAYS

  defp handle_change(
         %Change{
           op: :delete,
           old_struct: %Portal.Gateway{id: gateway_id}
         },
         %{
           assigns: %{gateway: %{id: gateway_id}}
         } = socket
       ) do
    {:stop, :shutdown, socket}
  end

  # RESOURCES

  # The gateway only handles filter changes for resources. Other addressability changes like address,
  # type, or ip_stack require sending reject_access to remove the resource state from the gateway.

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Resource{
             address: old_address,
             ip_stack: old_ip_stack,
             type: old_type
           },
           struct: %Portal.Resource{address: address, ip_stack: ip_stack, type: type, id: id}
         },
         socket
       )
       when old_address != address or
              old_ip_stack != ip_stack or
              old_type != type do
    for {client_id, resource_id} <- Cache.Gateway.all_pairs_for_resource(socket.assigns.cache, id) do
      # Send reject_access to the gateway to reset state. Clients will need to reauthorize the resource.
      push(socket, "reject_access", %{client_id: client_id, resource_id: resource_id})
    end

    # The cache will be updated by the policy authorization deletion handler.
    {:noreply, socket}
  end

  defp handle_change(
         %Change{
           op: :update,
           old_struct: %Portal.Resource{filters: old_filters},
           struct: %Portal.Resource{filters: filters} = resource
         },
         socket
       )
       when old_filters != filters do
    # Send regardless of cache state - if the Gateway has no policy_authorizations for this resource,
    # it will simply ignore the message.
    resource = Cache.Cacheable.to_cache(resource)

    case Resource.adapt_resource_for_version(resource, socket.assigns.gateway.last_seen_version) do
      nil ->
        {:noreply, socket}

      adapted_resource ->
        push(socket, "resource_updated", Views.Resource.render(adapted_resource))
        {:noreply, socket}
    end
  end

  defp handle_change(%Change{}, socket), do: {:noreply, socket}

  defp load_balance_relays({lat, lon}, relays) when is_nil(lat) or is_nil(lon) do
    relays
    |> Enum.shuffle()
    |> Enum.take(2)
  end

  defp load_balance_relays({lat, lon}, relays) do
    relays
    |> Enum.map(fn relay ->
      case {relay.lat, relay.lon} do
        {nil, _} -> {nil, relay}
        {_, nil} -> {nil, relay}
        {relay_lat, relay_lon} -> {Portal.Geo.distance({lat, lon}, {relay_lat, relay_lon}), relay}
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), &nils_last/2)
    |> Enum.take(2)
    |> Enum.map(&elem(&1, 1))
  end

  defp nils_last(nil, _), do: false
  defp nils_last(_, nil), do: true
  defp nils_last(a, b), do: a <= b

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Client

    def get_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped(:replica)
      |> Safe.one!()
    end

    def preload_client_addresses(%Client{} = client) do
      Safe.preload(client, [:ipv4_address, :ipv6_address], :replica)
    end
  end
end
