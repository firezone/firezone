defmodule PortalWeb.Logs.FlowLogs do
  use PortalWeb, :live_view

  import PortalWeb.Logs.Components

  alias __MODULE__.Database

  @table_id "flow_logs"
  @filter_key "flow_logs_filter"

  def mount(_params, _session, socket) do
    browser_tz = browser_tz_from_connect(socket)

    socket =
      socket
      |> assign(page_title: "Flow Logs")
      |> assign(selected_report: nil, selected_report_json: nil, browser_tz: browser_tz)
      |> assign(tz_mode: "utc", display_tz: "Etc/UTC")
      |> assign_live_table(@table_id,
        query_module: Database,
        sortable_fields: [
          {:flow_logs, :flow_start},
          {:flow_logs, :total_bytes},
          {:flow_logs, :log_id}
        ],
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

    case Database.fetch_report(log_id, socket.assigns.subject) do
      {:ok, report} ->
        {:noreply,
         assign(socket,
           selected_report: report,
           selected_report_json: flow_log_json(report.log)
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Flow log not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/flow_logs")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this flow log")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/flow_logs")}
    end
  end

  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(selected_report: nil, selected_report_json: nil)
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
       to: ~p"/#{socket.assigns.account}/logs/flow_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_report) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/logs/flow_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", _params, socket), do: {:noreply, socket}

  def handle_logs_update!(socket, list_opts) do
    list_opts =
      Keyword.update(list_opts, :filter, [show_incomplete: false], &default_show_incomplete/1)

    with {:ok, logs, metadata} <- Database.list_flow_logs(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, flow_logs: logs, flow_logs_metadata: metadata)}
    end
  end

  defp default_show_incomplete(filter) do
    if Keyword.has_key?(filter, :show_incomplete),
      do: filter,
      else: [{:show_incomplete, false} | filter]
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.logs_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="flow_logs"
          rows={@flow_logs}
          row_id={&"flow-log-#{&1.log.log_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/flow_logs/#{row.log.log_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_report) and
                row.log.log_id == @selected_report.log.log_id
            end
          }
          row_class={&role_row_class/1}
          filters={@filters_by_table_id["flow_logs"]}
          filter={@filter_form_by_table_id["flow_logs"]}
          ordered_by={@order_by_table_id["flow_logs"]}
          metadata={@flow_logs_metadata}
          class="flex-1 min-h-0"
          row_item={& &1}
        >
          <:col :let={row} field={{:flow_logs, :flow_start}} label="Opened" class="w-44">
            <span class="sr-only">Logged by {row.log.role}</span>
            <.timestamp_cell
              log_id={row.log.log_id}
              timestamp={row.log.flow_start}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} label="Actor" class="w-64">
            <.actor_cell subject={actor_subject(row.log)} />
          </:col>
          <:col :let={row} label="Client" class="w-52">
            <.flow_client_cell
              device_name={device_name(row.initiator_device, "Deleted device")}
              ip={first_outer_src_ip(row.log)}
            />
          </:col>
          <:col :let={row} label="Resource" class="w-72">
            <.flow_resource_cell
              name={row.log.resource_name}
              domain={row.log.domain}
              protocol={row.log.protocol}
              ip={row.log.inner_dst_ip}
              port={row.log.inner_dst_port}
            />
          </:col>
          <:col :let={row} label="Duration" class="w-28">
            <.flow_state log={row.log} />
          </:col>
          <:col
            :let={row}
            field={{:flow_logs, :total_bytes}}
            label="Size"
            class="w-28"
          >
            <span
              class="font-mono text-xs tabular-nums text-[var(--text-secondary)]"
              title="Total traffic in both directions"
            >
              {format_bytes(total_bytes(row.log))}
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-exchange-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No flow logs</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Logs from initiators and responders will appear here as flows are observed.
                </p>
              </div>
            </div>
          </:empty>
          <:footer>
            <.log_sinks_notice account={@account} />
          </:footer>
        </.live_table>
      </div>

      <.show_panel id="flow-log-panel" open?={not is_nil(@selected_report)}>
        <:title>
          <%= if @selected_report do %>
            <div id="flow-log-panel-title" class="flex min-w-0 items-center gap-2 text-sm">
              <span class="truncate text-[var(--text-primary)]">
                {@selected_report.log.initiator_actor_name || "Unknown actor"}
                <span
                  :if={@selected_report.log.initiator_actor_email not in [nil, ""]}
                  class="text-[var(--text-tertiary)]"
                >
                  ({@selected_report.log.initiator_actor_email})
                </span>
              </span>
              <.icon
                name="ri-arrow-right-line"
                class="h-4 w-4 shrink-0 text-[var(--text-tertiary)]"
              />
              <span class="truncate text-[var(--text-primary)]">
                {@selected_report.log.resource_name}
              </span>
            </div>
          <% end %>
        </:title>

        <div
          :if={@selected_report}
          class="flex-1 min-w-0 overflow-y-auto p-5 space-y-5"
        >
          <.role_fieldset
            role={@selected_report.log.role}
            label="Connection details"
            hint="Directions are normalized to initiator → responder"
          >
            <div class="space-y-3">
              <div class="overflow-hidden rounded border border-[var(--border)] bg-[var(--surface)]">
                <div class="flex items-center justify-between gap-3 border-b border-[var(--border)] bg-[var(--surface-raised)] px-4 py-2">
                  <div class="flex items-center gap-2 text-xs font-medium text-[var(--text-secondary)]">
                    <.icon name="ri-shield-keyhole-line" class="h-3.5 w-3.5 text-[var(--brand)]" />
                    Inner tunnel
                  </div>
                  <span class="font-mono text-[10px] uppercase text-[var(--text-tertiary)]">
                    {@selected_report.log.protocol}
                  </span>
                </div>
                <div class="px-4 py-3">
                  <div class="flex items-center gap-3 min-w-0">
                    <div class="min-w-0 flex-1">
                      <div class="text-xs text-[var(--text-tertiary)]">
                        Initiator
                      </div>
                      <div class="mt-1 truncate font-mono text-xs text-[var(--text-primary)]">
                        {format_endpoint(
                          @selected_report.log.inner_src_ip,
                          @selected_report.log.inner_src_port
                        )}
                      </div>
                    </div>
                    <.icon name="ri-arrow-right-line" class="w-4 h-4 shrink-0 text-[var(--brand)]" />
                    <div class="min-w-0 flex-1 text-right">
                      <div class="truncate text-xs text-[var(--text-tertiary)]">
                        {destination_label(@selected_report.log)}
                      </div>
                      <div class="mt-1 truncate font-mono text-xs text-[var(--text-primary)]">
                        {format_endpoint(
                          @selected_report.log.inner_dst_ip,
                          @selected_report.log.inner_dst_port
                        )}
                      </div>
                    </div>
                  </div>
                  <div
                    :if={@selected_report.log.domain}
                    class="mt-3 pt-3 border-t border-[var(--border)] text-xs text-[var(--text-secondary)]"
                  >
                    Resolved domain:
                    <span class="font-mono text-[var(--text-primary)]">
                      {@selected_report.log.domain}
                    </span>
                  </div>
                </div>
              </div>

              <div class="overflow-hidden rounded border border-[var(--border)] bg-[var(--surface)]">
                <div class="flex items-center justify-between gap-3 border-b border-[var(--border)] bg-[var(--surface-raised)] px-4 py-2">
                  <div class="flex items-center gap-2 text-xs font-medium text-[var(--text-secondary)]">
                    <.icon name="ri-time-line" class="h-3.5 w-3.5 text-[var(--brand)]" />
                    Timing and traffic
                  </div>
                  <.flow_state log={@selected_report.log} />
                </div>
                <div class="space-y-3 px-4 py-3">
                  <dl class="grid grid-cols-3 gap-x-4 gap-y-2">
                    <.detail_row label="Started">
                      <.timestamp_cell
                        id_prefix="panel-start"
                        log_id={@selected_report.log.log_id}
                        timestamp={@selected_report.log.flow_start}
                        tz_mode={@tz_mode}
                        display_tz={@display_tz}
                      />
                    </.detail_row>
                    <.detail_row label="Ended">
                      <.timestamp_cell
                        :if={@selected_report.log.flow_end}
                        id_prefix="panel-end"
                        log_id={@selected_report.log.log_id}
                        timestamp={@selected_report.log.flow_end}
                        tz_mode={@tz_mode}
                        display_tz={@display_tz}
                      />
                      <span
                        :if={is_nil(@selected_report.log.flow_end)}
                        class="text-xs text-[var(--text-tertiary)]"
                      >
                        Open
                      </span>
                    </.detail_row>
                    <.detail_row label="Last packet">
                      <.timestamp_cell
                        :if={@selected_report.log.last_packet}
                        id_prefix="panel-packet"
                        log_id={@selected_report.log.log_id}
                        timestamp={@selected_report.log.last_packet}
                        tz_mode={@tz_mode}
                        display_tz={@display_tz}
                      />
                      <span
                        :if={is_nil(@selected_report.log.last_packet)}
                        class="text-xs text-[var(--text-tertiary)]"
                      >
                        -
                      </span>
                    </.detail_row>
                  </dl>

                  <div class="grid grid-cols-2 gap-2">
                    <.metric
                      label="Initiator → responder"
                      value={format_bytes(@selected_report.log.tx_bytes)}
                      secondary={format_packets(@selected_report.log.tx_packets)}
                    />
                    <.metric
                      label="Responder → initiator"
                      value={format_bytes(@selected_report.log.rx_bytes)}
                      secondary={format_packets(@selected_report.log.rx_packets)}
                    />
                  </div>
                </div>
              </div>

              <.outer_path_history
                id={"flow-log-path-history-#{@selected_report.log.log_id}"}
                log_id={@selected_report.log.log_id}
                outers={@selected_report.log.outers}
                tz_mode={@tz_mode}
                display_tz={@display_tz}
              />
            </div>
          </.role_fieldset>

          <.role_fieldset
            role={counterpart_role(@selected_report.log.role)}
            label={matching_heading(@selected_report.matching_logs)}
          >
            <.match_notice
              matching_logs={@selected_report.matching_logs}
              selected_role={@selected_report.log.role}
            />
            <div :if={@selected_report.matching_logs != []} class="mt-2 space-y-2">
              <.matching_log_card
                :for={log <- @selected_report.matching_logs}
                log={log}
                path={~p"/#{@account}/logs/flow_logs/#{log.log_id}?#{@query_params}"}
                tz_mode={@tz_mode}
                display_tz={@display_tz}
              />
            </div>
          </.role_fieldset>

          <.json_view id="flow-log-json" value={@selected_report_json} label="Flow log JSON" />
        </div>

        <.show_panel_sidebar :if={@selected_report}>
          <section>
            <.section_heading label="Log details" />
            <dl class="space-y-2.5">
              <.detail_row label="Logged by">
                <div class="flex items-center gap-2">
                  <.role_badge role={@selected_report.log.role} />
                  <span class="truncate text-xs text-[var(--text-secondary)]">
                    {reporter_device_name(@selected_report)}
                  </span>
                </div>
              </.detail_row>
              <.detail_row label="Received">
                <.timestamp_cell
                  id_prefix="panel-received"
                  log_id={@selected_report.log.log_id}
                  timestamp={@selected_report.log.inserted_at}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Log ID">
                <.identifier value={@selected_report.log.log_id} />
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Devices and resource" />
            <dl class="space-y-2.5">
              <.detail_row label="Actor">
                <div class="text-xs text-[var(--text-primary)]">
                  {@selected_report.log.initiator_actor_name}
                </div>
                <div
                  :if={@selected_report.log.initiator_actor_email}
                  class="truncate text-xs text-[var(--text-tertiary)]"
                >
                  {@selected_report.log.initiator_actor_email}
                </div>
              </.detail_row>
              <.detail_row label="Initiator device">
                <div class="text-xs text-[var(--text-secondary)]">
                  {device_name(@selected_report.initiator_device, "Deleted device")}
                </div>
                <.identifier value={@selected_report.log.initiator_device_id} />
              </.detail_row>
              <.detail_row label="Responder device">
                <div class="text-xs text-[var(--text-secondary)]">
                  {device_name(@selected_report.responder_device, "Deleted responder")}
                </div>
                <.identifier value={@selected_report.log.responder_device_id} />
              </.detail_row>
              <.detail_row label="Resource">
                <div class="text-xs text-[var(--text-primary)]">
                  {@selected_report.log.resource_name}
                </div>
                <div
                  :if={@selected_report.log.resource_address}
                  class="truncate font-mono text-xs text-[var(--text-tertiary)]"
                >
                  {@selected_report.log.resource_address}
                </div>
                <.identifier value={@selected_report.log.resource_id} />
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Authorization" />
            <dl class="space-y-2.5">
              <.detail_row label="Authorization ID">
                <.identifier value={@selected_report.log.policy_authorization_id} />
              </.detail_row>
              <.detail_row label="Policy ID">
                <.identifier value={@selected_report.log.policy_id} />
              </.detail_row>
              <.detail_row label="Authorized">
                <.timestamp_cell
                  id_prefix="panel-authorized"
                  log_id={@selected_report.log.log_id}
                  timestamp={@selected_report.log.authorized_at}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Expires">
                <.timestamp_cell
                  id_prefix="panel-expires"
                  log_id={@selected_report.log.log_id}
                  timestamp={@selected_report.log.authorization_expires_at}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
            </dl>
          </section>

          <div
            :if={has_client_telemetry?(@selected_report.log)}
            class="border-t border-[var(--border)]"
          >
          </div>

          <section :if={has_client_telemetry?(@selected_report.log)}>
            <.section_heading label="Initiator device details" />
            <dl class="space-y-2.5">
              <.detail_row :if={@selected_report.log.initiator_client_version} label="Client">
                <.detail_value value={@selected_report.log.initiator_client_version} />
              </.detail_row>
              <.detail_row :if={@selected_report.log.initiator_device_os_name} label="Operating system">
                <.detail_value value={os_label(@selected_report.log)} />
              </.detail_row>
              <.detail_row :if={@selected_report.log.initiator_device_serial} label="Serial">
                <.identifier value={@selected_report.log.initiator_device_serial} />
              </.detail_row>
              <.detail_row :if={@selected_report.log.initiator_device_uuid} label="Device UUID">
                <.identifier value={@selected_report.log.initiator_device_uuid} />
              </.detail_row>
              <.detail_row
                :if={@selected_report.log.initiator_device_identifier_for_vendor}
                label="Vendor identifier"
              >
                <.identifier value={@selected_report.log.initiator_device_identifier_for_vendor} />
              </.detail_row>
              <.detail_row
                :if={@selected_report.log.initiator_device_firebase_installation_id}
                label="Firebase installation"
              >
                <.identifier value={
                  @selected_report.log.initiator_device_firebase_installation_id
                } />
              </.detail_row>
              <.detail_row :if={@selected_report.log.initiator_auth_provider_id} label="Auth provider ID">
                <.identifier value={@selected_report.log.initiator_auth_provider_id} />
              </.detail_row>
            </dl>
          </section>
        </.show_panel_sidebar>
      </.show_panel>
    </div>
    """
  end

  attr :role, :atom, required: true

  defp role_badge(assigns) do
    ~H"""
    <.badge type={if(@role == :initiator, do: "primary", else: "accent")} size="xs">
      {if(@role == :initiator, do: "Initiator", else: "Responder")}
    </.badge>
    """
  end

  attr :role, :atom, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  slot :inner_block, required: true

  defp role_fieldset(assigns) do
    ~H"""
    <fieldset class={["rounded-lg border px-4 pb-4 pt-3", role_fieldset_class(@role)]}>
      <legend class={[
        "px-1.5 text-[10px] font-semibold uppercase tracking-widest",
        role_legend_class(@role)
      ]}>
        {@label}
      </legend>
      <p :if={@hint} class="mb-3 text-[10px] text-[var(--text-tertiary)]">{@hint}</p>
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  attr :log, :any, required: true

  defp flow_state(assigns) do
    assigns = assign(assigns, :skew?, clock_skew?(assigns.log))

    ~H"""
    <.badge :if={is_nil(@log.flow_end)} type="info" size="xs">Incomplete</.badge>
    <.badge
      :if={@skew?}
      type="warning"
      size="xs"
      title="The reported flow end time is earlier than its start time, usually because the reporting device's clock changed or was out of sync."
    >
      Clock skew
    </.badge>
    <span
      :if={not is_nil(@log.flow_end) and not @skew?}
      class="text-xs tabular-nums text-[var(--text-secondary)]"
    >
      {format_duration(@log.flow_start, @log.flow_end)}
    </span>
    """
  end

  attr :matching_logs, :list, required: true
  attr :selected_role, :atom, required: true

  defp match_notice(assigns) do
    assigns =
      assign(assigns,
        count: length(assigns.matching_logs),
        other_role: to_string(counterpart_role(assigns.selected_role))
      )

    ~H"""
    <div
      :if={@count == 0}
      class="flex items-center gap-2 rounded border border-[var(--border)] bg-[var(--surface-raised)] px-3 py-2 text-xs text-[var(--text-secondary)]"
    >
      <.icon name="ri-information-line" class="h-4 w-4 shrink-0 text-[var(--brand)]" />
      <span>
        No matching {@other_role} log was found. It may still be open, delayed, dropped, or beyond
        the retention period.
      </span>
    </div>
    <div
      :if={@count == 1}
      class="flex items-center gap-2 rounded border border-[var(--border)] bg-[var(--surface-raised)] px-3 py-2 text-xs text-[var(--text-secondary)]"
    >
      <.icon name="ri-link" class="h-4 w-4 shrink-0 text-[var(--brand)]" />
      <span>
        Flow logs are paired on a best-effort basis.
        <.link
          href="https://www.firezone.dev/kb/audit-logs/flow#two-sided-reporting"
          target="_blank"
          rel="noopener noreferrer"
          class="font-medium text-[var(--brand)] hover:underline"
        >
          Read more
        </.link>
      </span>
    </div>
    <div
      :if={@count > 1}
      class="flex items-center gap-2 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-900/40 dark:bg-amber-950/30 dark:text-amber-200"
    >
      <.icon name="ri-alert-line" class="h-4 w-4 shrink-0" />
      <span>
        Multiple {@other_role} logs have the same flow details and overlapping time windows. Up to
        the three closest matches are shown; none can be selected with certainty.
      </span>
    </div>
    """
  end

  attr :log, :any, required: true
  attr :path, :string, required: true
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true

  defp matching_log_card(assigns) do
    ~H"""
    <.link
      id={"flow-log-match-#{@log.log_id}"}
      patch={@path}
      data-role={@log.role}
      class="block overflow-hidden rounded border border-[var(--border)] bg-[var(--surface)] transition-colors hover:border-[var(--brand)]/50"
    >
      <div class="flex items-center justify-between gap-3 border-b border-[var(--border)] bg-[var(--surface-raised)] px-3 py-2">
        <div class="flex min-w-0 items-center gap-2">
          <.role_badge role={@log.role} />
          <.flow_state log={@log} />
        </div>
        <span class="inline-flex shrink-0 items-center gap-1 text-xs text-[var(--brand)]">
          View log <.icon name="ri-arrow-right-line" class="h-3 w-3" />
        </span>
      </div>
      <div class="px-3 py-2.5">
        <dl class="grid grid-cols-2 gap-x-4 gap-y-2 xl:grid-cols-4">
          <.detail_row label="Started">
            <.timestamp_cell
              id_prefix="match-start"
              log_id={@log.log_id}
              timestamp={@log.flow_start}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </.detail_row>
          <.detail_row label="Ended">
            <.timestamp_cell
              :if={@log.flow_end}
              id_prefix="match-end"
              log_id={@log.log_id}
              timestamp={@log.flow_end}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
            <span :if={is_nil(@log.flow_end)} class="text-xs text-[var(--text-tertiary)]">Open</span>
          </.detail_row>
          <.detail_row label="Traffic">
            <span class="font-mono text-xs tabular-nums text-[var(--text-secondary)]">
              {format_bytes(total_bytes(@log))}
            </span>
          </.detail_row>
          <.detail_row label="Log ID">
            <.identifier value={@log.log_id} />
          </.detail_row>
        </dl>
      </div>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :log_id, :string, required: true
  attr :outers, :list, required: true
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true

  defp outer_path_history(assigns) do
    assigns = assign(assigns, :path_count, length(assigns.outers))

    ~H"""
    <div id={@id} class="overflow-hidden rounded border border-[var(--border)] bg-[var(--surface)]">
      <div class="flex items-center justify-between gap-3 border-b border-[var(--border)] bg-[var(--surface-raised)] px-4 py-2">
        <div class="flex items-center gap-2 text-xs font-medium text-[var(--text-secondary)]">
          <.icon name="ri-route-line" class="h-3.5 w-3.5 text-[var(--brand)]" />
          WireGuard path history
        </div>
        <.badge :if={@path_count > 0} type="neutral" size="xs">
          {@path_count} {if(@path_count == 1, do: "path", else: "paths")}
        </.badge>
      </div>

      <div class="px-4 py-3">
        <div
          :if={@path_count == 0}
          class="flex items-center gap-2 rounded bg-[var(--surface-raised)] px-3 py-2 text-xs text-[var(--text-tertiary)]"
        >
          <.icon name="ri-time-line" class="h-3.5 w-3.5 shrink-0" />
          Paths are reported when the flow closes.
        </div>

        <div :if={@path_count > 0} class="mb-2 text-[10px] text-[var(--text-tertiary)]">
          Ordered from first to last observed
        </div>

        <ol :if={@path_count > 0} class="space-y-2" aria-label="WireGuard path history">
          <li
            :for={{outer, index} <- Enum.with_index(@outers, 1)}
            data-wireguard-path={index}
            class="relative flex gap-3 pb-2 last:pb-0"
          >
            <div class="relative flex w-6 shrink-0 justify-center">
              <span
                :if={index < @path_count}
                class="absolute left-1/2 top-6 -bottom-2 w-px -translate-x-1/2 bg-[var(--border)]"
              >
              </span>
              <span class="relative z-10 inline-flex h-6 w-6 items-center justify-center rounded-full border border-brand/30 bg-brand-subtle font-mono text-[10px] font-semibold text-brand">
                {index}
              </span>
            </div>

            <div class="min-w-0 flex-1 rounded border border-[var(--border)] bg-[var(--surface-raised)] px-3 py-2.5">
              <div class="mb-2 flex items-center justify-between gap-2">
                <div class="text-[10px] font-medium uppercase tracking-wide text-[var(--text-tertiary)]">
                  {if(index == 1, do: "Initial path", else: "Path change")}
                </div>
                <.timestamp_cell
                  :if={outer.path_activated_at}
                  id_prefix={"path-activated-#{index}"}
                  log_id={@log_id}
                  timestamp={outer.path_activated_at}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </div>
              <div class="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-2">
                <div class="min-w-0">
                  <div class="text-[10px] text-[var(--text-tertiary)]">Initiator</div>
                  <div
                    :if={outer.src_ip}
                    data-wireguard-endpoint="initiator"
                    class="mt-0.5 break-all font-mono text-xs text-[var(--text-primary)]"
                  >
                    {format_endpoint(outer.src_ip, outer.src_port)}
                  </div>
                  <div
                    :if={is_nil(outer.src_ip)}
                    data-wireguard-endpoint="initiator"
                    class="mt-0.5 text-xs italic text-[var(--text-tertiary)]"
                  >
                    Not observed
                  </div>
                </div>
                <.icon name="ri-arrow-right-line" class="h-4 w-4 shrink-0 text-[var(--brand)]" />
                <div class="min-w-0 text-right">
                  <div class="text-[10px] text-[var(--text-tertiary)]">Responder</div>
                  <div
                    data-wireguard-endpoint="responder"
                    class="mt-0.5 break-all font-mono text-xs text-[var(--text-primary)]"
                  >
                    {format_endpoint(outer.dst_ip, outer.dst_port)}
                  </div>
                </div>
              </div>
            </div>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :secondary, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div class="rounded bg-[var(--surface-raised)] px-3 py-2">
      <div class="text-xs text-[var(--text-tertiary)]">{@label}</div>
      <div class="mt-1 font-mono text-xs text-[var(--text-primary)]">{@value}</div>
      <div class="font-mono text-xs text-[var(--text-tertiary)]">{@secondary}</div>
    </div>
    """
  end

  attr :value, :any, required: true

  defp identifier(assigns) do
    ~H"""
    <span class="block font-mono text-xs text-[var(--text-secondary)] break-all">
      {@value}
    </span>
    """
  end

  attr :value, :any, required: true

  defp detail_value(assigns) do
    ~H"""
    <span class="text-xs text-[var(--text-secondary)]">{@value}</span>
    """
  end

  defp matching_heading([_, _ | _]), do: "Matching logs"
  defp matching_heading(_matching_logs), do: "Matching log"

  defp counterpart_role(:initiator), do: :responder
  defp counterpart_role(:responder), do: :initiator

  defp role_fieldset_class(:initiator), do: "border-brand/40"
  defp role_fieldset_class(:responder), do: "border-accent/40 dark:border-accent-light/50"

  defp role_legend_class(:initiator), do: "text-brand"
  defp role_legend_class(:responder), do: "text-accent dark:text-accent-light"

  defp role_row_class(%{log: %{role: :initiator}}),
    do:
      "!bg-brand/[0.025] hover:!bg-brand/[0.04] dark:!bg-brand/[0.04] dark:hover:!bg-brand/[0.06]"

  defp role_row_class(%{log: %{role: :responder}}),
    do:
      "!bg-accent/[0.025] hover:!bg-accent/[0.04] dark:!bg-accent/[0.04] dark:hover:!bg-accent/[0.06]"

  defp actor_subject(log) do
    %{
      "actor_name" => log.initiator_actor_name,
      "actor_email" => log.initiator_actor_email
    }
  end

  defp destination_label(log), do: log.domain || log.resource_name

  defp flow_log_json(log) do
    log
    |> PortalAPI.Render.data(schema: PortalAPI.Schemas.Log.Flow)
    |> JSON.encode!()
    |> JSON.decode!()
  end

  defp reporter_device_name(%{log: %{role: :initiator}, initiator_device: device}),
    do: device_name(device, "Deleted device")

  defp reporter_device_name(%{log: %{role: :responder}, responder_device: device}),
    do: device_name(device, "Deleted responder")

  defp device_name(%{name: name}, _fallback) when name not in [nil, ""], do: name
  defp device_name(_, fallback), do: fallback

  defp first_outer_src_ip(%{outers: [%{src_ip: src_ip} | _]}), do: src_ip
  defp first_outer_src_ip(_log), do: nil

  defp format_duration(started_at, ended_at) do
    seconds = DateTime.diff(ended_at, started_at, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
    end
  end

  defp clock_skew?(%{flow_end: nil}), do: false

  defp clock_skew?(%{flow_start: started_at, flow_end: ended_at}),
    do: DateTime.compare(ended_at, started_at) == :lt

  defp format_bytes(nil), do: "-"
  defp format_bytes(bytes) when bytes < 1_000, do: "#{bytes} B"

  defp format_bytes(bytes) do
    {value, unit} =
      cond do
        bytes < 1_000_000 -> {bytes / 1_000, "KB"}
        bytes < 1_000_000_000 -> {bytes / 1_000_000, "MB"}
        bytes < 1_000_000_000_000 -> {bytes / 1_000_000_000, "GB"}
        true -> {bytes / 1_000_000_000_000, "TB"}
      end

    formatted =
      if value >= 100,
        do: :erlang.float_to_binary(value, decimals: 0),
        else: :erlang.float_to_binary(value, decimals: 1)

    "#{formatted} #{unit}"
  end

  defp format_packets(nil), do: "No final packet count"
  defp format_packets(1), do: "1 packet"
  defp format_packets(count), do: "#{count} packets"

  defp total_bytes(%{tx_bytes: nil, rx_bytes: nil}), do: nil

  defp total_bytes(log),
    do: (log.tx_bytes || 0) + (log.rx_bytes || 0)

  defp has_client_telemetry?(log) do
    Enum.any?(
      [
        log.initiator_client_version,
        log.initiator_device_os_name,
        log.initiator_device_os_version,
        log.initiator_device_serial,
        log.initiator_device_uuid,
        log.initiator_device_identifier_for_vendor,
        log.initiator_device_firebase_installation_id,
        log.initiator_auth_provider_id
      ],
      &(&1 not in [nil, ""])
    )
  end

  defp os_label(log) do
    [log.initiator_device_os_name, log.initiator_device_os_version]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Device
    alias Portal.FlowLog
    alias Portal.Safe
    alias Portal.Types.LogId

    @candidate_limit 3

    def list_flow_logs(subject, opts \\ []) do
      {query, opts} =
        from(fl in FlowLog, as: :flow_logs)
        |> apply_total_bytes_order(opts)

      result =
        query
        |> Safe.scoped(subject)
        |> Safe.list_offset(__MODULE__, Keyword.put(opts, :order_by_nulls, :natural))

      case result do
        {:ok, logs, metadata} -> {:ok, enrich(logs, subject), metadata}
        other -> other
      end
    end

    defp apply_total_bytes_order(queryable, opts) do
      order_by = Keyword.get(opts, :order_by, [])

      case Enum.find(
             order_by,
             &match?(
               {:flow_logs, direction, :total_bytes} when direction in [:asc, :desc],
               &1
             )
           ) do
        nil ->
          {queryable, opts}

        {:flow_logs, direction, :total_bytes} ->
          remaining_order =
            Enum.reject(order_by, &match?({:flow_logs, _, :total_bytes}, &1))

          queryable = order_by_total_bytes(queryable, direction)
          {queryable, Keyword.put(opts, :order_by, remaining_order)}
      end
    end

    defp order_by_total_bytes(queryable, :asc) do
      order_by(
        queryable,
        [flow_logs: fl],
        asc_nulls_last:
          fragment(
            "CASE WHEN ? IS NULL AND ? IS NULL THEN NULL ELSE COALESCE(?::numeric, 0) + COALESCE(?::numeric, 0) END",
            fl.tx_bytes,
            fl.rx_bytes,
            fl.tx_bytes,
            fl.rx_bytes
          )
      )
    end

    defp order_by_total_bytes(queryable, :desc) do
      order_by(
        queryable,
        [flow_logs: fl],
        desc_nulls_last:
          fragment(
            "CASE WHEN ? IS NULL AND ? IS NULL THEN NULL ELSE COALESCE(?::numeric, 0) + COALESCE(?::numeric, 0) END",
            fl.tx_bytes,
            fl.rx_bytes,
            fl.tx_bytes,
            fl.rx_bytes
          )
      )
    end

    def fetch_report(log_id, subject) do
      with {:ok, log_id} <- LogId.parse(log_id),
           %FlowLog{} = log <- fetch_log(log_id, subject),
           matching_logs when is_list(matching_logs) <- matching_logs(log, subject) do
        [report] = enrich([log], subject)
        {:ok, Map.put(report, :matching_logs, matching_logs)}
      else
        :error -> {:error, :not_found}
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
      end
    end

    def cursor_fields,
      do: [{:flow_logs, :desc, :flow_start}, {:flow_logs, :desc, :log_id}]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "actor, resource, IP, or log ID",
          type: {:string, :websearch_wide},
          fun: &filter_by_search/2
        },
        %Portal.Repo.Filter{
          name: :role,
          title: "Logged by",
          type: :string,
          values: [{"Initiator", "initiator"}, {"Responder", "responder"}],
          fun: &filter_by_role/2
        },
        %Portal.Repo.Filter{
          name: :protocol_port,
          title: "Protocol / port",
          type: {:string, :protocol_port},
          fun: &filter_by_protocol_port/2
        },
        %Portal.Repo.Filter{
          name: :show_incomplete,
          title: "Show incomplete",
          type: :boolean,
          fun: &filter_show_incomplete/2
        },
        %Portal.Repo.Filter{
          name: :timestamp,
          title: "Flow started",
          type: {:range, :datetime},
          fun: &filter_by_timestamp/2
        }
      ]
    end

    defp fetch_log(log_id, subject) do
      from(fl in FlowLog, as: :flow_logs, where: fl.log_id == ^log_id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    # Both devices normalize the inner tuple to initiator -> responder. Exact
    # attribution, protocol, inner tuple, and domain equality plus an
    # overlapping time window narrows the matches, but cannot prove identity
    # because independently created logs have no shared flow ID.
    #
    # Only fields both sides can agree on are matched, and the WireGuard tuple
    # is not one of them: each side records the path from its own vantage point
    # (its own bound socket address and the peer address it observes), so NAT on
    # either end, or a relay in between, leaves the two sides disagreeing on
    # every outer address in the common case.
    defp matching_logs(log, subject) do
      opposite_role = if log.role == :initiator, do: :responder, else: :initiator
      {selected_min, selected_max} = normalized_bounds(log)

      query =
        from(candidate in FlowLog,
          as: :flow_logs,
          where: candidate.role == ^opposite_role,
          where: candidate.policy_authorization_id == ^log.policy_authorization_id,
          where: candidate.initiator_device_id == ^log.initiator_device_id,
          where: candidate.responder_device_id == ^log.responder_device_id,
          where: candidate.resource_id == ^log.resource_id,
          where: candidate.protocol == ^log.protocol,
          where: candidate.inner_src_ip == ^log.inner_src_ip,
          where: candidate.inner_src_port == ^log.inner_src_port,
          where: candidate.inner_dst_port == ^log.inner_dst_port,
          where:
            is_nil(candidate.flow_end) or
              ^selected_min <= fragment("GREATEST(?, ?)", candidate.flow_start, candidate.flow_end),
          order_by:
            fragment(
              "abs(extract(epoch from (? - ?)))",
              candidate.flow_start,
              ^log.flow_start
            ),
          limit: @candidate_limit
        )
        |> filter_candidate_inner_dst_ip(log)
        |> filter_candidate_domain(log.domain)
        |> filter_candidate_upper_bound(selected_max)

      query
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp normalized_bounds(%{flow_start: started_at, flow_end: nil}), do: {started_at, nil}

    defp normalized_bounds(%{flow_start: started_at, flow_end: ended_at}) do
      if DateTime.compare(started_at, ended_at) == :gt,
        do: {ended_at, started_at},
        else: {started_at, ended_at}
    end

    # A flow to a DNS Resource is addressed to the proxy IP the Client assigned
    # to the domain, and the Gateway swaps that for the IP it resolved before
    # forwarding, so the two sides never agree on the destination. Their shared
    # domain identifies the destination instead.
    defp filter_candidate_inner_dst_ip(query, %{domain: nil} = log),
      do: where(query, [flow_logs: candidate], candidate.inner_dst_ip == ^log.inner_dst_ip)

    defp filter_candidate_inner_dst_ip(query, _log), do: query

    defp filter_candidate_domain(query, nil),
      do: where(query, [flow_logs: candidate], is_nil(candidate.domain))

    defp filter_candidate_domain(query, domain),
      do: where(query, [flow_logs: candidate], candidate.domain == ^domain)

    defp filter_candidate_upper_bound(query, nil), do: query

    defp filter_candidate_upper_bound(query, selected_max) do
      where(
        query,
        [flow_logs: candidate],
        fragment("LEAST(?, COALESCE(?, ?))", candidate.flow_start, candidate.flow_end, candidate.flow_start) <=
          ^selected_max
      )
    end

    defp enrich([], _subject), do: []

    defp enrich(logs, subject) do
      device_ids =
        logs
        |> Enum.flat_map(&[&1.initiator_device_id, &1.responder_device_id])
        |> Enum.uniq()

      devices_by_id =
        from(device in Device, where: device.id in ^device_ids)
        |> Safe.scoped(subject)
        |> Safe.all()
        |> case do
          devices when is_list(devices) -> Map.new(devices, &{&1.id, &1})
          _ -> %{}
        end

      Enum.map(logs, fn log ->
        %{
          log: log,
          initiator_device: Map.get(devices_by_id, log.initiator_device_id),
          responder_device: Map.get(devices_by_id, log.responder_device_id)
        }
      end)
    end

    defp filter_by_timestamp(queryable, %Portal.Repo.Filter.Range{from: from, to: to}) do
      {queryable, timestamp_dynamic(from, to)}
    end

    # Keep the partition key bare in these predicates so PostgreSQL can prune
    # the daily flow_start partitions selected by the UI's explicit Started
    # filter.
    defp timestamp_dynamic(%DateTime{} = from, %DateTime{} = to),
      do: dynamic([flow_logs: fl], fl.flow_start >= ^from and fl.flow_start <= ^to)

    defp timestamp_dynamic(%DateTime{} = from, nil),
      do: dynamic([flow_logs: fl], fl.flow_start >= ^from)

    defp timestamp_dynamic(nil, %DateTime{} = to),
      do: dynamic([flow_logs: fl], fl.flow_start <= ^to)

    defp filter_by_search(queryable, value) do
      pattern = "%" <> value <> "%"

      {queryable,
       dynamic(
         [flow_logs: fl],
         fragment("? ILIKE ?", fl.initiator_actor_name, ^pattern) or
           fragment("? ILIKE ?", fl.initiator_actor_email, ^pattern) or
           fragment("? ILIKE ?", fl.resource_name, ^pattern) or
           fragment("? ILIKE ?", fl.resource_address, ^pattern) or
           fragment("? ILIKE ?", fl.domain, ^pattern) or
           fragment("?::text ILIKE ?", fl.inner_src_ip, ^pattern) or
           fragment("?::text ILIKE ?", fl.inner_dst_ip, ^pattern) or
           fragment("?::text ILIKE ?", fl.outers, ^pattern) or
           fragment("encode(?, 'hex') ILIKE ?", fl.log_id, ^pattern)
       )}
    end

    defp filter_by_role(queryable, values) when is_list(values) and values != [] do
      roles = Enum.map(values, &String.to_existing_atom/1)
      {queryable, dynamic([flow_logs: fl], fl.role in ^roles)}
    end

    defp filter_by_role(queryable, value) when value in ["initiator", "responder"],
      do: filter_by_role(queryable, [value])

    defp filter_by_protocol_port(queryable, value) do
      dynamic =
        case parse_protocol_port(value) do
          {:port, port} ->
            dynamic([flow_logs: fl], fl.inner_dst_port == ^port)

          {:protocol, protocol} ->
            dynamic([flow_logs: fl], fl.protocol == ^protocol)

          {:protocol_port, protocol, port} ->
            dynamic(
              [flow_logs: fl],
              fl.protocol == ^protocol and fl.inner_dst_port == ^port
            )

          :error ->
            dynamic(false)
        end

      {queryable, dynamic}
    end

    defp parse_protocol_port(value) do
      value = value |> String.trim() |> String.downcase()

      case String.split(value, ~r{[/:]}, parts: 2) do
        [protocol, port] when protocol in ["tcp", "udp"] ->
          with {:ok, port} <- parse_port(port) do
            {:protocol_port, protocol_atom(protocol), port}
          end

        [protocol] when protocol in ["tcp", "udp"] ->
          {:protocol, protocol_atom(protocol)}

        [port] ->
          case parse_port(port) do
            {:ok, port} -> {:port, port}
            :error -> :error
          end

        _other ->
          :error
      end
    end

    defp parse_port(value) do
      case Integer.parse(value) do
        {port, ""} when port in 0..65_535 -> {:ok, port}
        _other -> :error
      end
    end

    defp protocol_atom("tcp"), do: :tcp
    defp protocol_atom("udp"), do: :udp

    defp filter_show_incomplete(queryable, true), do: {queryable, nil}

    defp filter_show_incomplete(queryable, false),
      do: {queryable, dynamic([flow_logs: fl], not is_nil(fl.flow_end))}
  end
end
