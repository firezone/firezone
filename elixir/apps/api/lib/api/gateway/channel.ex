defmodule API.Gateway.Channel do
  use API, :channel
  alias API.Gateway.Views
  alias Domain.{Actors, Clients, Flows, Gateways, Policies, PubSub, Resources, Relays, Tokens}
  alias Domain.Relays.Presence.Debouncer
  require Logger
  require OpenTelemetry.Tracer

  @prune_flow_cache_every :timer.minutes(1)

  @impl true
  def join("gateway", _payload, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.join" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()
      send(self(), {:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}})

      socket =
        assign(socket,
          opentelemetry_ctx: opentelemetry_ctx,
          opentelemetry_span_ctx: opentelemetry_span_ctx
        )

      {:ok, socket}
    end
  end

  ####################################
  ##### Channel lifecycle events #####
  ####################################

  @impl true
  def handle_info({:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}}, socket) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.after_join" do
      # Initialize the cache
      socket = hydrate_cache(socket)
      Process.send_after(self(), :prune_flow_cache, @prune_flow_cache_every)

      # Track gateway's presence
      :ok = Gateways.Presence.connect(socket.assigns.gateway)

      # Subscribe to all account updates
      :ok = PubSub.Account.subscribe(socket.assigns.gateway.account_id)

      # Return all connected relays for the account
      relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(90, :day)
      {:ok, relays} = select_relays(socket)
      :ok = Enum.each(relays, &Domain.Relays.subscribe_to_relay_presence/1)
      :ok = maybe_subscribe_for_relays_presence(relays, socket)

      account = Domain.Accounts.fetch_account_by_id!(socket.assigns.gateway.account_id)

      push(socket, "init", %{
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

      # Cache new stamp secrets
      socket = Debouncer.cache_stamp_secrets(socket, relays)

      {:noreply, socket}
    end
  end

  def handle_info(:prune_flow_cache, socket) do
    Logger.debug("Pruning flow cache",
      gateway_id: socket.assigns.gateway.id,
      flow_cache_size: map_size(socket.assigns.flows)
    )

    Process.send_after(self(), :prune_flow_cache, @prune_flow_cache_every)

    cutoff = DateTime.utc_now() |> DateTime.add(-14, :day)

    # Keep flows that were inserted in the last 14 days
    flows =
      socket.assigns.flows
      |> Enum.filter(fn {_id, flow} -> flow.inserted_at > cutoff end)
      |> Enum.into(%{})

    # We don't need to push reject_access - the gateway uses its own timer to expire flows

    {:noreply, assign(socket, flows: flows)}
  end

  # Called to actually push relays_presence with a disconnected relay to the gateway
  def handle_info({:push_leave, relay_id, stamp_secret, payload}, socket) do
    {:noreply, Debouncer.handle_leave(socket, relay_id, stamp_secret, payload, &push/3)}
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  # CLIENTS

  # Expire flows for this client because unverifying a client can remove access
  # to resources, but we don't necessarily know which ones.
  def handle_info(
        {:updated, %Clients.Client{verified_at: old_verified_at},
         %Clients.Client{verified_at: nil, id: client_id}},
        socket
      )
      when old_verified_at != nil do
    socket = reject_access(socket, fn {_id, f} -> f.client_id == client_id end)
    {:noreply, socket}
  end

  # POLICIES

  # TODO: HARD DELETE
  # This can be removed when hard deletion is implemented because we will respond to the cascading
  # flow deletion when a policy is deleted. For now we need to handle this event.
  def handle_info({:deleted, %Policies.Policy{id: policy_id}}, socket) do
    socket = reject_access(socket, fn {_id, f} -> f.policy_id == policy_id end)
    {:noreply, socket}
  end

  # RESOURCES

  # The gateway can process traffic filter changes, but not any other type of addressability change.
  # So we send resource_updated for the former, and reject_access for the latter.
  # The client will request a new connection on its side if the resource addressability changes.
  def handle_info(
        {:updated,
         %Resources.Resource{ip_stack: old_ip_stack, address: old_address, type: old_type},
         %Resources.Resource{ip_stack: ip_stack, address: address, type: type, id: resource_id}},
        socket
      )
      when old_ip_stack != ip_stack or old_address != address or old_type != type do
    socket = reject_access(socket, fn {_id, f} -> f.resource_id == resource_id end)
    {:noreply, socket}
  end

  def handle_info(
        {:updated, %Resources.Resource{filters: old_filters},
         %Resources.Resource{filters: filters} = resource},
        socket
      )
      when old_filters != filters do
    has_flows? = Enum.any?(socket.assigns.flows, fn {_id, f} -> f.resource_id == resource.id end)

    if has_flows? do
      push(socket, "resource_updated", Views.Resource.render(resource))
    end

    {:noreply, socket}
  end

  def handle_info({:deleted, %Resources.Resource{id: resource_id}}, socket) do
    socket = reject_access(socket, fn {_id, f} -> f.resource_id == resource_id end)
    {:noreply, socket}
  end

  # RESOURCE_CONNECTIONS

  def handle_info({:deleted, %Resources.Connection{resource_id: resource_id}}, socket) do
    socket = reject_access(socket, fn {_id, f} -> f.resource_id == resource_id end)
    {:noreply, socket}
  end

  # GATEWAYS

  # TODO: HARD DELETE
  # This can be removed when hard deletion is implemented because we will respond to the
  # cascading flow deletion when a gateway is deleted.

  def handle_info(
        {:deleted, %Gateways.Gateway{id: gateway_id}},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    disconnect(socket)
  end

  # CLIENTS

  # TODO: HARD DELETE
  # This can be removed after hard deletion is implemented because we will respond to the cascading
  # flow deletion when a client is deleted.
  def handle_info({:deleted, %Clients.Client{id: client_id}}, socket) do
    socket = reject_access(socket, fn {_id, f} -> f.client_id == client_id end)
    {:noreply, socket}
  end

  # TOKENS

  # Our gateway token was deleted
  def handle_info({:deleted, %Tokens.Token{type: :gateway_group, id: id}}, socket)
      when id == socket.assigns.subject.token_id do
    disconnect(socket)
  end

  # TODO: HARD DELETE
  # This can be removed when hard deletion is implemented because we will respond to the
  # cascading flow deletion when a token is deleted.

  # A client's token was deleted, remove all flows for that token
  def handle_info({:deleted, %Tokens.Token{type: :client, id: token_id}}, socket) do
    socket = reject_access(socket, fn {_id, f} -> f.token_id == token_id end)
    {:noreply, socket}
  end

  # ACTOR_GROUP_MEMBERSHIPS

  def handle_info({:deleted, %Actors.Membership{} = membership}, socket) do
    socket =
      reject_access(socket, fn {_id, f} ->
        f.actor_group_membership_id == membership.id
      end)

    {:noreply, socket}
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
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    if Map.has_key?(leaves, relay_id) do
      OpenTelemetry.Tracer.with_span "gateway.relays_presence",
        attributes: %{
          relay_id: relay_id
        } do
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
      end
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
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    if Enum.count(joins) > 0 do
      OpenTelemetry.Tracer.with_span "gateway.account_relays_presence" do
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
        end
      end
    else
      {:noreply, socket}
    end
  end

  ##############################################################
  ##### Forwarding messages from the client to the gateway #####
  ##############################################################

  def handle_info(
        {{:ice_candidates, gateway_id}, client_id, candidates,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.ice_candidates",
      attributes: %{
        client_id: client_id,
        candidates_length: length(candidates)
      } do
      push(socket, "ice_candidates", %{
        client_id: client_id,
        candidates: candidates
      })

      {:noreply, socket}
    end
  end

  def handle_info(
        {{:invalidate_ice_candidates, gateway_id}, client_id, candidates,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.invalidate_ice_candidates",
      attributes: %{
        client_id: client_id,
        candidates_length: length(candidates)
      } do
      push(socket, "invalidate_ice_candidates", %{
        client_id: client_id,
        candidates: candidates
      })

      {:noreply, socket}
    end
  end

  def handle_info(
        {{:authorize_flow, gateway_id}, {channel_pid, socket_ref}, payload,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    %{
      client: client,
      resource: resource,
      flow: flow,
      authorization_expires_at: authorization_expires_at,
      ice_credentials: ice_credentials,
      preshared_key: preshared_key
    } = payload

    OpenTelemetry.Tracer.with_span "gateway.authorize_flow" do
      Logger.debug("Gateway authorizes a new network flow",
        flow: flow
      )

      opentelemetry_headers = :otel_propagator_text_map.inject([])

      ref =
        encode_ref(socket, {
          channel_pid,
          socket_ref,
          flow.resource_id,
          preshared_key,
          ice_credentials,
          opentelemetry_headers
        })

      # Update our state
      socket = assign(socket, flows: Map.put(socket.assigns.flows, flow.id, flow))

      push(socket, "authorize_flow", %{
        ref: ref,
        flow_id: flow.id,
        actor: Views.Actor.render(client.actor),
        resource: Views.Resource.render(resource),
        gateway_ice_credentials: ice_credentials.gateway,
        client: Views.Client.render(client, preshared_key),
        client_ice_credentials: ice_credentials.client,
        # Gateway manages its own expiration
        expires_at:
          if(authorization_expires_at,
            do: DateTime.to_unix(authorization_expires_at, :second)
          )
      })

      Logger.debug("Awaiting gateway flow_authorized message",
        flow: flow
      )

      {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:allow_access, gateway_id}, {channel_pid, socket_ref}, attrs,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    %{
      client: client,
      resource: resource,
      flow: flow,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    OpenTelemetry.Tracer.with_span "gateway.allow_access",
      attributes: %{
        flow_id: flow.id,
        client_id: client.id,
        resource_id: resource.id
      } do
      case API.Client.Channel.map_or_drop_compatible_resource(
             resource,
             socket.assigns.gateway.last_seen_version
           ) do
        {:cont, resource} ->
          opentelemetry_headers = :otel_propagator_text_map.inject([])
          ref = encode_ref(socket, {channel_pid, socket_ref, resource.id, opentelemetry_headers})
          expires_at = DateTime.to_unix(authorization_expires_at, :second)

          # Update our state
          socket = assign(socket, flows: Map.put(socket.assigns.flows, flow.id, flow))

          push(socket, "allow_access", %{
            ref: ref,
            client_id: client.id,
            resource: Views.Resource.render(resource),
            expires_at: expires_at,
            payload: payload,
            client_ipv4: client.ipv4,
            client_ipv6: client.ipv6
          })

          Logger.debug("Awaiting gateway connection_ready message",
            client_id: client.id,
            resource_id: resource.id,
            flow_id: flow.id
          )

          {:noreply, socket}

        :drop ->
          Logger.debug("Resource is not compatible with the gateway version",
            gateway_id: socket.assigns.gateway.id,
            client_id: client.id,
            resource_id: resource.id,
            flow_id: flow.id
          )

          {:noreply, socket}
      end
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {{:request_connection, gateway_id}, {channel_pid, socket_ref}, attrs,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        %{assigns: %{gateway: %{id: id}}} = socket
      )
      when gateway_id == id do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    %{
      client: client,
      resource: resource,
      flow: flow,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload,
      client_preshared_key: preshared_key
    } = attrs

    OpenTelemetry.Tracer.with_span "gateway.request_connection" do
      Logger.debug("Gateway received connection request message",
        client_id: client.id,
        resource_id: resource.id
      )

      case API.Client.Channel.map_or_drop_compatible_resource(
             resource,
             socket.assigns.gateway.last_seen_version
           ) do
        {:cont, resource} ->
          opentelemetry_headers = :otel_propagator_text_map.inject([])
          ref = encode_ref(socket, {channel_pid, socket_ref, resource.id, opentelemetry_headers})
          expires_at = DateTime.to_unix(authorization_expires_at, :second)

          # Update our state
          socket = assign(socket, flows: Map.put(socket.assigns.flows, flow.id, flow))

          push(socket, "request_connection", %{
            ref: ref,
            actor: Views.Actor.render(client.actor),
            resource: Views.Resource.render(resource),
            client: Views.Client.render(client, payload, preshared_key),
            expires_at: expires_at
          })

          Logger.debug("Awaiting gateway connection_ready message",
            client_id: client.id,
            resource_id: resource.id,
            flow_id: flow.id
          )

          {:noreply, socket}

        :drop ->
          Logger.debug("Resource is not compatible with the gateway version",
            gateway_id: socket.assigns.gateway.id,
            client_id: client.id,
            resource_id: resource.id,
            flow_id: flow.id
          )

          {:noreply, socket}
      end
    end
  end

  # Catch-all for messages we don't handle
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_in("flow_authorized", %{"ref" => signed_ref}, socket) do
    OpenTelemetry.Tracer.with_span "gateway.flow_authorized" do
      case decode_ref(socket, signed_ref) do
        {:ok,
         {
           channel_pid,
           socket_ref,
           resource_id,
           preshared_key,
           ice_credentials,
           opentelemetry_headers
         }} ->
          :otel_propagator_text_map.extract(opentelemetry_headers)

          opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
          opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

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
              ice_credentials,
              {opentelemetry_ctx, opentelemetry_span_ctx}
            }
          )

          Logger.debug("Gateway replied to the Client with :authorize_flow message",
            resource_id: resource_id,
            channel_pid: inspect(channel_pid)
          )

          {:reply, :ok, socket}

        {:error, :invalid_ref} ->
          OpenTelemetry.Tracer.set_status(:error, "invalid ref")
          Logger.error("Gateway replied with an invalid ref")
          {:reply, {:error, %{reason: :invalid_ref}}, socket}
      end
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
    OpenTelemetry.Tracer.with_span "gateway.connection_ready" do
      case decode_ref(socket, signed_ref) do
        {:ok, {channel_pid, socket_ref, resource_id, opentelemetry_headers}} ->
          :otel_propagator_text_map.extract(opentelemetry_headers)

          opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
          opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

          send(
            channel_pid,
            {:connect, socket_ref, resource_id, socket.assigns.gateway.public_key, payload,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )

          Logger.debug("Gateway replied to the Client with :connect message",
            resource_id: resource_id,
            channel_pid: inspect(channel_pid)
          )

          {:reply, :ok, socket}

        {:error, :invalid_ref} ->
          OpenTelemetry.Tracer.set_status(:error, "invalid ref")
          Logger.error("Gateway replied with an invalid ref")
          {:reply, {:error, %{reason: :invalid_ref}}, socket}
      end
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
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.broadcast_ice_candidates" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      :ok =
        Enum.each(client_ids, fn client_id ->
          PubSub.Account.broadcast(
            socket.assigns.gateway.account_id,
            {{:ice_candidates, client_id}, socket.assigns.gateway.id, candidates,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )
        end)

      {:noreply, socket}
    end
  end

  def handle_in(
        "broadcast_invalidated_ice_candidates",
        %{"candidates" => candidates, "client_ids" => client_ids},
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.broadcast_invalidated_ice_candidates" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      :ok =
        Enum.each(client_ids, fn client_id ->
          PubSub.Account.broadcast(
            socket.assigns.gateway.account_id,
            {{:invalidate_ice_candidates, client_id}, socket.assigns.gateway.id, candidates,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )
        end)

      {:noreply, socket}
    end
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

    OpenTelemetry.Tracer.set_attribute(:relays_length, length(relays))

    relays = Relays.load_balance_relays(location, relays)

    {:ok, relays}
  end

  defp maybe_subscribe_for_relays_presence(relays, socket) do
    if length(relays) > 0 do
      :ok
    else
      Relays.subscribe_to_relays_presence_in_account(socket.assigns.gateway.account_id)
    end
  end

  defp hydrate_cache(socket) do
    flows =
      Flows.all_gateway_flows_for_cache!(socket.assigns.gateway)
      |> Enum.map(fn flow -> {flow.id, flow} end)
      |> Enum.into(%{})

    assign(socket, flows: flows)
  end

  defp reject_access(socket, filter_fn) do
    flows =
      socket.assigns.flows
      |> Enum.filter(filter_fn)
      |> Enum.into(%{})

    case flows do
      flows when map_size(flows) == 0 ->
        socket

      flows ->
        # Send reject_access for each affected client/resource pair
        flows
        |> Enum.map(fn {_id, flow} ->
          {flow.client_id, flow.resource_id}
        end)
        |> Enum.uniq()
        |> Enum.each(fn {client_id, resource_id} ->
          push(socket, "reject_access", %{
            client_id: client_id,
            resource_id: resource_id
          })
        end)

        # Remove affected flows from cache
        assign(socket, flows: Map.drop(socket.assigns.flows, Map.keys(flows)))
    end
  end

  defp disconnect(socket) do
    push(socket, "disconnect", %{"reason" => "token_expired"})
    send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
    {:stop, :shutdown, socket}
  end
end
