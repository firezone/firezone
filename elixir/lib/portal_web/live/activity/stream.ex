defmodule PortalWeb.Activity.Stream do
  use PortalWeb, :live_view

  alias PortalWeb.Logs
  alias Phoenix.LiveView.AsyncResult
  alias __MODULE__.Database

  @types [
    {"change", :change, "Changes"},
    {"session", :session, "Sessions"},
    {"flow", :flow, "Flows"},
    {"api", :api, "API requests"}
  ]
  @all_types Enum.map(@types, &elem(&1, 1))

  @ranges [
    {"1h", "Last hour", 3_600},
    {"24h", "Last 24 hours", 86_400},
    {"7d", "Last 7 days", 604_800},
    {"30d", "Last 30 days", 2_592_000}
  ]
  @default_range "24h"

  @kinds %{
    "actor" => :actor,
    "device" => :device,
    "resource" => :resource,
    "group" => :group,
    "site" => :site,
    "policy" => :policy
  }
  @max_pivots 5
  @page_size 50

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Activity",
       browser_tz: Logs.Components.browser_tz_from_connect(socket),
       filter: nil,
       events: [],
       has_more?: false,
       pivots: [],
       selected: nil,
       related: AsyncResult.loading(),
       related_key: nil
     )}
  end

  def handle_params(params, _uri, socket) do
    filter = parse_filter(params)

    socket =
      if filter == socket.assigns.filter do
        socket
      else
        load(socket, filter)
      end

    {:noreply, select_event(socket, params["event"])}
  end

  def handle_event("filter", params, socket) do
    filter = %{
      socket.assigns.filter
      | q: parse_q(params["q"]),
        types: parse_types(params["types"]),
        range: parse_range(params["range"])
    }

    {:noreply, push_patch(socket, to: stream_path(socket, filter))}
  end

  def handle_event("add_pivot", %{"kind" => kind, "id" => id}, socket) do
    filter = socket.assigns.filter
    pivots = parse_pivots(Enum.map(filter.pivots, &pivot_param/1) ++ ["#{kind}:#{id}"])

    {:noreply, push_patch(socket, to: stream_path(socket, %{filter | pivots: pivots}))}
  end

  def handle_event("remove_pivot", %{"kind" => kind, "id" => id}, socket) do
    filter = socket.assigns.filter
    pivots = Enum.reject(filter.pivots, &(pivot_param(&1) == "#{kind}:#{id}"))

    {:noreply, push_patch(socket, to: stream_path(socket, %{filter | pivots: pivots}))}
  end

  def handle_event("remove_types", _params, socket) do
    filter = %{socket.assigns.filter | types: @all_types}
    {:noreply, push_patch(socket, to: stream_path(socket, filter))}
  end

  def handle_event("remove_range", _params, socket) do
    filter = %{socket.assigns.filter | range: @default_range}
    {:noreply, push_patch(socket, to: stream_path(socket, filter))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: stream_path(socket, default_filter()))}
  end

  def handle_event("load_older", _params, socket) do
    case List.last(socket.assigns.events) do
      nil ->
        {:noreply, socket}

      oldest ->
        {events, more?} =
          Database.list_events(socket.assigns.subject, list_opts(socket.assigns.filter, oldest.at))

        known = MapSet.new(socket.assigns.events, & &1.key)
        events = Enum.reject(events, &MapSet.member?(known, &1.key))

        {:noreply, assign(socket, events: socket.assigns.events ++ events, has_more?: more?)}
    end
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: stream_path(socket, socket.assigns.filter))}
  end

  def render(assigns) do
    ~H"""
    <Page.page_header>
      <:title>Activity</:title>
      <:description>Every change, session, flow and API request in one stream.</:description>
      <:action>
        <Form.button
          navigate={~p"/#{@account}/settings/log_sinks"}
          icon="ri-upload-2-line"
          size="sm"
        >
          Export
        </Form.button>
      </:action>
    </Page.page_header>

    <div class="flex items-start sm:items-center gap-3 px-6 pb-3">
      <.form
        for={%{}}
        id="activity-filters"
        phx-change="filter"
        phx-submit="filter"
        class="flex flex-wrap items-center gap-2 flex-1 min-w-0"
      >
        <div class="relative w-full sm:w-72 shrink-0">
          <Core.icon
            name="ri-search-line"
            class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-muted pointer-events-none"
          />
          <input
            type="text"
            id="activity-search"
            name="q"
            value={@filter.q}
            placeholder="Search people, devices, resources, paths"
            phx-debounce="300"
            autocomplete="off"
            class="w-full h-8 pl-8 pr-3 text-[13px] bg-bg text-fg border border-rule placeholder:text-faint outline-none focus:ring-1 focus:ring-fg"
          />
        </div>
        <div
          class="relative shrink-0"
          phx-click-away={JS.add_class("hidden", to: "#activity-filters-menu")}
        >
          <button
            type="button"
            id="activity-filters-button"
            phx-click={JS.toggle_class("hidden", to: "#activity-filters-menu")}
            aria-controls="activity-filters-menu"
            class={[
              "inline-flex items-center gap-1.5 h-8 px-3 border text-[13px] font-medium transition-colors",
              @active_count > 0 && "border-fg bg-fg text-bg",
              @active_count == 0 && "border-rule text-fg hover:bg-hover"
            ]}
          >
            <Core.icon name="ri-filter-3-line" class="w-3.5 h-3.5" /> Filters
            <span :if={@active_count > 0} class="tabular-nums">· {@active_count}</span>
          </button>
          <div
            id="activity-filters-menu"
            class="hidden absolute left-0 top-full mt-1 z-40 w-[min(22rem,calc(100vw-2rem))] bg-bg border border-rule shadow-md"
          >
            <fieldset class="px-4 py-3 border-b border-hair">
              <legend class="float-left w-full mb-2 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Type
              </legend>
              <input type="hidden" name="types[]" value="" />
              <label
                :for={{value, type, label} <- types()}
                class="flex items-center gap-2 py-1 text-sm text-fg cursor-pointer"
              >
                <input
                  type="checkbox"
                  id={"activity-type-#{value}"}
                  name="types[]"
                  value={value}
                  checked={type in @filter.types}
                  class="w-3.5 h-3.5 border-rule text-fg focus:ring-0"
                />
                {label}
              </label>
            </fieldset>
            <fieldset class="px-4 py-3">
              <legend class="float-left w-full mb-2 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Time range
              </legend>
              <label
                :for={{value, label, _seconds} <- ranges()}
                class="flex items-center gap-2 py-1 text-sm text-fg cursor-pointer"
              >
                <input
                  type="radio"
                  id={"activity-range-#{value}"}
                  name="range"
                  value={value}
                  checked={value == @filter.range}
                  class="w-3.5 h-3.5 border-rule text-fg focus:ring-0"
                />
                {label}
              </label>
            </fieldset>
          </div>
        </div>
        <.chip
          :if={@filter.types != all_types()}
          id="activity-chip-types"
          label="Type"
          value={type_labels(@filter.types)}
          phx-click="remove_types"
        />
        <.chip
          :if={@filter.range != default_range()}
          id="activity-chip-range"
          label="Time"
          value={range_label(@filter.range)}
          phx-click="remove_range"
        />
        <.chip
          :for={pivot <- @pivots}
          id={"activity-pivot-#{pivot.kind}-#{pivot.id}"}
          label={kind_label(pivot.kind)}
          value={pivot.label}
          phx-click="remove_pivot"
          phx-value-kind={pivot.kind}
          phx-value-id={pivot.id}
        />
        <button
          :if={@active_count > 0 or @filter.q}
          type="button"
          phx-click="clear_filters"
          title="Clear all filters"
          class="inline-flex items-center px-2 h-8 text-[13px] text-muted hover:text-fg hover:underline underline-offset-4"
        >
          Clear all
        </button>
      </.form>
    </div>

    <div class="px-6 pb-8">
      <table id="activity-stream" class="w-full table-fixed text-sm text-left text-fg">
        <thead class="border-b border-rule">
          <tr class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            <th class="w-24 sm:w-32 pt-3 pb-2.5 pr-4 font-semibold">Time</th>
            <th class="hidden sm:table-cell w-44 pt-3 pb-2.5 pr-4 font-semibold">Who</th>
            <th class="pt-3 pb-2.5 pr-4 font-semibold">What</th>
            <th class="w-24 sm:w-28 pt-3 pb-2.5 text-right font-semibold">Result</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={event <- @events}
            id={"activity-event-#{event.type}-#{event.log_id}"}
            phx-click={
              Page.open_modal(stream_path(@account, @filter, event.key),
                title: event.who,
                subtitle: clock(event.at, @browser_tz),
                size: "md"
              )
            }
            class={[
              "border-b border-hair cursor-pointer hover:bg-hover align-top",
              @selected && @selected.key == event.key && "bg-hover"
            ]}
          >
            <td class="py-[11px] pr-4 font-mono text-xs text-muted tabular-nums whitespace-nowrap">
              {clock(event.at, @browser_tz)}
            </td>
            <td class="hidden sm:table-cell py-[11px] pr-4 truncate">
              <.pivot_link :if={event.who_ref} ref={event.who_ref} />
              <span :if={is_nil(event.who_ref)} class="text-muted">{event.who}</span>
            </td>
            <td class="py-[11px] pr-4 min-w-0">
              <div class="truncate">
                <span class="mr-1.5 text-[10px] tracking-[.1em] uppercase text-muted">
                  {type_label(event.type)}
                </span>
                <.sentence parts={event.what} />
              </div>
              <div class="sm:hidden text-xs text-muted truncate">{event.who}</div>
            </td>
            <td class={[
              "py-[11px] text-right whitespace-nowrap",
              (event.bad? && "text-attn") || "text-muted"
            ]}>
              {event.result}
            </td>
          </tr>
        </tbody>
      </table>

      <div
        :if={@events == []}
        id="activity-empty"
        class="flex flex-col items-center gap-2 py-16 text-center"
      >
        <Core.icon name="ri-stack-line" class="w-6 h-6 text-faint" />
        <p class="text-sm font-medium text-fg">No events match these filters</p>
        <p class="text-xs text-muted">Try a wider time range or remove a filter.</p>
      </div>

      <div :if={@has_more?} class="flex justify-center pt-5">
        <Form.button id="activity-load-older" phx-click="load_older" size="sm" icon="ri-arrow-down-line">
          Load older
        </Form.button>
      </div>
    </div>

    <Page.detail_modal id="activity-event-panel" open={not is_nil(@selected)} on_close="close_panel" size="md">
      <Form.panel_header
        :if={@selected}
        title={type_label(@selected.type) <> " · " <> long_time(@selected.at, @browser_tz)}
      />
      <div :if={@selected} class="flex-1 overflow-y-auto px-6 py-5 space-y-6">
        <p class="text-[17px] leading-snug text-fg">
          <span class="font-semibold"><.sentence parts={@selected.what} /></span>
          <span class="text-muted">·</span>
          <span class={(@selected.bad? && "text-attn") || "text-muted"}>{@selected.result}</span>
        </p>
        <p class="-mt-4 text-sm text-muted">by {@selected.who}</p>

        <section>
          <p class="mb-3 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            Related events
          </p>
          <.async_result :let={related} assign={@related}>
            <:loading>
              <div id="activity-related-loading" class="flex flex-col gap-3 animate-pulse" aria-busy="true">
                <span :for={_ <- 1..3} class="block h-3 w-56 bg-hover"></span>
              </div>
            </:loading>
            <:failed>
              <p class="text-xs text-muted">Could not load related events. Reload the page to try again.</p>
            </:failed>
            <ol id="activity-related" class="border-l border-rule ml-1 pl-[18px]">
              <li :for={event <- related} id={"related-#{event.type}-#{event.log_id}"} class="relative pb-4 last:pb-0">
                <span class={[
                  "absolute -left-[22px] top-[5px] w-[7px] h-[7px]",
                  (event.bad? && "bg-attn") || "bg-fg"
                ]}>
                </span>
                <.link
                  patch={stream_path(@account, @filter, event.key)}
                  class={["block hover:underline underline-offset-2", event.key == @selected.key && "font-semibold"]}
                >
                  <time class="block font-mono text-[11px] font-normal text-muted">
                    {clock(event.at, @browser_tz)} · {String.downcase(type_label(event.type))}
                  </time>
                  <span class={event.bad? && "text-attn"}>
                    {event.who}: <.sentence parts={event.what} plain />
                  </span>
                </.link>
              </li>
            </ol>
          </.async_result>
        </section>

        <section :if={pivotable(@selected) != []}>
          <p class="mb-2 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            Filter the stream by
          </p>
          <div class="flex flex-wrap gap-1.5">
            <button
              :for={ref <- pivotable(@selected)}
              type="button"
              id={"activity-pivot-add-#{ref.kind}-#{ref.id}"}
              phx-click="add_pivot"
              phx-value-kind={ref.kind}
              phx-value-id={ref.id}
              class="inline-flex items-center gap-1 h-7 px-2 border border-rule text-xs text-fg hover:bg-fg hover:text-bg"
            >
              <Core.icon name={kind_icon(ref.kind)} class="w-3.5 h-3.5" />
              {ref.label}
            </button>
          </div>
        </section>

        <section :if={openable(@selected) != []}>
          <p class="mb-2 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Open</p>
          <ul class="border-t border-rule">
            <li
              :for={ref <- openable(@selected)}
              class="flex items-center justify-between gap-3 py-2 border-b border-hair text-sm"
            >
              <.link navigate={entity_path(@account, ref)} class="truncate hover:underline underline-offset-2">
                {ref.label}
              </.link>
              <span class="text-xs text-muted">{kind_label(ref.kind)}</span>
            </li>
          </ul>
        </section>
      </div>
      <Form.panel_footer :if={@selected}>
        <Form.panel_footer_button
          id="activity-full-record"
          navigate={record_path(@account, @selected)}
          icon="ri-file-list-3-line"
        >
          View the full record
        </Form.panel_footer_button>
      </Form.panel_footer>
    </Page.detail_modal>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :rest, :global

  defp chip(assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center h-8 border border-rule text-[13px]">
      <span class="pl-2.5 pr-1 text-muted">{@label}:</span>
      <span class="pr-1.5 max-w-48 truncate text-fg">{@value}</span>
      <button
        type="button"
        title={"Remove the #{@label} filter"}
        class="flex items-center h-full px-1.5 border-l border-hair text-muted hover:text-fg hover:bg-hover"
        {@rest}
      >
        <Core.icon name="ri-close-line" class="w-3.5 h-3.5" />
      </button>
    </span>
    """
  end

  attr :parts, :list, required: true
  attr :plain, :boolean, default: false

  defp sentence(assigns) do
    ~H"""
    <%= for part <- @parts do %>
      <%= if is_binary(part) do %>
        {part}
      <% else %>
        <%= if @plain do %>
          {part.label}
        <% else %>
          <.pivot_link ref={part} />
        <% end %>
      <% end %>
    <% end %>
    """
  end

  attr :ref, :map, required: true

  defp pivot_link(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="add_pivot"
      phx-value-kind={@ref.kind}
      phx-value-id={@ref.id}
      title={"Show only activity for #{@ref.label}"}
      class="text-fg hover:underline underline-offset-2"
    >
      {@ref.label}
    </button>
    """
  end

  defp types, do: @types
  defp all_types, do: @all_types
  defp ranges, do: @ranges
  defp default_range, do: @default_range

  defp load(socket, filter) do
    {events, more?} = Database.list_events(socket.assigns.subject, list_opts(filter, DateTime.utc_now()))

    assign(socket,
      filter: filter,
      events: events,
      has_more?: more?,
      pivots: Database.label_refs(socket.assigns.subject, filter.pivots),
      active_count: active_count(filter)
    )
  end

  defp list_opts(filter, before) do
    {_value, _label, seconds} = List.keyfind(@ranges, filter.range, 0)

    %{
      since: DateTime.add(DateTime.utc_now(), -seconds, :second),
      before: before,
      q: filter.q,
      types: filter.types,
      refs: filter.pivots,
      match: :all,
      limit: @page_size
    }
  end

  defp select_event(socket, nil), do: assign(socket, selected: nil, related_key: nil)

  defp select_event(%{assigns: %{selected: %{key: key}, related_key: key}} = socket, key), do: socket

  defp select_event(socket, key) do
    subject = socket.assigns.subject

    event =
      Enum.find(socket.assigns.events, &(&1.key == key)) || Database.fetch_event(subject, key)

    case event do
      nil ->
        assign(socket, selected: nil, related_key: nil)

      event ->
        socket
        |> assign(selected: event, related_key: key)
        |> assign_async(:related, fn -> {:ok, %{related: Database.related(subject, event)}} end, reset: true)
    end
  end

  defp default_filter, do: %{q: nil, types: @all_types, range: @default_range, pivots: []}

  defp parse_filter(params) do
    %{
      q: parse_q(params["q"]),
      types: parse_types(params["types"]),
      range: parse_range(params["range"]),
      pivots: parse_pivots(params["pivot"])
    }
  end

  defp parse_q(q) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      q -> q
    end
  end

  defp parse_q(_q), do: nil

  defp parse_types(values) when is_list(values) do
    case for({value, type, _label} <- @types, value in values, do: type) do
      [] -> @all_types
      types -> types
    end
  end

  defp parse_types(_values), do: @all_types

  defp parse_range(range) do
    case List.keyfind(@ranges, range, 0) do
      {range, _label, _seconds} -> range
      nil -> @default_range
    end
  end

  defp parse_pivots(values) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      with true <- is_binary(value),
           [kind, id] <- String.split(value, ":", parts: 2),
           {:ok, kind} <- Map.fetch(@kinds, kind),
           {:ok, id} <- Ecto.UUID.cast(id) do
        [{kind, id}]
      else
        _invalid -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@max_pivots)
  end

  defp parse_pivots(_values), do: []

  defp pivot_param({kind, id}), do: "#{kind}:#{id}"

  defp active_count(filter) do
    Enum.count([filter.types != @all_types, filter.range != @default_range], & &1) +
      length(filter.pivots)
  end

  defp stream_path(%Phoenix.LiveView.Socket{} = socket, filter),
    do: stream_path(socket.assigns.account, filter, nil)

  defp stream_path(account, filter, event_key) do
    query =
      [
        q: filter.q,
        types: filter.types != @all_types && Enum.map(filter.types, &type_value/1),
        range: filter.range != @default_range && filter.range,
        pivot: filter.pivots != [] && Enum.map(filter.pivots, &pivot_param/1),
        event: event_key
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    ~p"/#{account}/activity?#{query}"
  end

  defp type_value(type), do: @types |> List.keyfind(type, 1) |> elem(0)

  defp type_label(:change), do: "Change"
  defp type_label(:session), do: "Session"
  defp type_label(:flow), do: "Flow"
  defp type_label(:api), do: "API"

  defp type_labels(types), do: Enum.map_join(types, ", ", &(@types |> List.keyfind(&1, 1) |> elem(2)))

  defp range_label(range), do: @ranges |> List.keyfind(range, 0) |> elem(1)

  defp kind_label(:actor), do: "Person"
  defp kind_label(:device), do: "Device"
  defp kind_label(:resource), do: "Resource"
  defp kind_label(:group), do: "Group"
  defp kind_label(:site), do: "Site"
  defp kind_label(:policy), do: "Policy"

  defp kind_icon(:actor), do: "ri-user-line"
  defp kind_icon(:device), do: "ri-computer-line"
  defp kind_icon(:resource), do: "ri-server-line"
  defp kind_icon(:group), do: "ri-team-line"
  defp kind_icon(:site), do: "ri-building-line"
  defp kind_icon(:policy), do: "ri-shield-check-line"

  defp pivotable(event), do: Enum.reject(event.refs, &(&1.kind == :policy))

  defp openable(event), do: Enum.filter(event.refs, & &1.exists?)

  defp entity_path(account, %{kind: :actor, subtype: :service_account, id: id}),
    do: ~p"/#{account}/service_accounts/#{id}"

  defp entity_path(account, %{kind: :actor, subtype: :api_client}),
    do: ~p"/#{account}/settings/api_clients"

  defp entity_path(account, %{kind: :actor, id: id}), do: ~p"/#{account}/actors/#{id}"
  defp entity_path(account, %{kind: :device, id: id}), do: ~p"/#{account}/devices/#{id}"
  defp entity_path(account, %{kind: :resource, id: id}), do: ~p"/#{account}/resources/#{id}"
  defp entity_path(account, %{kind: :group, id: id}), do: ~p"/#{account}/groups/#{id}"
  defp entity_path(account, %{kind: :site, id: id}), do: ~p"/#{account}/sites/#{id}"
  defp entity_path(account, %{kind: :policy, id: id}), do: ~p"/#{account}/policies/#{id}"

  defp record_path(account, %{type: :change, log_id: id}), do: ~p"/#{account}/logs/change_logs/#{id}"
  defp record_path(account, %{type: :session, log_id: id}), do: ~p"/#{account}/logs/session_logs/#{id}"
  defp record_path(account, %{type: :flow, log_id: id}), do: ~p"/#{account}/logs/flow_logs/#{id}"

  defp record_path(account, %{type: :api, log_id: id}),
    do: ~p"/#{account}/logs/api_request_logs/#{id}"

  defp clock(at, tz) do
    local = shift(at, tz)

    if Date.compare(DateTime.to_date(local), DateTime.to_date(shift(DateTime.utc_now(), tz))) == :eq do
      Calendar.strftime(local, "%H:%M:%S")
    else
      Calendar.strftime(local, "%b %-d %H:%M")
    end
  end

  defp long_time(at, tz), do: Calendar.strftime(shift(at, tz), "%b %-d, %Y %H:%M:%S %Z")

  defp shift(at, tz) do
    case DateTime.shift_zone(at, tz, Tz.TimeZoneDatabase) do
      {:ok, local} -> local
      {:error, _reason} -> at
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{
      Actor,
      APIRequestLog,
      ChangeLog,
      Device,
      FlowLog,
      Group,
      Policy,
      Resource,
      Safe,
      SessionLog,
      Site
    }

    alias Portal.Types.LogId

    @related_window_seconds 3_600
    @related_limit 8

    # The JSON key a change log row uses to point at each kind, and the table
    # holding records of that kind.
    @change_keys %{
      actor: {"actors", "actor_id"},
      device: {"devices", "device_id"},
      resource: {"resources", "resource_id"},
      group: {"groups", "group_id"},
      site: {"sites", "site_id"},
      policy: {"policies", "policy_id"}
    }
    @change_kinds Map.new(@change_keys, fn {kind, {table, _key}} -> {table, kind} end)

    @nouns %{
      "accounts" => "account settings",
      "actors" => "person",
      "api_tokens" => "API token",
      "auth_providers" => "auth provider",
      "device_tokens" => "device token",
      "devices" => "device",
      "directories" => "directory",
      "external_identities" => "identity",
      "groups" => "group",
      "memberships" => "membership",
      "policies" => "policy",
      "portal_sessions" => "admin session",
      "resources" => "resource",
      "sites" => "site"
    }

    @doc """
    The newest events of the given types between `since` and `before`, merged
    newest first. Each type is read with its own time-bounded, indexed query
    capped at `limit`, and the merge happens here.
    """
    def list_events(subject, opts) do
      rows = Enum.map(opts.types, &{&1, fetch(&1, subject, opts)})
      full? = Enum.any?(rows, fn {_type, list} -> length(list) >= opts.limit end)

      events =
        rows
        |> build(subject)
        |> Enum.sort_by(& &1.at, {:desc, DateTime})

      {Enum.take(events, opts.limit), full? or length(events) > opts.limit}
    end

    @doc "Events near the given one in time that share its person, device or resource."
    def related(subject, event) do
      refs =
        for %{kind: kind, id: id} <- event.refs, kind in [:actor, :device, :resource], do: {kind, id}

      events =
        if refs == [] do
          []
        else
          {events, _more?} =
            list_events(subject, %{
              since: DateTime.add(event.at, -@related_window_seconds, :second),
              before: DateTime.add(event.at, @related_window_seconds, :second),
              q: nil,
              types: [:change, :session, :flow, :api],
              refs: refs,
              match: :any,
              limit: @related_limit
            })

          events
        end

      [event | events]
      |> Enum.uniq_by(& &1.key)
      |> Enum.sort_by(&abs(DateTime.diff(&1.at, event.at, :microsecond)))
      |> Enum.take(@related_limit)
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
    end

    @doc "Loads one event by its key, `type:log_id`."
    def fetch_event(subject, key) when is_binary(key) do
      with [type, log_id] <- String.split(key, ":", parts: 2),
           {:ok, type} <- event_type(type),
           {:ok, log_id} <- LogId.parse(log_id),
           [row] <- fetch_one(type, log_id, subject) do
        [{type, [row]}] |> build(subject) |> List.first()
      else
        _other -> nil
      end
    end

    def fetch_event(_subject, _key), do: nil

    @doc "Names for the pivot chips."
    def label_refs(_subject, []), do: []

    def label_refs(subject, refs) do
      names = load_names(refs, subject)
      Enum.map(refs, fn {kind, id} -> ref(names, kind, id, nil) end)
    end

    defp event_type("change"), do: {:ok, :change}
    defp event_type("session"), do: {:ok, :session}
    defp event_type("flow"), do: {:ok, :flow}
    defp event_type("api"), do: {:ok, :api}
    defp event_type(_type), do: :error

    defp fetch(:change, subject, opts) do
      from(cl in ChangeLog,
        as: :change_logs,
        where: cl.timestamp >= ^opts.since and cl.timestamp < ^opts.before,
        where: not is_nil(cl.subject),
        order_by: [desc: cl.timestamp],
        limit: ^opts.limit
      )
      |> search(:change, opts.q, subject)
      |> run(:change, opts, subject)
    end

    defp fetch(:session, subject, opts) do
      from(sl in SessionLog,
        as: :session_logs,
        where: sl.timestamp >= ^opts.since and sl.timestamp < ^opts.before,
        order_by: [desc: sl.timestamp],
        limit: ^opts.limit
      )
      |> search(:session, opts.q, subject)
      |> run(:session, opts, subject)
    end

    defp fetch(:flow, subject, opts) do
      from(fl in FlowLog,
        as: :flow_logs,
        where: fl.flow_start >= ^opts.since and fl.flow_start < ^opts.before,
        order_by: [desc: fl.flow_start],
        limit: ^opts.limit
      )
      |> search(:flow, opts.q, subject)
      |> run(:flow, opts, subject)
    end

    defp fetch(:api, subject, opts) do
      from(arl in APIRequestLog,
        as: :api_request_logs,
        where: arl.inserted_at >= ^opts.since and arl.inserted_at < ^opts.before,
        order_by: [desc: arl.inserted_at],
        limit: ^opts.limit
      )
      |> search(:api, opts.q, subject)
      |> run(:api, opts, subject)
    end

    defp fetch_one(:change, log_id, subject),
      do: from(cl in ChangeLog, where: cl.log_id == ^log_id) |> all(subject)

    defp fetch_one(:session, log_id, subject),
      do: from(sl in SessionLog, where: sl.log_id == ^log_id) |> all(subject)

    defp fetch_one(:flow, log_id, subject),
      do: from(fl in FlowLog, where: fl.log_id == ^log_id, limit: 1) |> all(subject)

    defp fetch_one(:api, log_id, subject),
      do: from(arl in APIRequestLog, where: arl.log_id == ^log_id) |> all(subject)

    defp run(query, type, opts, subject) do
      case filter_refs(query, type, opts.refs, opts.match) do
        {:ok, query} -> all(query, subject)
        :skip -> []
      end
    end

    defp all(query, subject) do
      case query |> Safe.scoped(subject) |> Safe.all() do
        rows when is_list(rows) -> rows
        {:error, :unauthorized} -> []
      end
    end

    defp search(query, _type, nil, _subject), do: query

    defp search(query, :change, q, _subject) do
      pattern = like(q)

      where(
        query,
        [change_logs: cl],
        fragment("?->>'actor_name' ILIKE ?", cl.subject, ^pattern) or
          fragment("?->>'actor_email' ILIKE ?", cl.subject, ^pattern) or
          ilike(cl.object, ^pattern) or
          fragment("coalesce(?, ?)->>'name' ILIKE ?", cl.after, cl.before, ^pattern)
      )
    end

    defp search(query, :session, q, _subject) do
      pattern = like(q)

      where(
        query,
        [session_logs: sl],
        fragment("?->>'actor_name' ILIKE ?", sl.subject, ^pattern) or
          fragment("?->>'actor_email' ILIKE ?", sl.subject, ^pattern) or
          fragment("?->>'user_agent' ILIKE ?", sl.subject, ^pattern)
      )
    end

    defp search(query, :flow, q, _subject) do
      pattern = like(q)

      where(
        query,
        [flow_logs: fl],
        ilike(fl.initiator_actor_name, ^pattern) or ilike(fl.initiator_actor_email, ^pattern) or
          ilike(fl.resource_name, ^pattern) or ilike(fl.resource_address, ^pattern) or
          ilike(fl.domain, ^pattern)
      )
    end

    defp search(query, :api, q, subject) do
      pattern = like(q)

      actor_ids =
        from(a in Actor,
          where: ilike(a.name, ^pattern) or ilike(a.email, ^pattern),
          select: a.id,
          limit: 100
        )
        |> all(subject)

      where(
        query,
        [api_request_logs: arl],
        ilike(arl.path, ^pattern) or arl.actor_id in ^actor_ids
      )
    end

    defp like(q), do: "%" <> String.replace(q, ~r/[\\%_]/, "\\\\\\0") <> "%"

    defp filter_refs(query, _type, [], _match), do: {:ok, query}

    defp filter_refs(query, type, refs, match) do
      dynamics = Enum.map(refs, fn {kind, id} -> ref_dynamic(type, kind, id) end)
      supported = Enum.reject(dynamics, &is_nil/1)

      cond do
        supported == [] ->
          :skip

        match == :all and length(supported) < length(dynamics) ->
          :skip

        match == :all ->
          {:ok, where(query, ^Enum.reduce(supported, &dynamic(^&2 and ^&1)))}

        true ->
          {:ok, where(query, ^Enum.reduce(supported, &dynamic(^&2 or ^&1)))}
      end
    end

    defp ref_dynamic(:change, :actor, id) do
      dynamic(
        [change_logs: cl],
        fragment("?->>'actor_id' = ?", cl.subject, ^id) or ^change_record(:actor, id)
      )
    end

    defp ref_dynamic(:change, kind, id), do: change_record(kind, id)

    defp ref_dynamic(:session, :actor, id),
      do: dynamic([session_logs: sl], fragment("?->>'actor_id' = ?", sl.subject, ^id))

    defp ref_dynamic(:session, :device, id),
      do: dynamic([session_logs: sl], fragment("?->>'device_id' = ?", sl.subject, ^id))

    defp ref_dynamic(:flow, :actor, id), do: dynamic([flow_logs: fl], fl.initiator_actor_id == ^id)

    defp ref_dynamic(:flow, :device, id),
      do: dynamic([flow_logs: fl], fl.initiator_device_id == ^id or fl.responder_device_id == ^id)

    defp ref_dynamic(:flow, :resource, id), do: dynamic([flow_logs: fl], fl.resource_id == ^id)
    defp ref_dynamic(:flow, :policy, id), do: dynamic([flow_logs: fl], fl.policy_id == ^id)
    defp ref_dynamic(:api, :actor, id), do: dynamic([api_request_logs: arl], arl.actor_id == ^id)
    defp ref_dynamic(_type, _kind, _id), do: nil

    defp change_record(kind, id) do
      {table, key} = Map.fetch!(@change_keys, kind)

      dynamic(
        [change_logs: cl],
        fragment("coalesce(?, ?)->>? = ?", cl.after, cl.before, type(^key, :string), ^id) or
          (cl.object == ^table and fragment("coalesce(?, ?)->>'id' = ?", cl.after, cl.before, ^id))
      )
    end

    # Events: rows of every type become one shape. Names that the log rows do
    # not carry are read in one query per kind.

    defp build(rows_by_type, subject) do
      rows_by_type = Enum.map(rows_by_type, fn {type, rows} -> {type, dedupe(type, rows)} end)

      names =
        rows_by_type
        |> Enum.flat_map(fn {type, rows} -> Enum.flat_map(rows, &ids(type, &1)) end)
        |> load_names(subject)

      Enum.flat_map(rows_by_type, fn {type, rows} -> Enum.map(rows, &event(type, &1, names)) end)
    end

    # Both sides of a flow may report it. Show it once.
    defp dedupe(:flow, rows) do
      Enum.uniq_by(rows, fn fl ->
        {fl.policy_authorization_id, fl.initiator_device_id, fl.resource_id, fl.protocol, fl.inner_src_ip,
         fl.inner_src_port, fl.inner_dst_port}
      end)
    end

    defp dedupe(_type, rows), do: rows

    defp ids(:change, cl) do
      data = cl.after || cl.before || %{}
      record = Map.get(@change_kinds, cl.object)

      [{:actor, subject_field(cl, "actor_id")}, record && {record, data["id"]}] ++
        for {kind, {_table, key}} <- @change_keys, do: {kind, data[key]}
    end

    defp ids(:session, sl), do: [{:actor, subject_field(sl, "actor_id")}, {:device, subject_field(sl, "device_id")}]

    defp ids(:flow, fl) do
      [
        {:actor, fl.initiator_actor_id},
        {:device, fl.initiator_device_id},
        {:device, fl.responder_device_id},
        {:resource, fl.resource_id},
        {:policy, fl.policy_id}
      ]
    end

    defp ids(:api, arl), do: [{:actor, arl.actor_id}]

    defp event(:change, cl, names) do
      data = cl.after || cl.before || %{}
      actor = ref(names, :actor, subject_field(cl, "actor_id"), actor_snapshot(cl.subject))
      record_kind = Map.get(@change_kinds, cl.object)
      record = record_kind && ref(names, record_kind, data["id"], data["name"] || data["email"])
      fks = for {kind, {_table, key}} <- @change_keys, data[key], do: ref(names, kind, data[key], nil)

      %{
        key: "change:#{cl.log_id}",
        type: :change,
        log_id: cl.log_id,
        at: cl.timestamp,
        who: actor_label(actor, cl.subject),
        who_ref: actor,
        what: change_sentence(cl.object, cl.operation, record, names, data),
        result: "Saved",
        bad?: false,
        refs: compact_refs([actor, record | fks])
      }
    end

    defp event(:session, sl, names) do
      actor = ref(names, :actor, subject_field(sl, "actor_id"), actor_snapshot(sl.subject))
      device = ref(names, :device, subject_field(sl, "device_id"), os_name(sl))

      %{
        key: "session:#{sl.log_id}",
        type: :session,
        log_id: sl.log_id,
        at: sl.timestamp,
        who: actor_label(actor, sl.subject) || (device && device.label) || "Gateway",
        who_ref: actor,
        what: session_sentence(sl.context, device),
        result: "OK",
        bad?: false,
        refs: compact_refs([actor, device])
      }
    end

    defp event(:flow, fl, names) do
      actor = ref(names, :actor, fl.initiator_actor_id, fl.initiator_actor_name || fl.initiator_actor_email)
      device = ref(names, :device, fl.initiator_device_id, nil)
      gateway = ref(names, :device, fl.responder_device_id, nil)
      resource = ref(names, :resource, fl.resource_id, fl.resource_name)
      policy = ref(names, :policy, fl.policy_id, nil)

      %{
        key: "flow:#{fl.log_id}",
        type: :flow,
        log_id: fl.log_id,
        at: fl.flow_start,
        who: (actor && actor.label) || "Unknown",
        who_ref: actor,
        what: [device || "A deleted device", " → ", resource || fl.resource_name || "a resource"],
        result: flow_result(fl),
        bad?: false,
        refs: compact_refs([actor, device, resource, gateway, policy])
      }
    end

    defp event(:api, arl, names) do
      actor = ref(names, :actor, arl.actor_id, nil)
      {result, bad?} = api_result(arl.mcp)

      %{
        key: "api:#{arl.log_id}",
        type: :api,
        log_id: arl.log_id,
        at: arl.inserted_at,
        who: (actor && actor.label) || "Deleted actor",
        who_ref: actor,
        what: ["#{arl.method} #{arl.path}"],
        result: result,
        bad?: bad?,
        refs: compact_refs([actor])
      }
    end

    defp change_sentence("memberships", operation, _record, names, data) do
      actor = ref(names, :actor, data["actor_id"], nil) || "someone"
      group = ref(names, :group, data["group_id"], nil) || "a group"

      case operation do
        :insert -> ["Added ", actor, " to ", group]
        :delete -> ["Removed ", actor, " from ", group]
        :update -> ["Updated the membership of ", actor, " in ", group]
      end
    end

    defp change_sentence("policies", operation, record, names, data) do
      group = ref(names, :group, data["group_id"], nil) || "a group"
      resource = ref(names, :resource, data["resource_id"], nil) || "a resource"
      verb = verb(operation)

      if record do
        [verb <> " ", record, ": ", group, " → ", resource]
      else
        [verb <> " a policy: ", group, " → ", resource]
      end
    end

    defp change_sentence(object, operation, nil, _names, _data) do
      ["#{verb(operation)} #{noun(object)}"]
    end

    defp change_sentence(object, operation, record, _names, _data) do
      ["#{verb(operation)} #{noun(object)} ", record]
    end

    defp session_sentence(:client, nil), do: ["Signed in on a device"]
    defp session_sentence(:client, device), do: ["Signed in on ", device]
    defp session_sentence(:gateway, nil), do: ["A gateway connected"]
    defp session_sentence(:gateway, device), do: ["Gateway ", device, " connected"]
    defp session_sentence(:portal, _device), do: ["Signed in to the admin portal"]

    defp verb(:insert), do: "Created"
    defp verb(:update), do: "Updated"
    defp verb(:delete), do: "Deleted"

    defp noun(object) do
      Map.get_lazy(@nouns, object, fn ->
        object |> String.trim_trailing("s") |> String.replace("_", " ")
      end)
    end

    defp flow_result(%{flow_end: nil}), do: "Open"
    defp flow_result(_fl), do: "Allowed"

    defp api_result(%{"http_status" => status}) when is_integer(status) and status >= 400,
      do: {to_string(status), true}

    defp api_result(%{"http_status" => status}) when is_integer(status), do: {to_string(status), false}
    defp api_result(%{"outcome" => outcome}) when outcome in ["failed", "rejected"], do: {"Failed", true}
    defp api_result(_mcp), do: {"Received", false}

    defp subject_field(%{subject: subject}, key) when is_map(subject), do: Map.get(subject, key)
    defp subject_field(_row, _key), do: nil

    defp actor_snapshot(%{} = subject), do: blank_to_nil(subject["actor_name"]) || blank_to_nil(subject["actor_email"])
    defp actor_snapshot(_subject), do: nil

    defp actor_label(%{label: label}, _subject), do: label
    defp actor_label(nil, subject), do: actor_snapshot(subject) || "System"

    defp os_name(%{subject: %{"user_agent" => ua}}) when is_binary(ua) and ua != "" do
      case ua |> PortalWeb.Devices.Components.os_name_and_version() |> String.trim() do
        "" -> nil
        name -> name
      end
    end

    defp os_name(_row), do: nil

    defp blank_to_nil(value) when value in [nil, ""], do: nil
    defp blank_to_nil(value), do: value

    defp compact_refs(refs) do
      refs
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1.kind, &1.id})
    end

    # A reference to a person, device, resource, group, site or policy. The
    # current name wins over the name the log row kept, which wins over a
    # placeholder for something since deleted.
    defp ref(names, kind, id, snapshot) do
      case Ecto.UUID.cast(id) do
        {:ok, id} ->
          case Map.get(names, {kind, id}) do
            %{label: label, subtype: subtype} ->
              %{kind: kind, id: id, label: label, subtype: subtype, exists?: true}

            nil ->
              %{kind: kind, id: id, label: snapshot || deleted_label(kind), subtype: nil, exists?: false}
          end

        :error ->
          nil
      end
    end

    defp deleted_label(:actor), do: "Deleted person"
    defp deleted_label(:device), do: "Deleted device"
    defp deleted_label(:resource), do: "Deleted resource"
    defp deleted_label(:group), do: "Deleted group"
    defp deleted_label(:site), do: "Deleted site"
    defp deleted_label(:policy), do: "Deleted policy"

    defp load_names(refs, subject) do
      ids =
        refs
        |> Enum.reject(fn ref -> is_nil(ref) or is_nil(elem(ref, 1)) end)
        |> Enum.flat_map(fn {kind, id} ->
          case Ecto.UUID.cast(id) do
            {:ok, id} -> [{kind, id}]
            :error -> []
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {kind, ids} -> {kind, Enum.uniq(ids)} end)

      policies = records(Policy, Map.get(ids, :policy, []), subject)

      ids =
        Enum.reduce(policies, ids, fn policy, ids ->
          ids
          |> Map.update(:group, [policy.group_id], &[policy.group_id | &1])
          |> Map.update(:resource, [policy.resource_id], &[policy.resource_id | &1])
        end)

      names =
        [actor: Actor, device: Device, resource: Resource, group: Group, site: Site]
        |> Enum.flat_map(fn {kind, schema} ->
          schema
          |> records(ids |> Map.get(kind, []) |> Enum.reject(&is_nil/1) |> Enum.uniq(), subject)
          |> Enum.map(&{{kind, &1.id}, name(kind, &1)})
        end)
        |> Map.new()

      Enum.reduce(policies, names, fn policy, names ->
        group = names |> Map.get({:group, policy.group_id}, %{label: "a group"}) |> Map.fetch!(:label)
        resource = names |> Map.get({:resource, policy.resource_id}, %{label: "a resource"}) |> Map.fetch!(:label)
        Map.put(names, {:policy, policy.id}, %{label: "#{group} → #{resource}", subtype: nil})
      end)
    end

    defp records(_schema, [], _subject), do: []
    defp records(schema, ids, subject), do: from(record in schema, where: record.id in ^ids) |> all(subject)

    defp name(:actor, actor), do: %{label: actor.name || actor.email || "Unnamed", subtype: actor.type}
    defp name(:device, device), do: %{label: device.name || "Unnamed device", subtype: device.type}
    defp name(_kind, record), do: %{label: record.name, subtype: nil}
  end
end
