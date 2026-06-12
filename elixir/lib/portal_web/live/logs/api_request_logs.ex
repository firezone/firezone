defmodule PortalWeb.Logs.APIRequestLogs do
  use PortalWeb, :live_view

  import PortalWeb.Logs.Components

  alias __MODULE__.Database

  @table_id "api_request_logs"
  @filter_key "api_request_logs_filter"

  def mount(_params, _session, socket) do
    browser_tz = browser_tz_from_connect(socket)

    socket =
      socket
      |> assign(page_title: "API Request Logs")
      |> assign(selected_log: nil, browser_tz: browser_tz)
      |> assign(tz_mode: "utc", display_tz: "Etc/UTC")
      |> assign_live_table(@table_id,
        query_module: Database,
        sortable_fields: [{:api_request_logs, :inserted_at}, {:api_request_logs, :event_id}],
        callback: &handle_logs_update!/2
      )

    {:ok, socket}
  end

  def handle_params(
        %{"event_id" => event_id} = params,
        uri,
        %{assigns: %{live_action: :show}} = socket
      ) do
    socket =
      socket
      |> assign_tz(params, @filter_key)
      |> handle_live_tables_params(params, uri)

    case Database.fetch_log(event_id, socket.assigns.subject) do
      {:ok, row} ->
        {:noreply, assign(socket, selected_log: row)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "API request log not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/api_request_logs")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this log")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/api_request_logs")}
    end
  end

  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(selected_log: nil)
      |> assign_tz(params, @filter_key)
      |> handle_live_tables_params(params, uri)

    {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "table_row_click", "change_limit"],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/logs/api_request_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_log) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/logs/api_request_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_logs_update!(socket, list_opts) do
    with {:ok, rows, metadata} <-
           Database.list_api_request_logs(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, api_request_logs: rows, api_request_logs_metadata: metadata)}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="ri-terminal-box-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>API Request Logs</:title>
        <:description>
          Every authenticated REST API call, with full actor and source attribution.
        </:description>
        <:action>
          <.docs_action path="/administer/logs" />
        </:action>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="api_request_logs"
          rows={@api_request_logs}
          row_id={&"api-request-log-#{&1.log.event_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/api_request_logs/#{row.log.event_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_log) and row.log.event_id == @selected_log.log.event_id
            end
          }
          filters={@filters_by_table_id["api_request_logs"]}
          filter={@filter_form_by_table_id["api_request_logs"]}
          ordered_by={@order_by_table_id["api_request_logs"]}
          metadata={@api_request_logs_metadata}
          class="flex-1 min-h-0"
          row_item={& &1}
        >
          <:col
            :let={row}
            field={{:api_request_logs, :inserted_at}}
            label="Timestamp"
            class="w-44"
          >
            <.timestamp_cell
              event_id={row.log.event_id}
              timestamp={row.log.inserted_at}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} label="Method" class="w-24">
            <.method_badge method={row.log.method} />
          </:col>
          <:col :let={row} label="Path">
            <span class="font-mono text-xs text-[var(--text-primary)] break-all">
              {row.log.path}
            </span>
          </:col>
          <:col :let={row} label="Size" class="w-20 text-right tabular-nums">
            <span class="text-xs text-[var(--text-secondary)]">
              {format_size(row.log.content_length)}
            </span>
          </:col>
          <:col :let={row} label="Actor" class="w-64">
            <.actor_display actor={row.actor} actor_id={row.log.actor_id} />
          </:col>
          <:col :let={row} label="Client" class="w-40">
            <.client_display user_agent={row.log.user_agent} />
          </:col>
          <:col :let={row} label="IP" class="w-32">
            <span class="font-mono text-xs text-[var(--text-secondary)]">
              {format_ip(row.log.ip)}
            </span>
          </:col>
          <:col :let={row} label="Location" class="w-48">
            <span class="text-xs text-[var(--text-secondary)] truncate">
              {row_location(row.log)}
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-terminal-box-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No API requests</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Authenticated REST API calls will appear here as they happen.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.show_panel id="api-request-log-panel" open?={not is_nil(@selected_log)}>
        <:title>
          <%= if @selected_log do %>
            <.method_badge method={@selected_log.log.method} />
            <span class="font-mono text-sm font-semibold text-[var(--text-primary)] truncate">
              {@selected_log.log.path}
            </span>
          <% end %>
        </:title>
        <div :if={@selected_log} class="flex-1 flex flex-col min-h-0 overflow-auto p-5 gap-4">
          <.actor_card
            name={@selected_log.actor && @selected_log.actor.name}
            email={@selected_log.actor && @selected_log.actor.email}
            type={@selected_log.actor && @selected_log.actor.type}
            fallback_id={@selected_log.log.actor_id}
          />

          <section class="flex flex-col">
            <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-2">
              Request
            </div>
            <div class="rounded border border-[var(--border)] bg-[var(--surface)] p-4 grid grid-cols-2 gap-4">
              <div>
                <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
                  Body size
                </div>
                <div class="text-sm text-[var(--text-primary)] tabular-nums">
                  {format_size(@selected_log.log.content_length)}
                </div>
              </div>
              <div class="min-w-0">
                <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
                  Request ID
                </div>
                <div class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.log.request_id}
                </div>
              </div>
            </div>
          </section>

          <section class="flex flex-col">
            <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-2">
              Location
            </div>
            <.location_map lat={@selected_log.log.ip_lat} lon={@selected_log.log.ip_lon}>
              <:caption>
                <div class="flex items-center justify-between gap-2 text-xs">
                  <div class="flex items-center gap-2 min-w-0">
                    <.icon
                      name="ri-map-pin-line"
                      class="w-3.5 h-3.5 shrink-0 text-[var(--text-tertiary)]"
                    />
                    <span class="text-[var(--text-primary)] truncate">
                      {api_location_caption(@selected_log.log)}
                    </span>
                    <span
                      :if={@selected_log.log.ip}
                      class="font-mono text-[10px] text-[var(--text-tertiary)] shrink-0"
                    >
                      · {format_ip(@selected_log.log.ip)}
                    </span>
                  </div>
                  <span
                    :if={
                      is_number(@selected_log.log.ip_lat) and is_number(@selected_log.log.ip_lon)
                    }
                    class="font-mono text-[10px] text-[var(--text-tertiary)] tabular-nums shrink-0"
                  >
                    {format_coord(@selected_log.log.ip_lat)}, {format_coord(
                      @selected_log.log.ip_lon
                    )}
                  </span>
                </div>
              </:caption>
            </.location_map>
          </section>
        </div>
        <.show_panel_sidebar :if={@selected_log}>
          <section>
            <.section_heading label="Details" />
            <dl class="space-y-2.5">
              <.detail_row label="Timestamp">
                <.timestamp_cell
                  id_prefix="panel-timestamp"
                  event_id={@selected_log.log.event_id}
                  timestamp={@selected_log.log.inserted_at}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Event ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.log.event_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Identifiers" />
            <dl class="space-y-2.5">
              <.detail_row label="Actor ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.log.actor_id}
                </span>
              </.detail_row>
              <.detail_row label="Token ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.log.api_token_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Source" />
            <dl class="space-y-2.5">
              <.detail_row :if={@selected_log.log.ip_city} label="City">
                <span class="text-xs text-[var(--text-primary)]">
                  {@selected_log.log.ip_city}
                </span>
              </.detail_row>
              <.detail_row :if={@selected_log.log.ip_region} label="Region">
                <span class="text-xs text-[var(--text-primary)]">
                  {Portal.Geo.country_common_name!(@selected_log.log.ip_region) ||
                    @selected_log.log.ip_region}
                </span>
              </.detail_row>
              <.detail_row :if={@selected_log.log.user_agent} label="User agent">
                <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
                  {@selected_log.log.user_agent}
                </span>
              </.detail_row>
            </dl>
          </section>
        </.show_panel_sidebar>
      </.show_panel>
    </div>
    """
  end

  attr :actor, :any, required: true
  attr :actor_id, :any, required: true

  defp actor_display(%{actor: nil} = assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="text-xs text-[var(--text-tertiary)] italic">Deleted actor</div>
      <div class="font-mono text-[10px] text-[var(--text-tertiary)] truncate">{@actor_id}</div>
    </div>
    """
  end

  defp actor_display(assigns) do
    ~H"""
    <div class="min-w-0">
      <div
        :if={@actor.name not in [nil, ""]}
        class="text-sm font-medium text-[var(--text-primary)] truncate"
      >
        {@actor.name}
      </div>
      <div :if={@actor.email not in [nil, ""]} class="text-xs text-[var(--text-tertiary)] truncate">
        {@actor.email}
      </div>
      <div
        :if={@actor.name in [nil, ""] and @actor.email in [nil, ""]}
        class="font-mono text-[10px] text-[var(--text-tertiary)] truncate"
      >
        {@actor_id}
      </div>
    </div>
    """
  end

  attr :user_agent, :any, required: true

  defp client_display(assigns) do
    {icon, label} = client_info(assigns.user_agent)
    assigns = assign(assigns, icon: icon, label: label)

    ~H"""
    <div class="flex items-center gap-2 text-xs text-[var(--text-secondary)]" title={@user_agent}>
      <.icon name={@icon} class="w-4 h-4 shrink-0" />
      <span class="truncate">{@label}</span>
    </div>
    """
  end

  attr :method, :string, required: true

  defp method_badge(%{method: method} = assigns) do
    assigns = assign(assigns, :type, method_badge_type(method))

    ~H"""
    <.badge type={@type} class="uppercase font-mono">{@method}</.badge>
    """
  end

  defp method_badge_type("GET"), do: "info"
  defp method_badge_type("HEAD"), do: "info"
  defp method_badge_type("POST"), do: "success"
  defp method_badge_type("PUT"), do: "warning"
  defp method_badge_type("PATCH"), do: "warning"
  defp method_badge_type("DELETE"), do: "danger"
  defp method_badge_type(_method), do: "neutral"

  defp format_size(nil), do: "-"
  defp format_size(0), do: "0 B"
  defp format_size(n) when is_integer(n) and n < 1024, do: "#{n} B"

  defp format_size(n) when is_integer(n) and n < 1_048_576,
    do: :erlang.float_to_binary(n / 1024, decimals: 1) <> " KB"

  defp format_size(n) when is_integer(n),
    do: :erlang.float_to_binary(n / 1_048_576, decimals: 1) <> " MB"

  defp format_ip(%Postgrex.INET{address: address}) when tuple_size(address) in [4, 8],
    do: to_string(:inet.ntoa(address))

  defp format_ip(other), do: to_string(other)

  defp format_coord(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 3)

  defp row_location(log) do
    region =
      case log.ip_region do
        nil -> nil
        code -> Portal.Geo.country_common_name!(code) || code
      end

    case Enum.reject([log.ip_city, region], &(&1 in [nil, ""])) do
      [] -> "-"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp api_location_caption(log) do
    region =
      case log.ip_region do
        nil -> nil
        code -> Portal.Geo.country_common_name!(code) || code
      end

    case Enum.reject([log.ip_city, region], &(&1 in [nil, ""])) do
      [] -> "Location unknown"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp client_info(nil), do: {"ri-terminal-box-line", "API client"}
  defp client_info(""), do: {"ri-terminal-box-line", "API client"}

  defp client_info(ua) do
    cond do
      ua =~ ~r/terraform/i -> {"icon-terraform", "Terraform"}
      ua =~ ~r/docker/i -> {"icon-docker", "Docker"}
      String.starts_with?(ua, "curl") -> {"ri-terminal-line", first_token(ua)}
      String.starts_with?(ua, "gh/") -> {"ri-github-fill", "GitHub CLI"}
      String.starts_with?(ua, "python-") -> {"ri-code-line", first_token(ua)}
      String.starts_with?(ua, "Go-http-client") -> {"ri-code-line", "Go client"}
      String.starts_with?(ua, "node-fetch") -> {"ri-code-line", first_token(ua)}
      ua =~ ~r/mozilla|chrome|safari|firefox/i -> {"ri-window-line", "Browser"}
      true -> {"ri-terminal-box-line", first_token(ua)}
    end
  end

  defp first_token(ua), do: ua |> String.split() |> List.first()

  defmodule Database do
    import Ecto.Query

    alias Portal.APIRequestLog
    alias Portal.Actor
    alias Portal.Safe
    alias Portal.Types.EventId

    def list_api_request_logs(subject, opts \\ []) do
      result =
        from(arl in APIRequestLog, as: :api_request_logs)
        |> Safe.scoped(subject, :replica)
        |> Safe.list_offset(__MODULE__, opts)

      case result do
        {:ok, logs, metadata} -> {:ok, enrich(logs, subject), metadata}
        other -> other
      end
    end

    def fetch_log(event_id, subject) do
      with {:ok, event_id} <- EventId.parse(event_id) do
        result =
          from(arl in APIRequestLog, as: :api_request_logs)
          |> where([api_request_logs: arl], arl.event_id == ^event_id)
          |> Safe.scoped(subject, :replica)
          |> Safe.one(fallback_to_primary: true)

        case result do
          nil ->
            {:error, :not_found}

          {:error, :unauthorized} ->
            {:error, :unauthorized}

          log ->
            [row] = enrich([log], subject)
            {:ok, row}
        end
      else
        :error -> {:error, :not_found}
      end
    end

    def cursor_fields,
      do: [{:api_request_logs, :desc, :inserted_at}, {:api_request_logs, :desc, :event_id}]

    @method_values [
      {"GET", "GET"},
      {"POST", "POST"},
      {"PUT", "PUT"},
      {"PATCH", "PATCH"},
      {"DELETE", "DELETE"},
      {"HEAD", "HEAD"}
    ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "Path, actor ID, or event ID",
          type: {:string, :websearch},
          fun: &filter_by_search/2
        },
        %Portal.Repo.Filter{
          name: :method,
          title: "Method",
          type: {:list, :string},
          values: @method_values,
          fun: &filter_by_method/2
        },
        %Portal.Repo.Filter{
          name: :timestamp,
          title: "Timestamp",
          type: {:range, :datetime},
          fun: &filter_by_timestamp/2
        }
      ]
    end

    defp enrich([], _subject), do: []

    defp enrich(logs, subject) do
      actor_ids = logs |> Enum.map(& &1.actor_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      actors_by_id = load_by_ids(Actor, actor_ids, subject)

      Enum.map(logs, fn log ->
        %{
          log: log,
          actor: Map.get(actors_by_id, log.actor_id)
        }
      end)
    end

    defp load_by_ids(_schema, [], _subject), do: %{}

    defp load_by_ids(schema, ids, subject) do
      from(x in schema, where: x.id in ^ids)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} -> %{}
        list when is_list(list) -> Map.new(list, &{&1.id, &1})
      end
    end

    defp filter_by_timestamp(queryable, %Portal.Repo.Filter.Range{from: from, to: to}) do
      {queryable, timestamp_dynamic(from, to)}
    end

    defp timestamp_dynamic(%DateTime{} = from, %DateTime{} = to),
      do:
        dynamic(
          [api_request_logs: arl],
          arl.inserted_at >= ^from and arl.inserted_at <= ^to
        )

    defp timestamp_dynamic(%DateTime{} = from, nil),
      do: dynamic([api_request_logs: arl], arl.inserted_at >= ^from)

    defp timestamp_dynamic(nil, %DateTime{} = to),
      do: dynamic([api_request_logs: arl], arl.inserted_at <= ^to)

    defp filter_by_search(queryable, value) do
      pattern = "%" <> value <> "%"

      {queryable,
       dynamic(
         [api_request_logs: arl],
         fragment("? ILIKE ?", arl.path, ^pattern) or
           fragment("?::text ILIKE ?", arl.actor_id, ^pattern) or
           fragment("encode(?, 'hex') ILIKE ?", arl.event_id, ^pattern) or
           fragment("? ILIKE ?", arl.request_id, ^pattern)
       )}
    end

    defp filter_by_method(queryable, values) when is_list(values) and values != [] do
      {queryable, dynamic([api_request_logs: arl], arl.method in ^values)}
    end
  end
end
