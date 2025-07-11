defmodule API.Gateway.Channel do
  use API, :channel
  alias API.Gateway.Views
  alias Domain.{Clients, Gateways, PubSub, Resources, Relays}
  alias Domain.Relays.Presence.Debouncer
  require Logger
  require OpenTelemetry.Tracer

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
      :ok = Gateways.Presence.connect(socket.assigns.gateway)

      # Return all connected relays for the account
      relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(14, :day)
      {:ok, relays} = select_relays(socket)
      :ok = Enum.each(relays, &Domain.Relays.subscribe_to_relay_presence/1)
      :ok = maybe_subscribe_for_relays_presence(relays, socket)

      account = Domain.Accounts.fetch_account_by_id!(socket.assigns.gateway.account_id)

      push(socket, "init", %{
        account_slug: account.slug,
        interface: Views.Interface.render(socket.assigns.gateway),
        relays: Views.Relay.render_many(relays, relay_credentials_expire_at),
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

  # Called to actually push relays_presence with a disconnected relay to the gateway
  def handle_info({:push_leave, relay_id, stamp_secret, payload}, socket) do
    {:noreply, Debouncer.handle_leave(socket, relay_id, stamp_secret, payload, &push/3)}
  end

  def handle_info("disconnect", socket) do
    OpenTelemetry.Tracer.with_span "gateway.disconnect" do
      push(socket, "disconnect", %{"reason" => "token_expired"})
      send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
      {:stop, :shutdown, socket}
    end
  end

  ####################################
  ##### Reacting to domain events ####
  ####################################

  # Resource create message is a no-op for the Gateway as the Resource
  # details will be sent to the Gateway on an :authorize_flow message
  def handle_info({:create_resource, _resource_id}, socket) do
    {:noreply, socket}
  end

  # Resource is updated, eg. traffic filters are changed
  def handle_info({:update_resource, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.resource_updated",
      attributes: %{resource_id: resource_id} do
      resource = Resources.fetch_resource_by_id!(resource_id)

      case API.Client.Channel.map_or_drop_compatible_resource(
             resource,
             socket.assigns.gateway.last_seen_version
           ) do
        {:cont, resource} ->
          push(socket, "resource_updated", Views.Resource.render(resource))

        :drop ->
          Logger.debug("Resource is not compatible with the gateway version",
            gateway_id: socket.assigns.gateway.id,
            resource_id: resource_id
          )
      end

      {:noreply, socket}
    end
  end

  # This event is ignored because we will receive a reject_access message from
  # the Flows which will trigger a reject_access event
  def handle_info({:delete_resource, resource_id}, socket) do
    :ok = PubSub.Resource.unsubscribe(resource_id)
    {:noreply, socket}
  end

  # Flows context broadcasts this message when flow is expired,
  # which happens when policy, resource, actor, group, identity or provider were
  # disabled or deleted
  def handle_info({:expire_flow, flow_id, client_id, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.reject_access",
      attributes: %{
        flow_id: flow_id,
        client_id: client_id,
        resource_id: resource_id
      } do
      :ok = PubSub.Flow.unsubscribe(flow_id)

      push(socket, "reject_access", %{
        flow_id: flow_id,
        client_id: client_id,
        resource_id: resource_id
      })

      {:noreply, socket}
    end
  end

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

        relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(14, :day)
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
          connected: Views.Relay.render_many(relays, relay_credentials_expire_at)
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
          relay_credentials_expire_at = DateTime.utc_now() |> DateTime.add(14, :day)

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
            connected: Views.Relay.render_many(relays, relay_credentials_expire_at)
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
        {:ice_candidates, client_id, candidates, {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
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
        {:invalidate_ice_candidates, client_id, candidates,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
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
        {:authorize_flow, {channel_pid, socket_ref}, payload,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    %{
      client_id: client_id,
      resource_id: resource_id,
      flow_id: flow_id,
      authorization_expires_at: authorization_expires_at,
      ice_credentials: ice_credentials,
      preshared_key: preshared_key
    } = payload

    OpenTelemetry.Tracer.with_span "gateway.authorize_flow" do
      :ok = PubSub.Flow.subscribe(flow_id)

      Logger.debug("Gateway authorizes a new network flow",
        flow_id: flow_id,
        client_id: client_id,
        resource_id: resource_id
      )

      client = Clients.fetch_client_by_id!(client_id, preload: [:actor])
      resource = Resources.fetch_resource_by_id!(resource_id)

      # TODO: WAL
      # Why are we unsubscribing and subscribing again?
      :ok = PubSub.Resource.unsubscribe(resource_id)
      :ok = PubSub.Resource.subscribe(resource_id)

      opentelemetry_headers = :otel_propagator_text_map.inject([])

      ref =
        encode_ref(socket, {
          channel_pid,
          socket_ref,
          resource_id,
          preshared_key,
          ice_credentials,
          opentelemetry_headers
        })

      push(socket, "authorize_flow", %{
        ref: ref,
        flow_id: flow_id,
        actor: Views.Actor.render(client.actor),
        resource: Views.Resource.render(resource),
        gateway_ice_credentials: ice_credentials.gateway,
        client: Views.Client.render(client, preshared_key),
        client_ice_credentials: ice_credentials.client,
        expires_at:
          if(authorization_expires_at, do: DateTime.to_unix(authorization_expires_at, :second))
      })

      Logger.debug("Awaiting gateway flow_authorized message",
        client_id: client_id,
        resource_id: resource_id,
        flow_id: flow_id
      )

      {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {:allow_access, {channel_pid, socket_ref}, attrs,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    %{
      client_id: client_id,
      resource_id: resource_id,
      flow_id: flow_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload
    } = attrs

    OpenTelemetry.Tracer.with_span "gateway.allow_access",
      attributes: %{
        flow_id: flow_id,
        client_id: client_id,
        resource_id: resource_id
      } do
      :ok = PubSub.Flow.subscribe(flow_id)

      client = Clients.fetch_client_by_id!(client_id)
      resource = Resources.fetch_resource_by_id!(resource_id)

      case API.Client.Channel.map_or_drop_compatible_resource(
             resource,
             socket.assigns.gateway.last_seen_version
           ) do
        {:cont, resource} ->
          # TODO: WAL
          # Why are we unsubscribing and subscribing again?
          :ok = PubSub.Resource.unsubscribe(resource_id)
          :ok = PubSub.Resource.subscribe(resource_id)

          opentelemetry_headers = :otel_propagator_text_map.inject([])
          ref = encode_ref(socket, {channel_pid, socket_ref, resource_id, opentelemetry_headers})

          push(socket, "allow_access", %{
            ref: ref,
            client_id: client_id,
            flow_id: flow_id,
            resource: Views.Resource.render(resource),
            expires_at: DateTime.to_unix(authorization_expires_at, :second),
            payload: payload,
            client_ipv4: client.ipv4,
            client_ipv6: client.ipv6
          })

          Logger.debug("Awaiting gateway connection_ready message",
            client_id: client_id,
            resource_id: resource_id,
            flow_id: flow_id
          )

        :drop ->
          Logger.debug("Resource is not compatible with the gateway version",
            gateway_id: socket.assigns.gateway.id,
            client_id: client_id,
            resource_id: resource_id,
            flow_id: flow_id
          )
      end

      {:noreply, socket}
    end
  end

  # DEPRECATED IN 1.4
  def handle_info(
        {:request_connection, {channel_pid, socket_ref}, attrs,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    %{
      client_id: client_id,
      resource_id: resource_id,
      flow_id: flow_id,
      authorization_expires_at: authorization_expires_at,
      client_payload: payload,
      client_preshared_key: preshared_key
    } = attrs

    OpenTelemetry.Tracer.with_span "gateway.request_connection" do
      :ok = PubSub.Flow.subscribe(flow_id)

      Logger.debug("Gateway received connection request message",
        client_id: client_id,
        resource_id: resource_id
      )

      client = Clients.fetch_client_by_id!(client_id, preload: [:actor])
      resource = Resources.fetch_resource_by_id!(resource_id)

      case API.Client.Channel.map_or_drop_compatible_resource(
             resource,
             socket.assigns.gateway.last_seen_version
           ) do
        {:cont, resource} ->
          # TODO: WAL
          # Why are we unsubscribing and subscribing again?
          :ok = PubSub.Resource.unsubscribe(resource_id)
          :ok = PubSub.Resource.subscribe(resource_id)

          opentelemetry_headers = :otel_propagator_text_map.inject([])
          ref = encode_ref(socket, {channel_pid, socket_ref, resource_id, opentelemetry_headers})

          push(socket, "request_connection", %{
            ref: ref,
            flow_id: flow_id,
            actor: Views.Actor.render(client.actor),
            resource: Views.Resource.render(resource),
            client: Views.Client.render(client, payload, preshared_key),
            expires_at: DateTime.to_unix(authorization_expires_at, :second)
          })

          Logger.debug("Awaiting gateway connection_ready message",
            client_id: client_id,
            resource_id: resource_id,
            flow_id: flow_id
          )

        :drop ->
          Logger.debug("Resource is not compatible with the gateway version",
            gateway_id: socket.assigns.gateway.id,
            client_id: client_id,
            resource_id: resource_id,
            flow_id: flow_id
          )
      end

      {:noreply, socket}
    end
  end

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
          PubSub.Client.broadcast(
            client_id,
            {:ice_candidates, socket.assigns.gateway.id, candidates,
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
          PubSub.Client.broadcast(
            client_id,
            {:invalidate_ice_candidates, socket.assigns.gateway.id, candidates,
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
end
