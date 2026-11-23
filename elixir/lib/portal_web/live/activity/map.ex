defmodule PortalWeb.Activity.Map do
  use PortalWeb, :live_view

  alias PortalWeb.Activity.Land
  alias PortalWeb.Logs
  alias __MODULE__.Database

  @poll_interval 2_500
  @per_tick 50
  @list_limit 25

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Live map",
        browser_tz: Logs.Components.browser_tz_from_connect(socket),
        cursor: DateTime.utc_now(),
        seen: 0,
        empty?: true
      )
      |> stream_configure(:connections, dom_id: &"connection-#{&1.id}")
      |> stream(:connections, [])

    if connected?(socket) do
      connections = Database.list_connections(socket.assigns.subject, nil, @list_limit)
      schedule_poll()

      {:ok,
       socket
       |> add_connections(connections, false)
       |> assign(cursor: newest(connections, socket.assigns.cursor))}
    else
      {:ok, socket}
    end
  end

  def handle_info(:poll, socket) do
    connections = Database.list_connections(socket.assigns.subject, socket.assigns.cursor, @per_tick)
    schedule_poll()

    {:noreply,
     socket
     |> add_connections(connections, true)
     |> assign(cursor: newest(connections, socket.assigns.cursor))}
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  def render(assigns) do
    assigns = assign(assigns, land_path: Land.path(), width: Land.width(), height: Land.height())

    ~H"""
    <Page.page_header>
      <:title>Live map</:title>
      <:description>New connections as they are authorized, from the device to the gateway.</:description>
      <:stats>{@seen} since you opened this page</:stats>
    </Page.page_header>

    <div class="px-6 pb-8 grid gap-8 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <section class="min-w-0">
        <div
          id="activity-map"
          phx-hook="ActivityMap"
          phx-update="ignore"
          class="relative border-t border-rule pt-4"
        >
          <svg
            viewBox={"0 0 #{@width} #{@height}"}
            class="block w-full h-auto"
            role="img"
            aria-label="World map of new connections"
          >
            <path
              d={@land_path}
              fill="none"
              stroke="currentColor"
              stroke-width="0.42"
              stroke-linecap="round"
              stroke-dasharray="0 1"
              class="text-faint"
            />
            <g data-endpoints class="text-fg"></g>
            <g data-arcs class="text-fg"></g>
          </svg>
        </div>
        <p class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-muted">
          <span class="inline-flex items-center gap-1.5">
            <span class="inline-block w-1.5 h-1.5 rounded-full bg-fg"></span> Device or gateway seen
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="inline-block w-2.5 h-2.5 rounded-full border border-attn"></span>
            New connection
          </span>
          <span>Places come from each device's last known IP address.</span>
        </p>
      </section>

      <section class="min-w-0">
        <p class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted pb-2 border-b border-rule">
          Latest connections
        </p>
        <ul id="activity-map-connections" phx-update="stream" class="divide-y divide-hair">
          <li
            :for={{dom_id, connection} <- @streams.connections}
            id={dom_id}
            class="py-2.5 flex items-start justify-between gap-3"
          >
            <div class="min-w-0">
              <p class="text-sm text-fg truncate">
                {connection.who} <span class="text-muted">→</span> {connection.resource}
              </p>
              <p class="text-xs text-muted truncate">
                {connection.client_place} <span aria-hidden="true">→</span> {connection.gateway_place}
              </p>
            </div>
            <time class="shrink-0 font-mono text-xs text-muted tabular-nums">
              {clock(connection.inserted_at, @browser_tz)}
            </time>
          </li>
        </ul>
        <div
          :if={@empty?}
          id="activity-map-empty"
          class="py-10 flex flex-col items-center gap-2 text-center"
        >
          <Core.icon name="ri-earth-line" class="w-5 h-5 text-faint" />
          <p class="text-sm text-muted">Waiting for new connections.</p>
        </div>
      </section>
    </div>
    """
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)

  defp add_connections(socket, [], _animate?), do: socket

  defp add_connections(socket, connections, animate?) do
    socket =
      Enum.reduce(connections, socket, fn connection, socket ->
        stream_insert(socket, :connections, connection, at: 0, limit: @list_limit)
      end)

    socket
    |> assign(empty?: false, seen: socket.assigns.seen + new_count(connections, animate?))
    |> push_event("activity-map:connections", %{
      animate: animate?,
      connections: Enum.map(connections, &Map.take(&1, [:id, :from, :to]))
    })
  end

  defp new_count(connections, true), do: length(connections)
  defp new_count(_connections, false), do: 0

  defp newest([], cursor), do: cursor
  defp newest(connections, _cursor), do: connections |> List.last() |> Map.fetch!(:inserted_at)

  defp clock(at, tz) do
    case DateTime.shift_zone(at, tz, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M:%S")
      {:error, _reason} -> Calendar.strftime(at, "%H:%M:%S")
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{Actor, Device, Membership, PolicyAuthorization, Resource, Safe}

    # policy_authorizations has no (account_id, inserted_at) index, so every
    # read is bounded to a short recent window on top of the cursor.
    @window_seconds 300

    @doc """
    The newest authorizations created after `since` (or in the last few
    minutes), oldest first, with the places of both devices.
    """
    def list_connections(subject, since, limit) do
      now = DateTime.utc_now()
      floor = DateTime.add(now, -@window_seconds, :second)
      since = latest(since, floor)

      from(pa in PolicyAuthorization,
        as: :policy_authorizations,
        where: pa.inserted_at > ^since and pa.expires_at > ^now,
        order_by: [desc: pa.inserted_at],
        limit: ^limit,
        select:
          map(pa, [
            :id,
            :initiating_device_id,
            :receiving_device_id,
            :resource_id,
            :membership_id,
            :inserted_at
          ])
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        authorizations when is_list(authorizations) ->
          authorizations |> Enum.reverse() |> enrich(subject)

        {:error, :unauthorized} ->
          []
      end
    end

    defp latest(nil, floor), do: floor

    defp latest(since, floor) do
      if DateTime.after?(since, floor) do
        since
      else
        floor
      end
    end

    defp enrich([], _subject), do: []

    defp enrich(authorizations, subject) do
      devices =
        authorizations
        |> Enum.flat_map(&[&1.initiating_device_id, &1.receiving_device_id])
        |> by_id(Device, subject)

      resources = authorizations |> Enum.map(& &1.resource_id) |> by_id(Resource, subject)
      memberships = authorizations |> Enum.map(& &1.membership_id) |> by_id(Membership, subject)
      actors = memberships |> Map.values() |> Enum.map(& &1.actor_id) |> by_id(Actor, subject)

      Enum.map(authorizations, fn authorization ->
        client = Map.get(devices, authorization.initiating_device_id)
        gateway = Map.get(devices, authorization.receiving_device_id)
        resource = Map.get(resources, authorization.resource_id)
        membership = Map.get(memberships, authorization.membership_id)
        actor = membership && Map.get(actors, membership.actor_id)

        %{
          id: authorization.id,
          inserted_at: authorization.inserted_at,
          who: who(actor, client),
          resource: (resource && resource.name) || "Deleted resource",
          client_place: place(client),
          gateway_place: place(gateway),
          from: location(client),
          to: location(gateway)
        }
      end)
    end

    defp by_id(ids, schema, subject) do
      case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
        [] ->
          %{}

        ids ->
          from(record in schema, where: record.id in ^ids)
          |> Safe.scoped(subject)
          |> Safe.all()
          |> case do
            records when is_list(records) -> Map.new(records, &{&1.id, &1})
            {:error, :unauthorized} -> %{}
          end
      end
    end

    defp who(%Actor{name: name}, _client) when name not in [nil, ""], do: name
    defp who(%Actor{email: email}, _client) when email not in [nil, ""], do: email
    defp who(_actor, %Device{name: name}) when name not in [nil, ""], do: name
    defp who(_actor, _client), do: "Unknown device"

    defp location(%Device{} = device),
      do: Land.project(device.last_seen_remote_ip_location_lat, device.last_seen_remote_ip_location_lon)

    defp location(_device), do: nil

    defp place(%Device{} = device) do
      region = device.last_seen_remote_ip_location_region
      region = region && (Portal.Geo.country_common_name!(region) || region)

      case Enum.reject([device.last_seen_remote_ip_location_city, region], &(&1 in [nil, ""])) do
        [] -> "Unknown place"
        parts -> Enum.join(parts, ", ")
      end
    end

    defp place(_device), do: "Unknown place"
  end
end
