defmodule API.Client.Channel do
  use API, :channel
  alias API.Client.Views
  alias Domain.Instrumentation
  alias Domain.{Clients, Actors, Resources, Gateways, Relays, Policies, Flows}
  require Logger
  require OpenTelemetry.Tracer

  @impl true
  def join("client", _payload, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.join" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      socket =
        assign(socket,
          opentelemetry_ctx: opentelemetry_ctx,
          opentelemetry_span_ctx: opentelemetry_span_ctx
        )

      with {:ok, socket} <- schedule_expiration(socket) do
        send(self(), {:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}})
        {:ok, socket}
      end
    end
  end

  defp schedule_expiration(%{assigns: %{subject: %{expires_at: nil}}} = socket) do
    {:ok, socket}
  end

  defp schedule_expiration(%{assigns: %{subject: %{expires_at: expires_at}}} = socket) do
    expires_in = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)

    if expires_in > 0 do
      Process.send_after(self(), :token_expired, expires_in)
      {:ok, socket}
    else
      {:error, %{"reason" => "token_expired"}}
    end
  end

  @impl true
  def handle_info({:after_join, {opentelemetry_ctx, opentelemetry_span_ctx}}, socket) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.after_join" do
      :ok = Clients.connect_client(socket.assigns.client)

      {:ok, resources} = Resources.list_authorized_resources(socket.assigns.subject)

      # We subscribe for all resource events but only care about update events,
      # where resource might be renamed which should be propagated to the UI.
      :ok = Enum.each(resources, &Resources.subscribe_for_events_for_resource/1)

      # We subscribe for membership updates for all actor groups the client is a member of,
      :ok = Actors.subscribe_for_membership_updates_for_actor(socket.assigns.subject.actor)

      # We subscribe for all policy events for the actor groups the client is a member of,
      {:ok, actor_group_ids} = Actors.list_actor_group_ids(socket.assigns.subject.actor)
      :ok = Enum.each(actor_group_ids, &Policies.subscribe_for_events_for_actor_group/1)

      :ok =
        push(socket, "init", %{
          resources: Views.Resource.render_many(resources),
          interface: Views.Interface.render(socket.assigns.client)
        })

      {:noreply, socket}
    end
  end

  # Message is scheduled by schedule_expiration/1 on topic join to be sent
  # when the client token/subject expires
  def handle_info(:token_expired, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.token_expired" do
      push(socket, "disconnect", %{"reason" => "token_expired"})
      {:stop, {:shutdown, :token_expired}, socket}
    end
  end

  # This message is sent using Clients.broadcast_to_client/1 eg. when the client is deleted
  def handle_info("disconnect", socket) do
    OpenTelemetry.Tracer.with_span "client.disconnect" do
      push(socket, "disconnect", %{"reason" => "token_expired"})
      send(socket.transport_pid, %Phoenix.Socket.Broadcast{event: "disconnect"})
      {:stop, :shutdown, socket}
    end
  end

  # This the list of ICE candidates gathered by the gateway and relayed to the client
  def handle_info(
        {:ice_candidates, gateway_id, candidates, {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.ice_candidates",
      attributes: %{
        gateway_id: gateway_id,
        candidates_length: length(candidates)
      } do
      push(socket, "ice_candidates", %{
        gateway_id: gateway_id,
        candidates: candidates
      })

      {:noreply, socket}
    end
  end

  # This message is sent by the gateway when it is ready to accept the connection from the client
  def handle_info(
        {:connect, socket_ref, resource_id, gateway_public_key, payload,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.connect", attributes: %{resource_id: resource_id} do
      reply(
        socket_ref,
        {:ok,
         %{
           resource_id: resource_id,
           persistent_keepalive: 25,
           gateway_public_key: gateway_public_key,
           gateway_payload: payload
         }}
      )

      {:noreply, socket}
    end
  end

  # Resource is updated, eg. renamed. We don't care about other changes
  # as the access is dictated by the policy events
  def handle_info({:update_resource, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.resource_updated",
      attributes: %{resource_id: resource_id} do
      case Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject) do
        {:ok, resource} ->
          push(socket, "resource_created_or_updated", Views.Resource.render(resource))

        {:error, _reason} ->
          :ok
      end

      {:noreply, socket}
    end
  end

  # This event is ignored because we will receive a reject_access message from
  # the Policies which will trigger a resource_deleted event
  def handle_info({:delete_resource, _resource_id}, socket) do
    {:noreply, socket}
  end

  # Those events are broadcasted by Actors whenever a membership is created or deleted
  def handle_info({:create_membership, _actor_id, group_id}, socket) do
    :ok = Policies.subscribe_for_events_for_actor_group(group_id)
    {:noreply, socket}
  end

  def handle_info({:delete_membership, _actor_id, group_id}, socket) do
    :ok = Policies.unsubscribe_from_events_for_actor_group(group_id)
    {:noreply, socket}
  end

  # This message is received when there is a policy created or enabled
  # allowing access to a resource by a client actor group
  def handle_info({:allow_access, policy_id, actor_group_id, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.allow_access",
      attributes: %{
        policy_id: policy_id,
        actor_group_id: actor_group_id,
        resource_id: resource_id
      } do
      :ok = Resources.subscribe_for_events_for_resource(resource_id)

      case Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject) do
        {:ok, resource} ->
          push(socket, "resource_created_or_updated", Views.Resource.render(resource))

        {:error, _reason} ->
          :ok
      end

      {:noreply, socket}
    end
  end

  # This message is received when the policy
  # allowing access to a resource by a client actor group is deleted
  def handle_info({:reject_access, policy_id, actor_group_id, resource_id}, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.reject_access",
      attributes: %{
        policy_id: policy_id,
        actor_group_id: actor_group_id,
        resource_id: resource_id
      } do
      :ok = Resources.unsubscribe_from_events_for_resource(resource_id)

      # We potentially can re-create the flow but this will require keep tracking of client connections to gateways,
      # which is not worth it as this case should be pretty rare. Instead we just tell client to remove it
      # and the recreate it right away if there is another allowing access to it.
      push(socket, "resource_deleted", resource_id)

      case Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject) do
        {:ok, resource} ->
          push(socket, "resource_created_or_updated", Views.Resource.render(resource))

        {:error, _reason} ->
          :ok
      end

      {:noreply, socket}
    end
  end

  # This message sent by the client to create a GSC signed url for uploading logs and debug artifacts
  @impl true
  def handle_in("create_log_sink", _attrs, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    account_slug = socket.assigns.subject.account.slug

    actor_name =
      socket.assigns.subject.actor.name
      |> String.downcase()
      |> String.replace(" ", "_")
      |> String.replace(~r/[^a-zA-Z0-9_-]/iu, "")

    OpenTelemetry.Tracer.with_span "client.create_log_sink" do
      case Instrumentation.create_remote_log_sink(socket.assigns.client, actor_name, account_slug) do
        {:ok, signed_url} -> {:reply, {:ok, signed_url}, socket}
        {:error, :disabled} -> {:reply, {:error, :disabled}, socket}
      end
    end
  end

  # The client sends it's message to list relays and select a gateway whenever it wants
  # to connect to a resource.
  #
  # Client can send `connected_gateway_ids` to indicate that it is already connected to
  # some of the gateways and can multiplex the connections.
  @impl true
  def handle_in("prepare_connection", %{"resource_id" => resource_id} = attrs, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.prepare_connection", attributes: attrs do
      connected_gateway_ids = Map.get(attrs, "connected_gateway_ids", [])

      with {:ok, resource} <-
             Resources.fetch_and_authorize_resource_by_id(resource_id, socket.assigns.subject),
           {:ok, [_ | _] = gateways} <-
             Gateways.list_connected_gateways_for_resource(resource, preload: :group),
           gateway_groups = Enum.map(gateways, & &1.group),
           {relay_hosting_type, relay_connection_type} = Gateways.relay_strategy(gateway_groups),
           {:ok, [_ | _] = relays} <-
             Relays.list_connected_relays_for_resource(resource, relay_hosting_type) do
        location = {
          socket.assigns.client.last_seen_remote_ip_location_lat,
          socket.assigns.client.last_seen_remote_ip_location_lon
        }

        OpenTelemetry.Tracer.set_attribute(:relays_length, length(relays))
        OpenTelemetry.Tracer.set_attribute(:gateways_length, length(gateways))
        OpenTelemetry.Tracer.set_attribute(:relay_hosting_type, relay_hosting_type)
        OpenTelemetry.Tracer.set_attribute(:relay_connection_type, relay_connection_type)

        relays = Relays.load_balance_relays(location, relays)
        gateway = Gateways.load_balance_gateways(location, gateways, connected_gateway_ids)

        reply =
          {:ok,
           %{
             relays:
               Views.Relay.render_many(
                 relays,
                 socket.assigns.subject.expires_at,
                 relay_connection_type
               ),
             resource_id: resource_id,
             gateway_id: gateway.id,
             gateway_remote_ip: gateway.last_seen_remote_ip
           }}

        {:reply, reply, socket}
      else
        {:ok, []} ->
          OpenTelemetry.Tracer.set_status(:error, "offline")
          {:reply, {:error, :offline}, socket}

        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")
          {:reply, {:error, :not_found}, socket}
      end
    end
  end

  # This message is sent by the client when it already has connection to a gateway,
  # but wants to multiplex the connection to access a new resource
  def handle_in(
        "reuse_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "payload" => payload
        } = attrs,
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.reuse_connection", attributes: attrs do
      with {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
           {:ok, resource, flow} <-
             Flows.authorize_flow(
               socket.assigns.client,
               gateway,
               resource_id,
               socket.assigns.subject
             ),
           true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
        opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
        opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

        :ok =
          Gateways.broadcast_to_gateway(
            gateway,
            {:allow_access, {self(), socket_ref(socket)},
             %{
               client_id: socket.assigns.client.id,
               resource_id: resource.id,
               flow_id: flow.id,
               authorization_expires_at: socket.assigns.subject.expires_at,
               client_payload: payload
             }, {opentelemetry_ctx, opentelemetry_span_ctx}}
          )

        {:noreply, socket}
      else
        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")
          {:reply, {:error, :not_found}, socket}

        false ->
          OpenTelemetry.Tracer.set_status(:error, "offline")
          {:reply, {:error, :offline}, socket}
      end
    end
  end

  # This message is sent by the client when it wants to connect to a new gateway
  # to access a resource
  def handle_in(
        "request_connection",
        %{
          "gateway_id" => gateway_id,
          "resource_id" => resource_id,
          "client_payload" => client_payload,
          "client_preshared_key" => preshared_key
        },
        socket
      ) do
    ctx_attrs = %{gateway_id: gateway_id, resource_id: resource_id}
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.request_connection", attributes: ctx_attrs do
      with {:ok, gateway} <- Gateways.fetch_gateway_by_id(gateway_id, socket.assigns.subject),
           {:ok, resource, flow} <-
             Flows.authorize_flow(
               socket.assigns.client,
               gateway,
               resource_id,
               socket.assigns.subject
             ),
           true <- Gateways.gateway_can_connect_to_resource?(gateway, resource) do
        opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
        opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

        :ok =
          Gateways.broadcast_to_gateway(
            gateway,
            {:request_connection, {self(), socket_ref(socket)},
             %{
               client_id: socket.assigns.client.id,
               resource_id: resource.id,
               flow_id: flow.id,
               authorization_expires_at: socket.assigns.subject.expires_at,
               client_payload: client_payload,
               client_preshared_key: preshared_key
             }, {opentelemetry_ctx, opentelemetry_span_ctx}}
          )

        {:noreply, socket}
      else
        {:error, :not_found} ->
          OpenTelemetry.Tracer.set_status(:error, "not_found")
          {:reply, {:error, :not_found}, socket}

        false ->
          OpenTelemetry.Tracer.set_status(:error, "offline")
          {:reply, {:error, :offline}, socket}
      end
    end
  end

  # The client pushes it's ICE candidates list and the list of gateways that need to receive it
  def handle_in(
        "broadcast_ice_candidates",
        %{"candidates" => candidates, "gateway_ids" => gateway_ids},
        socket
      ) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "client.broadcast_ice_candidates" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      :ok =
        Enum.each(gateway_ids, fn gateway_id ->
          Gateways.broadcast_to_gateway(
            gateway_id,
            {:ice_candidates, socket.assigns.client.id, candidates,
             {opentelemetry_ctx, opentelemetry_span_ctx}}
          )
        end)

      {:noreply, socket}
    end
  end
end
