defmodule API.Gateway.Channel do
  use API, :channel
  alias API.Gateway.Views
  alias Domain.{Clients, Resources, Relays, Gateways, Flows}
  require Logger
  require OpenTelemetry.Tracer

  def broadcast(%Gateways.Gateway{} = gateway, payload) do
    broadcast(gateway.id, payload)
  end

  def broadcast(gateway_id, payload) do
    Logger.debug("Gateway message is being dispatched", gateway_id: gateway_id)
    Phoenix.PubSub.broadcast(Domain.PubSub, "gateway:#{gateway_id}", payload)
  end

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
          opentelemetry_span_ctx: opentelemetry_span_ctx,
          refs: %{}
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}}, socket) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.after_join" do
      :ok = Gateways.connect_gateway(socket.assigns.gateway)
      :ok = API.Endpoint.subscribe("gateway:#{socket.assigns.gateway.id}")

      config = Domain.Config.fetch_env!(:domain, Domain.Gateways)
      ipv4_masquerade_enabled = Keyword.fetch!(config, :gateway_ipv4_masquerade)
      ipv6_masquerade_enabled = Keyword.fetch!(config, :gateway_ipv6_masquerade)

      push(socket, "init", %{
        interface: Views.Interface.render(socket.assigns.gateway),
        # TODO: move to settings
        ipv4_masquerade_enabled: ipv4_masquerade_enabled,
        ipv6_masquerade_enabled: ipv6_masquerade_enabled
      })

      {:noreply, socket}
    end
  end

  def handle_info({:resource_created, _resource_id}, socket) do
    {:noreply, socket}
  end

  def handle_info({:resource_updated, _resource_id}, socket) do
    {:noreply, socket}
  end

  def handle_info({:resource_deleted, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.resource_deleted", %{resource_id: resource_id} do
      :ok = Resources.unsubscribe_from_resource_events(resource_id)
      push(socket, "resource_deleted", resource_id)
      {:noreply, socket}
    end
  end

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
        {:allow_access, {channel_pid, socket_ref}, attrs,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.allow_access" do
      %{
        client_id: client_id,
        resource_id: resource_id,
        flow_id: flow_id,
        authorization_expires_at: authorization_expires_at,
        client_payload: payload
      } = attrs

      resource = Resources.fetch_resource_by_id!(resource_id)
      :ok = Resources.subscribe_for_resource_events(resource)

      ref = Ecto.UUID.generate()

      push(socket, "allow_access", %{
        ref: ref,
        client_id: client_id,
        flow_id: flow_id,
        resource: Views.Resource.render(resource),
        expires_at: DateTime.to_unix(authorization_expires_at, :second),
        payload: payload
      })

      Logger.debug("Awaiting gateway connection_ready message",
        client_id: client_id,
        resource_id: resource_id,
        flow_id: flow_id,
        ref: ref
      )

      refs =
        Map.put(
          socket.assigns.refs,
          ref,
          {channel_pid, socket_ref, resource_id, {opentelemetry_ctx, opentelemetry_span_ctx}}
        )

      socket = assign(socket, :refs, refs)

      {:noreply, socket}
    end
  end

  def handle_info({:reject_access, client_id, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.reject_access",
      attributes: %{
        client_id: client_id,
        resource_id: resource_id
      } do
      push(socket, "reject_access", %{
        client_id: client_id,
        resource_id: resource_id
      })

      {:noreply, socket}
    end
  end

  def handle_info(
        {:request_connection, {channel_pid, socket_ref}, attrs,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.request_connection" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      %{
        client_id: client_id,
        resource_id: resource_id,
        flow_id: flow_id,
        authorization_expires_at: authorization_expires_at,
        client_payload: payload,
        client_preshared_key: preshared_key
      } = attrs

      Logger.debug("Gateway received connection request message",
        client_id: client_id,
        resource_id: resource_id
      )

      client = Clients.fetch_client_by_id!(client_id, preload: [:actor])
      resource = Resources.fetch_resource_by_id!(resource_id)

      {relay_hosting_type, relay_connection_type} =
        Gateways.relay_strategy([socket.assigns.gateway_group])

      {:ok, relays} = Relays.list_connected_relays_for_resource(resource, relay_hosting_type)

      :ok = Resources.subscribe_for_resource_events(resource)

      ref = Ecto.UUID.generate()

      push(socket, "request_connection", %{
        ref: ref,
        flow_id: flow_id,
        actor: Views.Actor.render(client.actor),
        relays: Views.Relay.render_many(relays, authorization_expires_at, relay_connection_type),
        resource: Views.Resource.render(resource),
        client: Views.Client.render(client, payload, preshared_key),
        expires_at: DateTime.to_unix(authorization_expires_at, :second)
      })

      Logger.debug("Awaiting gateway connection_ready message",
        client_id: client_id,
        resource_id: resource_id,
        flow_id: flow_id,
        ref: ref
      )

      refs =
        Map.put(
          socket.assigns.refs,
          ref,
          {channel_pid, socket_ref, resource_id, {opentelemetry_ctx, opentelemetry_span_ctx}}
        )

      socket = assign(socket, :refs, refs)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_in(
        "connection_ready",
        %{
          "ref" => ref,
          "gateway_payload" => payload
        },
        socket
      ) do
    {{channel_pid, socket_ref, resource_id, {opentelemetry_ctx, opentelemetry_span_ctx}}, refs} =
      Map.pop(socket.assigns.refs, ref)

    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.connection_ready" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      socket = assign(socket, :refs, refs)

      send(
        channel_pid,
        {:connect, socket_ref, resource_id, socket.assigns.gateway.public_key, payload,
         {opentelemetry_ctx, opentelemetry_span_ctx}}
      )

      Logger.debug("Gateway replied to the Client with :connect message",
        resource_id: resource_id,
        channel_pid: inspect(channel_pid),
        ref: ref
      )

      {:reply, :ok, socket}
    end
  end

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
          API.Client.Channel.broadcast(
            client_id,
            {:ice_candidates, socket.assigns.gateway.id, candidates,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )
        end)

      {:noreply, socket}
    end
  end

  def handle_in(
        "metrics",
        %{
          "started_at" => started_at,
          "ended_at" => ended_at,
          "metrics" => metrics
        },
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "gateway.metrics" do
      window_started_at = DateTime.from_unix!(started_at, :second)
      window_ended_at = DateTime.from_unix!(ended_at, :second)

      activities =
        Enum.map(metrics, fn metric ->
          %{
            "flow_id" => flow_id,
            "destination" => destination,
            "rx_bytes" => rx_bytes,
            "tx_bytes" => tx_bytes
          } = metric

          %{
            window_started_at: window_started_at,
            window_ended_at: window_ended_at,
            destination: destination,
            rx_bytes: rx_bytes,
            tx_bytes: tx_bytes,
            flow_id: flow_id,
            account_id: socket.assigns.gateway.account_id
          }
        end)

      {:ok, _num} = Flows.upsert_activities(activities)

      {:reply, :ok, socket}
    end
  end
end
