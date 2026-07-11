defmodule PortalWeb.Logs.SessionLogs do
  use PortalWeb, :live_view

  import PortalWeb.Logs.Components

  alias PortalWeb.Clients
  alias __MODULE__.Database

  @table_id "session_logs"
  @filter_key "session_logs_filter"

  def mount(_params, _session, socket) do
    browser_tz = browser_tz_from_connect(socket)

    socket =
      socket
      |> assign(page_title: "Session Logs")
      |> assign(selected_log: nil, browser_tz: browser_tz)
      |> assign(tz_mode: "utc", display_tz: "Etc/UTC")
      |> assign_live_table(@table_id,
        query_module: Database,
        sortable_fields: [{:session_logs, :timestamp}, {:session_logs, :log_id}],
        callback: &handle_logs_update!/2
      )

    {:ok, socket}
  end

  def handle_params(
        %{"log_id" => log_id} = params,
        uri,
        %{assigns: %{live_action: :show}} = socket
      ) do
    socket =
      socket
      |> assign_tz(params, @filter_key)
      |> handle_live_tables_params(params, uri)

    case Database.fetch_log(log_id, socket.assigns.subject) do
      {:ok, log} ->
        {:noreply, assign(socket, selected_log: log)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Session log not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/session_logs")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this log")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/session_logs")}
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
       to: ~p"/#{socket.assigns.account}/logs/session_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_log) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/logs/session_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_logs_update!(socket, list_opts) do
    with {:ok, logs, metadata} <-
           Database.list_session_logs(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, session_logs: logs, session_logs_metadata: metadata)}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.logs_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="session_logs"
          rows={@session_logs}
          row_id={&"session-log-#{&1.log_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/session_logs/#{row.log_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_log) and row.log_id == @selected_log.log_id
            end
          }
          filters={@filters_by_table_id["session_logs"]}
          filter={@filter_form_by_table_id["session_logs"]}
          ordered_by={@order_by_table_id["session_logs"]}
          metadata={@session_logs_metadata}
          class="flex-1 min-h-0"
          row_item={& &1}
        >
          <:col :let={row} field={{:session_logs, :timestamp}} label="Timestamp" class="w-44">
            <.timestamp_cell
              log_id={row.log_id}
              timestamp={row.timestamp}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} label="Context" class="w-40">
            <div class="flex items-center gap-2 text-xs text-[var(--text-secondary)]">
              <.session_context_icon context={row.context} user_agent={ua(row)} />
              <span class="truncate">{context_label(row.context)}</span>
            </div>
          </:col>
          <:col :let={row} label="Actor" class="w-72">
            <.actor_cell subject={row.subject} />
          </:col>
          <:col :let={row} label="IP" class="w-32">
            <.ip_cell ip={subject_field(row, "ip")} />
          </:col>
          <:col :let={row} label="Location" class="w-48">
            <span class="block truncate text-xs text-[var(--text-secondary)]">
              {row_location(row)}
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-login-circle-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No sessions</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Client, Gateway, and Portal sessions will appear here as they're created.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.show_panel id="session-log-panel" open?={not is_nil(@selected_log)}>
        <:title>
          <%= if @selected_log do %>
            <.session_context_icon
              context={@selected_log.context}
              user_agent={ua(@selected_log)}
              class="w-4 h-4 text-[var(--text-secondary)]"
            />
            <span class="text-sm font-semibold text-[var(--text-primary)] truncate">
              {device_label(@selected_log)}
            </span>
          <% end %>
        </:title>
        <div
          :if={@selected_log}
          class="flex-1 flex flex-col min-h-0 overflow-auto p-5 gap-4"
        >
          <.actor_card
            :if={
              subject_field(@selected_log, "actor_name") ||
                subject_field(@selected_log, "actor_email")
            }
            name={subject_field(@selected_log, "actor_name")}
            email={subject_field(@selected_log, "actor_email")}
            type={subject_field(@selected_log, "actor_type")}
            fallback_id={subject_field(@selected_log, "actor_id")}
          />

          <section class="flex flex-col">
            <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-2">
              Location
            </div>
            <.location_map
              lat={subject_field(@selected_log, "ip_lat")}
              lon={subject_field(@selected_log, "ip_lon")}
            >
              <:caption>
                <div class="flex items-center justify-between gap-2 text-xs">
                  <div class="flex items-center gap-2 min-w-0">
                    <.icon
                      name="ri-map-pin-line"
                      class="w-3.5 h-3.5 shrink-0 text-[var(--text-tertiary)]"
                    />
                    <span class="text-[var(--text-primary)] truncate">
                      {location_caption(@selected_log)}
                    </span>
                  </div>
                  <span
                    :if={
                      is_number(subject_field(@selected_log, "ip_lat")) and
                        is_number(subject_field(@selected_log, "ip_lon"))
                    }
                    class="font-mono text-[10px] text-[var(--text-tertiary)] tabular-nums shrink-0"
                  >
                    {format_coord(subject_field(@selected_log, "ip_lat"))}, {format_coord(
                      subject_field(@selected_log, "ip_lon")
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
                  log_id={@selected_log.log_id}
                  timestamp={@selected_log.timestamp}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Event ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.log_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Identifiers" />
            <dl class="space-y-2.5">
              <.detail_row :if={subject_field(@selected_log, "actor_id")} label="Actor ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {subject_field(@selected_log, "actor_id")}
                </span>
              </.detail_row>
              <.detail_row
                :if={subject_field(@selected_log, "auth_provider_id")}
                label="Auth provider ID"
              >
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {subject_field(@selected_log, "auth_provider_id")}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Source" />
            <dl class="space-y-2.5">
              <.detail_row :if={subject_field(@selected_log, "ip")} label="IP address">
                <span class="font-mono text-xs text-[var(--text-primary)]">
                  {subject_field(@selected_log, "ip")}
                </span>
              </.detail_row>
              <.detail_row :if={ua(@selected_log)} label="User agent">
                <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
                  {ua(@selected_log)}
                </span>
              </.detail_row>
            </dl>
          </section>
        </.show_panel_sidebar>
      </.show_panel>
    </div>
    """
  end

  defp context_label(:gateway), do: "Gateway"
  defp context_label(:portal), do: "Portal"
  defp context_label(:client), do: "Client"

  defp device_label(%{context: :gateway}), do: "Gateway"
  defp device_label(%{context: :portal}), do: "Portal"

  defp device_label(%{context: :client} = log) do
    log
    |> ua()
    |> Kernel.||("")
    |> Clients.Components.get_client_os_name_and_version()
    |> String.trim()
  end

  defp ua(log), do: subject_field(log, "user_agent")

  defp subject_field(%{subject: nil}, _key), do: nil
  defp subject_field(%{subject: subject}, key), do: Map.get(subject, key)

  defp row_location(log) do
    case location_caption(log) do
      "Location unknown" -> "-"
      s -> s
    end
  end

  defp location_caption(log) do
    city = subject_field(log, "ip_city")
    region_code = subject_field(log, "ip_region")
    region = if region_code, do: Portal.Geo.country_common_name!(region_code)

    case Enum.reject([city, region], &(&1 in [nil, ""])) do
      [] -> "Location unknown"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp format_coord(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 3)
  defp format_coord(_), do: nil

  defmodule Database do
    import Ecto.Query

    alias Portal.SessionLog
    alias Portal.Safe
    alias Portal.Types.LogId

    def list_session_logs(subject, opts \\ []) do
      from(sl in SessionLog, as: :session_logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def fetch_log(log_id, subject) do
      with {:ok, log_id} <- LogId.parse(log_id) do
        result =
          from(sl in SessionLog, as: :session_logs)
          |> where([session_logs: sl], sl.log_id == ^log_id)
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
      do: [{:session_logs, :desc, :timestamp}, {:session_logs, :desc, :log_id}]

    @context_values [
      {"Client", "client"},
      {"Gateway", "gateway"},
      {"Portal", "portal"}
    ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "Actor, email, or event ID",
          type: {:string, :websearch},
          fun: &filter_by_search/2
        },
        %Portal.Repo.Filter{
          name: :context,
          title: "Context",
          type: {:list, :string},
          values: @context_values,
          fun: &filter_by_context/2
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
      do: dynamic([session_logs: sl], sl.timestamp >= ^from and sl.timestamp <= ^to)

    defp timestamp_dynamic(%DateTime{} = from, nil),
      do: dynamic([session_logs: sl], sl.timestamp >= ^from)

    defp timestamp_dynamic(nil, %DateTime{} = to),
      do: dynamic([session_logs: sl], sl.timestamp <= ^to)

    defp filter_by_search(queryable, value) do
      pattern = "%" <> value <> "%"

      {queryable,
       dynamic(
         [session_logs: sl],
         fragment("?->>'actor_id' ILIKE ?", sl.subject, ^pattern) or
           fragment("?->>'actor_email' ILIKE ?", sl.subject, ^pattern) or
           fragment("encode(?, 'hex') ILIKE ?", sl.log_id, ^pattern)
       )}
    end

    defp filter_by_context(queryable, values) when is_list(values) and values != [] do
      atoms = Enum.map(values, &String.to_existing_atom/1)
      {queryable, dynamic([session_logs: sl], sl.context in ^atoms)}
    end
  end
end
