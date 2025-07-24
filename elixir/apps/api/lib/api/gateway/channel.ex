defmodule API.Gateway.Channel do
  use API, :channel
  alias API.Gateway.Views
  alias Domain.{Accounts, Flows, Gateways, PubSub, Relays, Resources, Tokens}
  alias Domain.Relays.Presence.Debouncer
  require Logger
  require OpenTelemetry.Tracer

  # The interval at which the flow cache is pruned.
  @prune_flow_cache_every :timer.minutes(1)

  # All relayed connections are dropped when this expires, so use
  # a long expiration time to avoid frequent disconnections.
  @relay_credentials_expire_in_hours 90 * 24

  @impl true
  def join("gateway", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def handle_info(:after_join, socket) do
    # Initialize the cache
    socket = hydrate_flows(socket)
    Process.send_after(self(), :prune_flow_cache, @prune_flow_cache_every)

    # Track gateway's presence
    :ok = Gateways.Presence.connect(socket.assigns.gateway)

    # Subscribe to all account updates
    :ok = PubSub.Account.subscribe(socket.assigns.gateway.account_id)

    # Return all connected relays for the account
    {:ok, relays} = select_relays(socket)
    :ok = Enum.each(relays, &Domain.Relays.subscribe_to_relay_presence/1)
    :ok = maybe_subscribe_for_relays_presence(relays, socket)

    account = Domain.Accounts.fetch_account_by_id!(socket.assigns.gateway.account_id)

    init(socket, account, relays)

    # Cache new stamp secrets
    socket = Debouncer.cache_stamp_secrets(socket, relays)

    {:noreply, socket}
  end

  def handle_info(:prune_flow_cache, socket) do
    Process.send_after(self(), :prune_flow_cache, @prune_flow_cache_every)

    now = DateTime.utc_now()

    # 1. Remove individual flows older than 14 days, then remove access entry if no flows left
    flows =
      socket.assigns.flows
      |> Enum.map(fn {tuple, flow_id_map} ->
        flow_id_map =
          Enum.reject(flow_id_map, fn {_flow_id, expires_at} ->
            DateTime.compare(expires_at, now) == :lt
          end)
          |> Enum.into(%{})

        {tuple, flow_id_map}
      end)
      |> Enum.into(%{})
      |> Enum.reject(fn {_tuple, flow_id_map} -> map_size(flow_id_map) == 0 end)
      |> Enum.into(%{})

    # The gateway has its own flow expiration, so no need to send `reject_access`

    {:noreply, assign(socket, flows: flows)}
  end

  # Called to actually push relays_presence with a disconnected relay to the gateway
  def handle_info({:push_leave, relay_id, stamp_secret, payload}, socket) do
    {:noreply, Debouncer.handle_leave(socket, relay_id, stamp_secret, payload, &push/3)}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  # ACCOUNTS

  # Resend init when config changes so that new slug may be applied
  def handle_info(
        {:updated, %Accounts.Account{slug: old_slug}, %Accounts.Account{slug: slug} = account},
        socket
      )
      when old_slug != slug do
    {:ok, relays} = select_relays(socket)
    init(socket, account, relays)

    {:noreply, socket}
  end

  # FLOWS

  def handle_info({:deleted, %Flows.Flow{} = flow}, socket) do
    tuple = {flow.client_id, flow.resource_id}

    socket =
      if flow_map = Map.get(socket.assigns.flows, tuple) do
        flow_map = Map.delete(flow_map, flow.id)

        if map_size(flow_map) == 0 do
          # Send reject_access if this was the last flow granting access for this client/resource
          push(socket, "reject_access", %{
            client_id: flow.client_id,
            resource_id: flow.resource_id
          })

          assign(socket, flows: Map.delete(socket.assigns.flows, tuple))
        else
          # "Pick" a new flow to move to based on earliest expiration, and tell the Gateway
          earliest_expiration =
            flow_map
            |> Map.values()
            |> Enum.min()

          push(
            socket,
            "access_authorization_expiry_updated",
            Views.Flow.render(flow, earliest_expiration)
          )

          assign(socket, flows: Map.put(socket.assigns.flows, tuple, flow_map))
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # RESOURCES

  # The gateway only handles filter changes. Other breaking changes are handled by deleting
  # relevant flows for the resource.
  def handle_info(
        {:updated, %Resources.Resource{filters: old_filters},
         %Resources.Resource{filters: filters, id: id} = resource},
        socket
      )
      when old_filters != filters do
    has_flows? =
      socket.assigns.flows
      |> Enum.any?(fn {{_client_id, resource_id}, _flow_map} -> resource_id == id end)

    if has_flows? do
      push(socket, "resource_updated", Views.Resource.render(resource))
    end

    {:noreply, socket}
  end

  # TOKENS

  # Our gateway token was deleted - disconnect WebSocket
  def handle_info({:deleted, %Tokens.Token{type: :gateway_group, id: id}}, socket)
      when id == socket.assigns.token_id do
    disconnect(socket)
  end

  ####################################
  #### Reacting to relay presence ####
  ####################################

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:relays:" <> relay_id,
          payload: %{leaves: leaves}
        },
        socket
      ) do
    if Map.has_key?(leaves, relay_id) do
      :ok = Domain.Relays.unsubscribe_from_relay_presence(relay_id)

      relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(90, :day)
      {:ok, relays} = select_relays(socket, [relay_id])
      :ok = maybe_subscribe_for_relays_presence(relays, socket)

      :ok =
        Enum.each(relays, fn relay ->
          # TODO: WAL
          # Why are we unsubscribing and subscribing again?
          :ok = Domain.Relays.unsubscribe_from_relay_presence(relay)
          :ok = Domain.Relays.subscribe_to_relay_presence(relay)
        end)

      payload = %{
        disconnected_ids: [relay_id],
        connected:
          Views.Relay.render_many(
            relays,
            socket.assigns.gateway.public_key,
            relay_credentials_expire_at
          )
      }

      socket = Debouncer.queue_leave(self(), socket, relay_id, payload)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:" <> _,
          payload: %{joins: joins}
        },
        socket
      )
      when map_size(joins) > 0 do
    {:ok, relays} = select_relays(socket)

    if length(relays) > 0 do
      relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(90, :day)

      :ok =
        Relays.unsubscribe_from_relays_presence_in_account(socket.assigns.gateway.account_id)

      :ok =
        Enum.each(relays, fn relay ->
          # TODO: WAL
          # Why are we unsubscribing and subscribing again?
          :ok = Relays.unsubscribe_from_relay_presence(relay)
          :ok = Relays.subscribe_to_relay_presence(relay)
        end)

      # Cache new stamp secrets
      socket = Debouncer.cache_stamp_secrets(socket, relays)

      # If a relay reconnects with a different stamp_secret, disconnect them immediately
      joined_ids = Map.keys(joins)

      {socket, disconnected_ids} =
        Debouncer.cancel_leaves_or_disconnect_immediately(
          socket,
          joined_ids,
          socket.assigns.gateway.account_id
        )

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

  ###########################
  #### Connection setup #####
  ###########################

  def handle_info(
        {{:ice_candidates, gateway_id}, client_id, candidates},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    push(socket, "ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:invalidate_ice_candidates, gateway_id}, client_id, candidates},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    push(socket, "invalidate_ice_candidates", %{
      client_id: client_id,
      candidates: candidates
    })

    {:noreply, socket}
  end

  def handle_info(
        {{:authorize_flow, gateway_id}, {channel_pid, socket_ref}, payload},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    %{
      client: client,
      resource: resource,
      flows_map: flows_map,
      ice_credentials: ice_credentials,
      preshared_key: preshared_key
    } = payload

    ref =
      encode_ref(socket, {
        channel_pid,
        socket_ref,
        resource.id,
        preshared_key,
        ice_credentials
      })

    min_expires_at = flows_map |> Map.values() |> Enum.min()

    push(socket, "authorize_flow", %{
      ref: ref,
      resource: Views.Resource.render(resource),
      gateway_ice_credentials: ice_credentials.gateway,
      client: Views.Client.render(client, preshared_key),
      client_ice_credentials: ice_credentials.client,
      expires_at: DateTime.to_unix(min_expires_at, :second)
    })

    # Start tracking flow
    tuple = {client.id, resource.id}

    flow_map =
      Map.get(socket.assigns.flows, tuple, %{})
      |> Map.merge(flows_map)

    flows = Map.put(socket.assigns.flows, tuple, flow_map)
    socket = assign(socket, flows: flows)

    {:noreply, socket}
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:allow_access, gateway_id}, {channel_pid, socket_ref}, attrs},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    %{
      client: client,
      resource: resource,
      flows_map: flows_map,
      client_payload: payload
    } = attrs

    case API.Client.Channel.map_or_drop_compatible_resource(
           resource,
           socket.assigns.gateway.last_seen_version
         ) do
      {:cont, resource} ->
        ref =
          encode_ref(
            socket,
            {channel_pid, socket_ref, resource.id}
          )

        min_expires_at = flows_map |> Map.values() |> Enum.min()

        push(socket, "allow_access", %{
          ref: ref,
          client_id: client.id,
          resource: Views.Resource.render(resource),
          expires_at: DateTime.to_unix(min_expires_at, :second),
          payload: payload,
          client_ipv4: client.ipv4,
          client_ipv6: client.ipv6
        })

        # Start tracking the flow
        tuple = {client.id, resource.id}

        flow_map =
          Map.get(socket.assigns.flows, tuple, %{})
          |> Map.merge(flows_map)

        flows = Map.put(socket.assigns.flows, tuple, flow_map)
        socket = assign(socket, flows: flows)

        {:noreply, socket}

      :drop ->
        {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:request_connection, gateway_id}, {channel_pid, socket_ref}, attrs},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    %{
      client: client,
      resource: resource,
      flows_map: flows_map,
      client_payload: payload,
      client_preshared_key: preshared_key
    } = attrs

    case API.Client.Channel.map_or_drop_compatible_resource(
           resource,
           socket.assigns.gateway.last_seen_version
         ) do
      {:cont, resource} ->
        ref =
          encode_ref(
            socket,
            {channel_pid, socket_ref, resource.id}
          )

        min_expires_at = flows_map |> Map.values() |> Enum.min()

        push(socket, "request_connection", %{
          ref: ref,
          resource: Views.Resource.render(resource),
          client: Views.Client.render(client, payload, preshared_key),
          expires_at: DateTime.to_unix(min_expires_at, :second)
        })

        # Start tracking the flow
        tuple = {client.id, resource.id}

        flow_map =
          Map.get(socket.assigns.flows, tuple, %{})
          |> Map.merge(flows_map)

        flows = Map.put(socket.assigns.flows, tuple, flow_map)
        socket = assign(socket, flows: flows)

        {:noreply, socket}

      :drop ->
        {:noreply, socket}
    end
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
            socket.assigns.gateway.group_id,
            socket.assigns.gateway.id,
            socket.assigns.gateway.public_key,
            socket.assigns.gateway.ipv4,
            socket.assigns.gateway.ipv6,
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
      {:ok, {channel_pid, socket_ref, resource_id}} ->
        send(
          channel_pid,
          {:connect, socket_ref, resource_id, socket.assigns.gateway.public_key, payload}
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
      Relays.all_connected_relays_for_account(socket.assigns.gateway.account_id, except_ids)

    location = {
      socket.assigns.gateway.last_seen_remote_ip_location_lat,
      socket.assigns.gateway.last_seen_remote_ip_location_lon
    }

    relays = Relays.load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp init(socket, account, relays) do
    relay_credentials_expire_at =
      DateTime.utc_now() |> DateTime.add(@relay_credentials_expire_in_hours, :hour)

    push(socket, "init", %{
      authorizations: Views.Flow.render_many(socket.assigns.flows),
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

  defp maybe_subscribe_for_relays_presence(relays, socket) do
    if length(relays) > 0 do
      :ok
    else
      Relays.subscribe_to_relays_presence_in_account(socket.assigns.gateway.account_id)
    end
  end

  defp hydrate_flows(socket) do
    OpenTelemetry.Tracer.with_span "gateway.hydrate_flows",
      attributes: %{
        gateway_id: socket.assigns.gateway.id,
        account_id: socket.assigns.gateway.account_id
      } do
      flows =
        Flows.all_gateway_flows_for_cache!(socket.assigns.gateway)
        # Reduces [ {client_id, resource_id}, {flow_id, inserted_at} ]
        #
        # to %{ {client_id, resource_id} => %{flow_id => expires_at} }
        #
        # This data structure is used to efficiently:
        #   1. Check if there are any active flows remaining for this client/resource?
        #   2. Remove a deleted flow
        |> Enum.reduce(%{}, fn {{client_id, resource_id}, {flow_id, expires_at}}, acc ->
          flow_id_map = Map.get(acc, {client_id, resource_id}, %{})

          Map.put(acc, {client_id, resource_id}, Map.put(flow_id_map, flow_id, expires_at))
        end)

      assign(socket, flows: flows)
    end
  end

  defp disconnect(socket) do
    push(socket, "disconnect", %{"reason" => "token_expired"})
    send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
    {:stop, :shutdown, socket}
  end
end
