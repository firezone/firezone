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
      {:ok, log} ->
        {:noreply, assign(socket, selected_log: log)}

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
    with {:ok, logs, metadata} <-
           Database.list_api_request_logs(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, api_request_logs: logs, api_request_logs_metadata: metadata)}
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
          One entry per authenticated REST API request, most recent first.
        </:description>
        <:action>
          <.docs_action path="/administer/logs" />
        </:action>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="api_request_logs"
          rows={@api_request_logs}
          row_id={&"api-request-log-#{&1.event_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/api_request_logs/#{row.event_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_log) and row.event_id == @selected_log.event_id
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
              event_id={row.event_id}
              timestamp={row.inserted_at}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} label="Method" class="w-24">
            <.method_badge method={row.method} />
          </:col>
          <:col :let={row} label="Path">
            <span class="font-mono text-xs text-[var(--text-primary)] break-all">
              {row.path}
            </span>
          </:col>
          <:col :let={row} label="Actor" class="w-72">
            <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
              {row.actor_id}
            </span>
          </:col>
          <:col :let={row} label="IP" class="w-36">
            <span class="font-mono text-[11px] text-[var(--text-secondary)]">
              {format_ip(row.remote_ip)}
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

      <.show_panel
        id="api-request-log-panel"
        open?={not is_nil(@selected_log)}
        title={panel_title(@selected_log)}
      >
        <div :if={@selected_log} class="flex-1 flex flex-col min-h-0 overflow-auto p-5">
          <section class="space-y-3">
            <.section_heading label="Request" />
            <div class="rounded border border-[var(--border)] bg-[var(--surface)] p-3 space-y-2">
              <div class="flex items-center gap-2">
                <.method_badge method={@selected_log.method} />
                <span class="font-mono text-sm text-[var(--text-primary)] break-all">
                  {@selected_log.path}
                </span>
              </div>
              <div :if={@selected_log.content_length} class="text-xs text-[var(--text-tertiary)]">
                Content length: {@selected_log.content_length} bytes
              </div>
            </div>
          </section>
        </div>
        <.show_panel_sidebar :if={@selected_log}>
          <section>
            <.section_heading label="Details" />
            <dl class="space-y-2.5">
              <.detail_row label="Timestamp">
                <.timestamp_cell
                  id_prefix="panel-timestamp"
                  event_id={@selected_log.event_id}
                  timestamp={@selected_log.inserted_at}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Event ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.event_id}
                </span>
              </.detail_row>
              <.detail_row label="Request ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.request_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Actor" />
            <dl class="space-y-2.5">
              <.detail_row label="Actor ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.actor_id}
                </span>
              </.detail_row>
              <.detail_row label="API token ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.api_token_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Source" />
            <dl class="space-y-2.5">
              <.detail_row label="IP">
                <span class="font-mono text-xs text-[var(--text-secondary)]">
                  {format_ip(@selected_log.remote_ip)}
                </span>
              </.detail_row>
              <.detail_row :if={ip_location(@selected_log)} label="IP location">
                <span class="text-xs text-[var(--text-primary)]">{ip_location(@selected_log)}</span>
              </.detail_row>
              <.detail_row :if={@selected_log.user_agent} label="User agent">
                <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
                  {@selected_log.user_agent}
                </span>
              </.detail_row>
            </dl>
          </section>
        </.show_panel_sidebar>
      </.show_panel>
    </div>
    """
  end

  defp panel_title(nil), do: ""
  defp panel_title(log), do: "API request event #{log.event_id}"

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

  defp format_ip(%Postgrex.INET{} = inet), do: Portal.Types.IP.to_string(inet)
  defp format_ip(_other), do: ""

  defp ip_location(%{
         remote_ip_location_city: city,
         remote_ip_location_region: region
       }) do
    [city, region]
    |> Enum.reject(&(&1 in [nil, "", "null"]))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.APIRequestLog
    alias Portal.Safe
    alias Portal.Types.EventId

    def list_api_request_logs(subject, opts \\ []) do
      from(arl in APIRequestLog, as: :api_request_logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def fetch_log(event_id, subject) do
      with {:ok, event_id} <- EventId.parse(event_id) do
        result =
          from(arl in APIRequestLog, as: :api_request_logs)
          |> where([api_request_logs: arl], arl.event_id == ^event_id)
          |> Safe.scoped(subject, :replica)
          |> Safe.one(fallback_to_primary: true)

        case result do
          nil -> {:error, :not_found}
          {:error, :unauthorized} -> {:error, :unauthorized}
          log -> {:ok, log}
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
