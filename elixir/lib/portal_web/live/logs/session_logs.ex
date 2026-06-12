defmodule PortalWeb.Logs.SessionLogs do
  use PortalWeb, :live_view

  import PortalWeb.Logs.Components

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
        sortable_fields: [{:session_logs, :timestamp}, {:session_logs, :event_id}],
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
      <.page_header>
        <:icon>
          <.icon name="ri-login-circle-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Session Logs</:title>
        <:description>
          One entry per Client, Gateway, or Portal session created.
        </:description>
        <:action>
          <.docs_action path="/administer/logs" />
        </:action>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="session_logs"
          rows={@session_logs}
          row_id={&"session-log-#{&1.event_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/session_logs/#{row.event_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_log) and row.event_id == @selected_log.event_id
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
              event_id={row.event_id}
              timestamp={row.timestamp}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} label="Context" class="w-28">
            <.context_badge context={row.context} />
          </:col>
          <:col :let={row} label="Actor" class="w-72">
            <.actor_cell subject={actor_subject(row)} />
          </:col>
          <:col :let={row} label="Device" class="w-72">
            <span class="font-mono text-[11px] text-[var(--text-tertiary)] break-all">
              {row.device_id}
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

      <.show_panel
        id="session-log-panel"
        open?={not is_nil(@selected_log)}
        title={panel_title(@selected_log)}
      >
        <div :if={@selected_log} class="flex-1 flex flex-col min-h-0 overflow-auto p-5">
          <section class="space-y-3">
            <.section_heading label="Session" />
            <div class="rounded border border-[var(--border)] bg-[var(--surface)] p-3 space-y-2">
              <div class="flex items-center gap-2">
                <.context_badge context={@selected_log.context} />
              </div>
              <div :if={@selected_log.auth_provider_id} class="text-xs text-[var(--text-tertiary)]">
                Auth provider:
                <span class="font-mono text-[var(--text-secondary)]">
                  {@selected_log.auth_provider_id}
                </span>
              </div>
              <div :if={@selected_log.token_id} class="text-xs text-[var(--text-tertiary)]">
                Token:
                <span class="font-mono text-[var(--text-secondary)]">{@selected_log.token_id}</span>
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
                  timestamp={@selected_log.timestamp}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Event ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.event_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <.subject_section subject={actor_subject(@selected_log)} />

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Device" />
            <dl class="space-y-2.5">
              <.detail_row :if={@selected_log.device_id} label="Device ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_log.device_id}
                </span>
              </.detail_row>
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
  defp panel_title(log), do: "Session event #{log.event_id}"

  # Adapt the session_log row to the shared `actor_cell` / `subject_section`
  # API, which expects a JSON-ish map keyed by string fields like change_logs.
  defp actor_subject(log) do
    %{
      "actor_id" => log.actor_id,
      "actor_email" => log.actor_email,
      "auth_provider_id" => log.auth_provider_id,
      "ip" => format_ip(log.remote_ip),
      "ip_city" => log.remote_ip_location_city,
      "ip_region" => log.remote_ip_location_region,
      "user_agent" => log.user_agent
    }
  end

  attr :context, :atom, required: true

  defp context_badge(%{context: :client} = assigns) do
    ~H"""
    <.badge type="info" class="uppercase">Client</.badge>
    """
  end

  defp context_badge(%{context: :gateway} = assigns) do
    ~H"""
    <.badge type="success" class="uppercase">Gateway</.badge>
    """
  end

  defp context_badge(%{context: :portal} = assigns) do
    ~H"""
    <.badge type="warning" class="uppercase">Portal</.badge>
    """
  end

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

    alias Portal.SessionLog
    alias Portal.Safe
    alias Portal.Types.EventId

    def list_session_logs(subject, opts \\ []) do
      from(sl in SessionLog, as: :session_logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def fetch_log(event_id, subject) do
      with {:ok, event_id} <- EventId.parse(event_id) do
        result =
          from(sl in SessionLog, as: :session_logs)
          |> where([session_logs: sl], sl.event_id == ^event_id)
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
      do: [{:session_logs, :desc, :timestamp}, {:session_logs, :desc, :event_id}]

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
         fragment("?::text ILIKE ?", sl.actor_id, ^pattern) or
           fragment("? ILIKE ?", sl.actor_email, ^pattern) or
           fragment("encode(?, 'hex') ILIKE ?", sl.event_id, ^pattern)
       )}
    end

    defp filter_by_context(queryable, values) when is_list(values) and values != [] do
      atoms = Enum.map(values, &String.to_existing_atom/1)
      {queryable, dynamic([session_logs: sl], sl.context in ^atoms)}
    end
  end
end
