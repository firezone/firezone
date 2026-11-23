defmodule PortalWeb.Access.Graph do
  use PortalWeb, :live_view

  alias PortalWeb.Access.Components
  alias __MODULE__.{Database, Layout}

  def mount(_params, _session, socket) do
    data =
      if connected?(socket) do
        Database.load(socket.assigns.subject)
      end

    socket =
      socket
      |> assign(page_title: "Access", data: data, search: "", pinned: nil)
      |> build_graph()

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <Page.page_header>
        <:title>Access</:title>
        <:description>
          Who can reach what, through which site, carried by which device. Hover a box to trace its path, click it to pin it.
        </:description>
        <:action>
          <Form.button
            style="primary"
            icon="ri-add-line"
            navigate={~p"/#{@account}/policies/new"}
          >
            Add a policy
          </Form.button>
        </:action>
      </Page.page_header>

      <div class="flex-1 min-h-0 flex flex-col px-6 pb-6">
        <div class="flex flex-wrap items-center gap-3 mb-4">
          <Components.search_box
            id="access-graph-search"
            value={@search}
            placeholder="Search groups, resources, sites, devices"
          />
          <p :if={@graph && @graph.notes != []} id="access-graph-cap" class="text-xs text-muted">
            <Core.icon name="ri-information-line" class="w-3.5 h-3.5 align-text-bottom" />
            {Enum.join(@graph.notes, " ")} Search to narrow the map.
          </p>
        </div>

        <.pin_strip :if={@graph} account={@account} graph={@graph} pinned={@pinned} />

        <div :if={is_nil(@graph)} id="access-graph-loading" class="py-16 text-center text-sm text-muted">
          <Core.icon name="ri-loader-4-line" class="w-4 h-4 animate-spin align-text-bottom" /> Loading the map
        </div>

        <div
          :if={@graph && @graph.nodes == []}
          id="access-graph-empty"
          class="flex flex-col items-center gap-3 py-16 text-center"
        >
          <Core.icon name="ri-git-merge-line" class="w-6 h-6 text-faint" />
          <p :if={@search == ""} class="text-sm text-muted">
            Nothing to show yet. Add a resource, then a policy that lets a group reach it.
          </p>
          <p :if={@search != ""} class="text-sm text-muted">Nothing matches "{@search}".</p>
        </div>

        <div :if={@graph && @graph.nodes != []} class="flex-1 min-h-[420px] flex flex-col">
          <div
            id="access-graph-viewport"
            tabindex="0"
            aria-label="Access map. Drag or scroll to move, hold Ctrl or Command and scroll to zoom, plus and minus keys zoom, 0 fits."
            class="relative flex-1 min-h-[420px] border border-hair overflow-hidden outline-none focus-visible:border-rule"
          >
            <div
              id="access-graph-controls"
              class="absolute top-3 right-3 z-10 flex items-stretch border border-rule bg-bg text-sm"
            >
              <button
                type="button"
                data-graph-zoom="in"
                title="Zoom in (+)"
                aria-label="Zoom in"
                class="w-8 h-8 flex items-center justify-center text-fg hover:bg-hover"
              >
                <Core.icon name="ri-zoom-in-line" class="w-4 h-4" />
              </button>
              <button
                type="button"
                data-graph-zoom="out"
                title="Zoom out (-)"
                aria-label="Zoom out"
                class="w-8 h-8 flex items-center justify-center text-fg hover:bg-hover border-l border-hair"
              >
                <Core.icon name="ri-zoom-out-line" class="w-4 h-4" />
              </button>
              <span
                data-graph-scale
                class="min-w-14 px-2 flex items-center justify-center border-l border-hair text-xs text-muted tabular-nums"
              >
                100%
              </span>
              <button
                type="button"
                data-graph-zoom="fit"
                title="Fit the whole map (0)"
                aria-label="Fit the whole map"
                class="w-8 h-8 flex items-center justify-center text-fg hover:bg-hover border-l border-hair"
              >
                <Core.icon name="ri-fullscreen-exit-line" class="w-4 h-4" />
              </button>
              <button
                type="button"
                data-graph-zoom="reset"
                title="Actual size, back to the top (1)"
                aria-label="Actual size"
                class="w-8 h-8 flex items-center justify-center text-fg hover:bg-hover border-l border-hair"
              >
                <Core.icon name="ri-focus-3-line" class="w-4 h-4" />
              </button>
            </div>
          <svg
            id="access-graph"
            phx-hook="AccessGraph"
            data-pinned={@pinned}
            data-width={@graph.width}
            data-height={@graph.height}
            viewBox={"0 0 #{@graph.width} #{@graph.height}"}
            preserveAspectRatio="xMinYMin meet"
            class="absolute inset-0 block w-full h-full select-none touch-none cursor-grab active:cursor-grabbing"
            role="img"
            aria-label="Access map"
          >
            <text
              :for={{title, x} <- @graph.headings}
              x={x}
              y="12"
              class="fill-muted text-[10.5px] font-semibold tracking-[.12em]"
            >
              {title}
            </text>
            <path
              :for={edge <- @graph.edges}
              data-from={edge.from}
              data-to={edge.to}
              d={edge.d}
              fill="none"
              stroke-width="1"
              stroke-dasharray={edge.dashed && "4 3"}
              class="stroke-faint"
            />
            <g
              :for={node <- @graph.nodes}
              data-node={node.id}
              phx-click="pin"
              phx-value-node={node.id}
              class="cursor-pointer"
            >
              <title>{node.title}</title>
              <rect
                x={node.x + 0.5}
                y={node.y + 0.5}
                width={node.w}
                height={Layout.node_height()}
                stroke-width="1"
                stroke-dasharray={node.dashed && "4 3"}
                class="fill-bg stroke-rule"
              />
              <circle
                :if={node.kind == :device}
                cx={node.x + 14}
                cy={node.y + 17}
                r="3.5"
                stroke-width="1.5"
                class={if node.online, do: "fill-fg stroke-fg", else: "fill-none stroke-attn"}
              />
              <text
                x={node.x + if(node.kind == :device, do: 26, else: 12)}
                y={node.y + if(node.sub && node.kind != :device, do: 15, else: 21)}
                class="fill-fg text-[12.5px]"
              >
                {node.label}
              </text>
              <text
                :if={node.sub && node.kind == :device}
                x={node.x + node.w - 10}
                y={node.y + 21}
                text-anchor="end"
                class="fill-muted text-[10.5px]"
              >
                {node.sub}
              </text>
              <text
                :if={node.sub && node.kind != :device}
                x={node.x + 12}
                y={node.y + 28}
                class="fill-muted text-[10.5px]"
              >
                {node.sub}
              </text>
            </g>
          </svg>
          </div>
          <p class="mt-3 text-xs text-muted flex flex-wrap items-center gap-x-4 gap-y-1">
            <span class="inline-flex items-center gap-1.5">
              <span class="inline-block w-2 h-2 rounded-full bg-fg"></span> Online
            </span>
            <span class="inline-flex items-center gap-1.5">
              <span class="inline-block w-2 h-2 rounded-full border border-attn"></span> Offline
            </span>
            <span class="inline-flex items-center gap-1.5">
              <span class="inline-block w-5 border-t border-dashed border-muted"></span>
              Direct to devices, no site
            </span>
            <span class="inline-flex items-center gap-1.5 sm:ml-auto">
              <Core.icon name="ri-drag-move-2-line" class="w-3.5 h-3.5" />
              Drag or scroll to move. Ctrl or Cmd + scroll, or + and -, to zoom. Arrows move, Shift moves faster, 0 fits.
            </span>
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :graph, :map, required: true
  attr :pinned, :string, default: nil

  defp pin_strip(assigns) do
    assigns = assign(assigns, :strip, strip(assigns.graph, assigns.pinned))

    ~H"""
    <div
      id="access-graph-strip"
      class="flex flex-wrap items-center gap-x-5 gap-y-2 mb-4 px-4 py-3 border border-rule text-sm"
    >
      <span :if={is_nil(@strip)} class="text-muted">
        <Core.icon name="ri-pushpin-line" class="w-4 h-4 align-text-bottom" />
        Nothing is pinned. Click a box to pin its path and open it.
      </span>
      <%= if @strip do %>
        <span class="inline-flex items-center gap-2">
          <span class="text-[10px] tracking-[.1em] uppercase text-muted">{kind_label(@strip.node.kind)}</span>
          <b class="font-semibold">{@strip.node.title}</b>
        </span>
        <span :if={@strip.node.kind not in [:group, :people]} class="inline-flex flex-wrap items-center gap-1.5">
          <span class="text-[10px] tracking-[.1em] uppercase text-muted">Groups</span>
          <Components.chip :for={node <- @strip.groups} navigate={node.href} icon={kind_icon(node.kind)}>
            {node.title}
          </Components.chip>
          <span :if={@strip.groups == []} class="text-muted">none</span>
        </span>
        <span :if={@strip.node.kind != :resource} class="inline-flex flex-wrap items-center gap-1.5">
          <span class="text-[10px] tracking-[.1em] uppercase text-muted">Resources</span>
          <Components.chip :for={node <- @strip.resources} navigate={node.href} icon={kind_icon(node.kind)}>
            {node.title}
          </Components.chip>
          <span :if={@strip.resources == []} class="text-muted">none</span>
        </span>
        <span class="ml-auto flex items-center gap-3">
          <button type="button" phx-click="unpin" class="text-sm text-muted hover:text-fg">
            Clear
          </button>
          <Form.button
            :if={@strip.node.href}
            id="access-graph-open"
            style="primary"
            size="sm"
            icon="ri-arrow-right-up-line"
            navigate={@strip.node.href}
          >
            Open
          </Form.button>
        </span>
      <% end %>
    </div>
    """
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(search: String.trim(search)) |> build_graph()}
  end

  def handle_event("pin", %{"node" => id}, socket) do
    pinned = if socket.assigns.pinned == id, do: nil, else: id
    {:noreply, assign(socket, pinned: pinned)}
  end

  def handle_event("unpin", _params, socket) do
    {:noreply, assign(socket, pinned: nil)}
  end

  defp build_graph(%{assigns: %{data: nil}} = socket), do: assign(socket, graph: nil)

  defp build_graph(socket) do
    graph = Layout.build(socket.assigns.data, socket.assigns.account, socket.assigns.search)
    pinned = socket.assigns.pinned

    if pinned && not Enum.any?(graph.nodes, &(&1.id == pinned)) do
      assign(socket, graph: graph, pinned: nil)
    else
      assign(socket, graph: graph)
    end
  end

  defp strip(_graph, nil), do: nil

  defp strip(graph, pinned) do
    case Enum.find(graph.nodes, &(&1.id == pinned)) do
      nil ->
        nil

      node ->
        reach = Layout.reach(graph.edges, pinned)
        related = Enum.filter(graph.nodes, &(&1.id != pinned and MapSet.member?(reach, &1.id)))

        %{
          node: node,
          groups: Enum.filter(related, &(&1.kind in [:group, :people])),
          resources: Enum.filter(related, &(&1.kind == :resource))
        }
    end
  end

  defp kind_label(:group), do: "Group"
  defp kind_label(:people), do: "People"
  defp kind_label(:resource), do: "Resource"
  defp kind_label(:site), do: "Site"
  defp kind_label(:device), do: "Device"
  defp kind_label(:devices), do: "Devices"

  defp kind_icon(:group), do: "ri-group-line"
  defp kind_icon(:people), do: "ri-user-line"
  defp kind_icon(:resource), do: "ri-server-line"
  defp kind_icon(_kind), do: nil

  defmodule Layout do
    @moduledoc false
    use PortalWeb, :verified_routes

    @node_height 34
    @row 48
    @top 26
    @gap 34
    @cap 2_500
    @columns [:g, :r, :s, :d]
    @titles %{g: "WHO", r: "CAN REACH", s: "THROUGH SITE", d: "CARRIED BY DEVICE"}
    @w %{g: 170, r: 210, s: 170, d: 220}
    @chars %{g: 22, r: 28, s: 22, d: 22}
    # Space for the curves between two columns, and between wrapped sub-columns.
    @column_gap 80
    @wrap_gap 24
    # A long column wraps into sub-columns until the map is about this much wider than tall.
    @aspect 1.4
    @min_rows 12

    def node_height, do: @node_height

    @doc "Every node reachable downstream of `ids` (one id or a list), plus every node that reaches them."
    def reach(edges, ids) do
      ids = List.wrap(ids)
      down = edges |> Enum.group_by(& &1.from, & &1.to) |> walk(ids)
      up = edges |> Enum.group_by(& &1.to, & &1.from) |> walk(ids)
      MapSet.union(down, up)
    end

    def build(data, account, search) do
      {nodes, edges} = graph(data, account)
      {nodes, edges} = filter(nodes, edges, search)
      {nodes, notes} = cap(nodes)
      ids = MapSet.new(nodes, & &1.id)
      edges = Enum.filter(edges, &(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to)))
      {nodes, height, width, headings} = place(nodes)
      by_id = Map.new(nodes, &{&1.id, &1})

      %{
        nodes: nodes,
        edges: Enum.map(edges, &Map.put(&1, :d, curve(by_id[&1.from], by_id[&1.to]))),
        height: height,
        width: width,
        headings: headings,
        notes: notes
      }
    end

    defp graph(data, account) do
      groups =
        data.policies
        |> Enum.uniq_by(& &1.group_id)
        |> Enum.map(fn policy ->
          if policy.direct? do
            count = Map.get(data.people_counts, policy.group_id, 0)

            make_node(
              "people:#{policy.group_id}",
              :people,
              :g,
              PortalWeb.Access.Components.people_count(count),
              href(account, :resources, policy.resource_id)
            )
          else
            make_node("group:#{policy.group_id}", :group, :g, policy.group_name, href(account, :groups, policy.group_id))
          end
        end)
        |> Enum.sort_by(&{&1.kind == :people, String.downcase(&1.title)})

      {pools, routed} = Enum.split_with(data.resources, &(&1.type == :device_pool))

      routed = Enum.sort_by(routed, &{&1.site_id || "", String.downcase(&1.name)})

      resources =
        Enum.map(routed, &make_node("resource:#{&1.id}", :resource, :r, &1.name, href(account, :resources, &1.id), resource_sub(&1))) ++
          Enum.map(
            pools,
            &(make_node("resource:#{&1.id}", :resource, :r, &1.name, href(account, :resources, &1.id), "Device pool")
              |> Map.merge(%{dashed: true, section: 2}))
          )

      used_sites = routed |> Enum.map(& &1.site_id) |> MapSet.new()
      devices_by_site = Enum.group_by(data.site_devices, & &1.site_id)

      sites =
        data.sites
        |> Enum.filter(&MapSet.member?(used_sites, &1.id))
        |> Enum.map(fn site ->
          count = length(Map.get(devices_by_site, site.id, []))
          make_node("site:#{site.id}", :site, :s, site.name, href(account, :sites, site.id), device_count(count))
        end)

      site_device_nodes =
        data.site_devices
        |> Enum.filter(&MapSet.member?(used_sites, &1.site_id))
        |> Enum.uniq_by(& &1.device_id)
        |> Enum.map(&device_node(&1, account, data.online_ids))

      {pool_device_nodes, pool_edges} = pool_devices(pools, data, account)

      site_device_ids = MapSet.new(site_device_nodes, & &1.id)
      pool_device_nodes = Enum.reject(pool_device_nodes, &MapSet.member?(site_device_ids, &1.id))

      edges =
        Enum.map(data.policies, fn policy ->
          from = if policy.direct?, do: "people:#{policy.group_id}", else: "group:#{policy.group_id}"
          edge(from, "resource:#{policy.resource_id}")
        end) ++
          for(resource <- routed, resource.site_id, do: edge("resource:#{resource.id}", "site:#{resource.site_id}")) ++
          for(sd <- data.site_devices, do: edge("site:#{sd.site_id}", "device:#{sd.device_id}")) ++
          pool_edges

      {groups ++ resources ++ sites ++ site_device_nodes ++ pool_device_nodes, Enum.uniq(edges)}
    end

    defp pool_devices(pools, data, account) do
      devices_by_id = Map.new(data.pool_devices, &{&1.device_id, &1})

      {nodes, edges} =
        pools
        |> Enum.map(&pool_targets(&1, devices_by_id, data.online_ids, account))
        |> Enum.unzip()

      {nodes |> List.flatten() |> Enum.uniq_by(& &1.id), List.flatten(edges)}
    end

    defp pool_targets(pool, devices_by_id, online_ids, account) do
      from = "resource:#{pool.id}"

      case Portal.Resource.DeviceMembershipCriteria.device_ids(pool.device_membership_criteria) do
        {:ok, ids} ->
          listed =
            for id <- ids, device = devices_by_id[id] do
              device |> device_node(account, online_ids) |> Map.put(:section, 2)
            end

          {listed, Enum.map(listed, &edge(from, &1.id, true))}

        :error ->
          id = "devices:#{pool.id}"

          summary =
            id
            |> make_node(:devices, :d, pool_label(pool.device_membership_criteria), nil)
            |> Map.merge(%{dashed: true, section: 2})

          {[summary], [edge(from, id, true)]}
      end
    end

    defp pool_label(nil), do: "No devices"

    defp pool_label(criteria) do
      case Portal.Resource.DeviceMembershipCriteria.kind(criteria) do
        :own_devices -> "Each person's own devices"
        :all_devices -> "All devices"
        :actor_group -> "Devices of a group"
        _kind -> "Devices"
      end
    end

    defp device_node(row, account, online_ids) do
      "device:#{row.device_id}"
      |> make_node(:device, :d, row.name, href(account, :devices, row.device_id))
      |> Map.put(:online, MapSet.member?(online_ids, row.device_id))
    end

    defp resource_sub(%{type: :internet}), do: "Internet"
    defp resource_sub(resource), do: resource.address

    defp device_count(1), do: "1 device"
    defp device_count(count), do: "#{count} devices"

    defp make_node(id, kind, col, title, href, sub \\ nil) do
      %{
        id: id,
        kind: kind,
        col: col,
        title: title || "",
        label: truncate(title || "", @chars[col]),
        sub: sub && truncate(sub, @chars[col] + 4),
        href: href,
        dashed: false,
        online: false,
        section: 1
      }
    end

    defp edge(from, to, dashed \\ false), do: %{from: from, to: to, dashed: dashed}

    defp href(account, :groups, id), do: ~p"/#{account}/groups/#{id}"
    defp href(account, :resources, id), do: ~p"/#{account}/resources/#{id}"
    defp href(account, :sites, id), do: ~p"/#{account}/sites/#{id}"
    defp href(account, :devices, id), do: ~p"/#{account}/devices/#{id}"

    defp truncate(text, max) do
      if String.length(text) > max do
        String.slice(text, 0, max - 1) <> "…"
      else
        text
      end
    end

    defp filter(nodes, edges, ""), do: {nodes, edges}

    defp filter(nodes, edges, search) do
      needle = String.downcase(search)

      keep =
        nodes
        |> Enum.filter(&matches?(&1, needle))
        |> Enum.map(& &1.id)
        |> then(&reach(edges, &1))

      {Enum.filter(nodes, &MapSet.member?(keep, &1.id)),
       Enum.filter(edges, &(MapSet.member?(keep, &1.from) and MapSet.member?(keep, &1.to)))}
    end

    defp matches?(node, needle) do
      String.contains?(String.downcase(node.title), needle) or
        (is_binary(node.sub) and String.contains?(String.downcase(node.sub), needle))
    end

    defp cap(nodes) do
      nodes
      |> Enum.group_by(& &1.col)
      |> Enum.reduce({nodes, []}, fn {col, col_nodes}, {kept, notes} ->
        if length(col_nodes) > @cap do
          dropped = col_nodes |> Enum.drop(@cap) |> MapSet.new(& &1.id)

          {Enum.reject(kept, &MapSet.member?(dropped, &1.id)),
           notes ++ ["Showing #{@cap} of #{length(col_nodes)} #{col_name(col)}."]}
        else
          {kept, notes}
        end
      end)
    end

    defp col_name(:g), do: "groups"
    defp col_name(:r), do: "resources"
    defp col_name(:s), do: "sites"
    defp col_name(:d), do: "devices"

    # Pools and the devices they reach sit below the rest, since they skip the site column.
    # Columns too tall for the map's shape wrap into sub-columns; both sections share
    # the same columns so the headings line up.
    defp place(nodes) do
      first = Enum.filter(nodes, &(&1.section == 1))
      second = Enum.filter(nodes, &(&1.section == 2))
      counts = [count_by_col(first), count_by_col(second)]
      rows = rows_per_column(counts)
      {xs, width} = column_positions(counts, rows)

      {first, bottom} = place_section(first, @top, rows, xs)
      second_top = if first == [], do: @top, else: bottom + @gap
      {second, bottom} = place_section(second, second_top, rows, xs)

      headings = Enum.map(@columns, &{@titles[&1], xs[&1]})
      {first ++ second, max(bottom, @top) + 10, width, headings}
    end

    defp count_by_col(nodes) do
      nodes |> Enum.frequencies_by(& &1.col)
    end

    defp rows_per_column(counts) do
      tallest = counts |> Enum.flat_map(&Map.values/1) |> Enum.max(fn -> 1 end)

      if tallest <= @min_rows do
        tallest
      else
        Enum.find(tallest..@min_rows//-1, @min_rows, fn rows ->
          {_xs, width} = column_positions(counts, rows)
          height = Enum.sum(Enum.map(counts, &section_rows(&1, rows))) * @row
          width >= height * @aspect
        end)
      end
    end

    defp section_rows(counts, rows) do
      counts |> Map.values() |> Enum.map(&min(&1, rows)) |> Enum.max(fn -> 0 end)
    end

    defp wraps(counts, col, rows) do
      counts |> Enum.map(&ceil_div(Map.get(&1, col, 0), rows)) |> Enum.max() |> max(1)
    end

    defp column_positions(counts, rows) do
      {xs, right} =
        Enum.reduce(@columns, {%{}, 0}, fn col, {xs, x} ->
          span = wraps(counts, col, rows) * (@w[col] + @wrap_gap) - @wrap_gap
          {Map.put(xs, col, x), x + span + @column_gap}
        end)

      {xs, right - @column_gap}
    end

    defp ceil_div(0, _rows), do: 0
    defp ceil_div(count, rows), do: div(count + rows - 1, rows)

    defp place_section([], top, _rows, _xs), do: {[], top}

    defp place_section(nodes, top, rows, xs) do
      by_col = Enum.group_by(nodes, & &1.col)
      tallest = by_col |> Map.values() |> Enum.map(&min(length(&1), rows)) |> Enum.max()
      span = (tallest - 1) * @row

      placed =
        Enum.flat_map(by_col, fn {col, col_nodes} ->
          count = length(col_nodes)
          offset = if count < rows, do: div(span - (count - 1) * @row, 2), else: 0

          col_nodes
          |> Enum.with_index()
          |> Enum.map(fn {node, index} ->
            wrap = div(index, rows)
            x = xs[col] + wrap * (@w[col] + @wrap_gap)
            Map.merge(node, %{x: x, w: @w[col], y: top + offset + rem(index, rows) * @row})
          end)
        end)

      {Enum.sort_by(placed, &{&1.section, &1.x, &1.y}), top + span + @node_height}
    end

    defp curve(a, b) do
      x1 = a.x + a.w
      x2 = b.x
      y1 = a.y + div(@node_height, 2)
      y2 = b.y + div(@node_height, 2)
      m = div(x1 + x2, 2)
      "M#{x1},#{y1} C#{m},#{y1} #{m},#{y2} #{x2},#{y2}"
    end

    defp walk(adjacency, starts), do: do_walk(adjacency, starts, MapSet.new(starts))

    defp do_walk(_adjacency, [], seen), do: seen

    defp do_walk(adjacency, [id | rest], seen) do
      next = adjacency |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1))
      do_walk(adjacency, next ++ rest, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, Policy, Group, Resource, Site, SiteDevice, Device, Membership}

    def load(subject) do
      resources = list_resources(subject)

      pool_device_ids =
        Enum.flat_map(resources, fn resource ->
          case Portal.Resource.DeviceMembershipCriteria.device_ids(resource.device_membership_criteria) do
            {:ok, ids} -> ids
            :error -> []
          end
        end)

      %{
        policies: list_policies(subject),
        resources: resources,
        sites: list_sites(subject),
        site_devices: list_site_devices(subject),
        pool_devices: list_devices(pool_device_ids, subject),
        people_counts: people_counts(subject),
        online_ids: MapSet.new(Portal.Presence.Devices.online_ids(subject.account.id))
      }
    end

    defp list_policies(subject) do
      from(p in Policy,
        join: g in Group,
        on: g.id == p.group_id and g.account_id == p.account_id,
        where: p.is_disabled == false,
        order_by: [asc: g.name],
        select: %{
          group_id: g.id,
          group_name: g.name,
          direct?: not is_nil(g.resource_id),
          resource_id: p.resource_id
        }
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    defp list_resources(subject) do
      from(r in Resource,
        order_by: [asc: r.name],
        select: map(r, [:id, :name, :address, :type, :site_id, :device_membership_criteria])
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    defp list_sites(subject) do
      from(s in Site, order_by: [asc: s.name], select: map(s, [:id, :name]))
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    defp list_site_devices(subject) do
      from(sd in SiteDevice,
        join: d in Device,
        on: d.id == sd.device_id and d.account_id == sd.account_id,
        order_by: [asc: d.name],
        select: %{site_id: sd.site_id, device_id: d.id, name: d.name}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    defp list_devices([], _subject), do: []

    defp list_devices(ids, subject) do
      from(d in Device,
        where: d.id in ^Enum.uniq(ids),
        order_by: [asc: d.name],
        select: %{device_id: d.id, name: d.name}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    defp people_counts(subject) do
      from(m in Membership,
        join: g in Group,
        on: g.id == m.group_id and g.account_id == m.account_id,
        where: not is_nil(g.resource_id),
        group_by: m.group_id,
        select: {m.group_id, count(m.actor_id)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
      |> Map.new()
    end

    defp ok_list({:error, _reason}), do: []
    defp ok_list(rows), do: rows
  end
end
