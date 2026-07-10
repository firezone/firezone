defmodule PortalWeb.Logs.ChangeLogs do
  use PortalWeb, :live_view

  import PortalWeb.Logs.Components

  alias PortalWeb.Logs.JSONDiff
  alias __MODULE__.Database

  @table_id "change_logs"
  @filter_key "change_logs_filter"

  def mount(_params, _session, socket) do
    browser_tz = browser_tz_from_connect(socket)

    socket =
      socket
      |> assign(page_title: "Change Logs")
      |> assign(selected_change_log: nil, browser_tz: browser_tz)
      |> assign(tz_mode: "utc", display_tz: "Etc/UTC")
      |> assign_live_table(@table_id,
        query_module: Database,
        sortable_fields: [{:change_logs, :timestamp}, {:change_logs, :log_id}],
        callback: &handle_change_logs_update!/2
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

    case Database.fetch_change_log(log_id, socket.assigns.subject) do
      {:ok, change_log} ->
        {:noreply, assign(socket, selected_change_log: change_log)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Change log not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/change_logs")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this change log")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/logs/change_logs")}
    end
  end

  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(selected_change_log: nil)
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
       to: ~p"/#{socket.assigns.account}/logs/change_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_change_log) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/logs/change_logs?#{socket.assigns.query_params}"
     )}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_change_logs_update!(socket, list_opts) do
    list_opts = Keyword.update(list_opts, :filter, [show_system: false], &default_show_system/1)

    with {:ok, change_logs, metadata} <-
           Database.list_change_logs(socket.assigns.subject, list_opts) do
      change_logs_with_meta =
        Enum.map(change_logs, fn cl ->
          %{
            change_log: cl,
            changed_count: JSONDiff.changed_field_count(cl.before, cl.after)
          }
        end)

      {:ok,
       assign(socket,
         change_logs: change_logs_with_meta,
         change_logs_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="ri-history-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Change Logs</:title>
        <:description>
          An immutable audit trail of every configuration change in your account.
        </:description>
        <:action>
          <.docs_action path="/administer/logs" />
        </:action>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="change_logs"
          rows={@change_logs}
          row_id={&"change_log-#{&1.change_log.log_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/change_logs/#{row.change_log.log_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_change_log) and
                row.change_log.log_id == @selected_change_log.log_id
            end
          }
          filters={@filters_by_table_id["change_logs"]}
          filter={@filter_form_by_table_id["change_logs"]}
          ordered_by={@order_by_table_id["change_logs"]}
          metadata={@change_logs_metadata}
          class="flex-1 min-h-0"
          row_item={& &1}
        >
          <:col :let={row} field={{:change_logs, :timestamp}} label="Timestamp" class="w-44">
            <.timestamp_cell
              log_id={row.change_log.log_id}
              timestamp={row.change_log.timestamp}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} field={{:change_logs, :log_id}} label="Event ID" class="w-52">
            <span class="font-mono text-[10px] text-[var(--text-tertiary)] break-all">
              {row.change_log.log_id}
            </span>
          </:col>
          <:col :let={row} label="Object" class="w-44">
            <span class="font-mono text-xs text-[var(--text-primary)]">
              {row.change_log.object}
            </span>
          </:col>
          <:col :let={row} label="Actor" class="w-64">
            <.actor_cell subject={row.change_log.subject} />
          </:col>
          <:col :let={row} label="Operation" class="w-28">
            <.op_label op={row.change_log.operation} />
          </:col>
          <:col :let={row} label="Changes" class="w-24">
            <.changes_cell op={row.change_log.operation} count={row.changed_count} />
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-history-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No change logs</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Configuration changes will appear here as they happen.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.show_panel id="change-log-panel" open?={not is_nil(@selected_change_log)}>
        <:title>
          <%= if @selected_change_log do %>
            <.op_label op={@selected_change_log.operation} />
            <span class="font-mono text-sm font-semibold text-[var(--text-primary)] truncate">
              {@selected_change_log.object}
            </span>
          <% end %>
        </:title>
        <div :if={@selected_change_log} class="flex-1 flex flex-col min-h-0 overflow-auto p-5 gap-4">
          <.actor_card
            :if={not is_nil(@selected_change_log.subject)}
            name={subject_field(@selected_change_log, "actor_name")}
            email={subject_field(@selected_change_log, "actor_email")}
            type={subject_field(@selected_change_log, "actor_type")}
            fallback_id={subject_field(@selected_change_log, "actor_id")}
          />

          <section class="flex flex-col">
            <div class="flex items-center justify-between mb-2">
              <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Diff
              </div>
              <div class="text-[10px] text-[var(--text-tertiary)]">
                {diff_change_count(@selected_change_log)}
              </div>
            </div>
            <div class="rounded border border-[var(--border)] bg-[var(--surface)] p-3 max-h-[600px] overflow-auto">
              <div class="json-diff">
                <JSONDiff.diff
                  old={@selected_change_log.before}
                  new={@selected_change_log.after}
                />
              </div>
            </div>
          </section>

          <section :if={not is_nil(@selected_change_log.subject)} class="flex flex-col">
            <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-2">
              Location
            </div>
            <.location_map
              lat={subject_field(@selected_change_log, "ip_lat")}
              lon={subject_field(@selected_change_log, "ip_lon")}
            >
              <:caption>
                <div class="flex items-center justify-between gap-2 text-xs">
                  <div class="flex items-center gap-2 min-w-0">
                    <.icon
                      name="ri-map-pin-line"
                      class="w-3.5 h-3.5 shrink-0 text-[var(--text-tertiary)]"
                    />
                    <span class="text-[var(--text-primary)] truncate">
                      {change_log_location_caption(@selected_change_log)}
                    </span>
                    <span
                      :if={subject_field(@selected_change_log, "ip")}
                      class="font-mono text-[10px] text-[var(--text-tertiary)] shrink-0"
                    >
                      · {subject_field(@selected_change_log, "ip")}
                    </span>
                  </div>
                  <span
                    :if={
                      is_number(subject_field(@selected_change_log, "ip_lat")) and
                        is_number(subject_field(@selected_change_log, "ip_lon"))
                    }
                    class="font-mono text-[10px] text-[var(--text-tertiary)] tabular-nums shrink-0"
                  >
                    {format_coord(subject_field(@selected_change_log, "ip_lat"))}, {format_coord(
                      subject_field(@selected_change_log, "ip_lon")
                    )}
                  </span>
                </div>
              </:caption>
            </.location_map>
          </section>
        </div>
        <.show_panel_sidebar :if={@selected_change_log}>
          <section>
            <.section_heading label="Details" />
            <dl class="space-y-2.5">
              <.detail_row label="Timestamp">
                <.timestamp_cell
                  id_prefix="panel-timestamp"
                  log_id={@selected_change_log.log_id}
                  timestamp={@selected_change_log.timestamp}
                  tz_mode={@tz_mode}
                  display_tz={@display_tz}
                />
              </.detail_row>
              <.detail_row label="Event ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {@selected_change_log.log_id}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Identifiers" />
            <dl class="space-y-2.5">
              <.detail_row :if={subject_field(@selected_change_log, "actor_id")} label="Actor ID">
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {subject_field(@selected_change_log, "actor_id")}
                </span>
              </.detail_row>
              <.detail_row
                :if={subject_field(@selected_change_log, "auth_provider_id")}
                label="Auth provider ID"
              >
                <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                  {subject_field(@selected_change_log, "auth_provider_id")}
                </span>
              </.detail_row>
            </dl>
          </section>

          <div class="border-t border-[var(--border)]"></div>

          <section>
            <.section_heading label="Source" />
            <dl class="space-y-2.5">
              <.detail_row :if={subject_field(@selected_change_log, "ip")} label="IP address">
                <span class="font-mono text-xs text-[var(--text-primary)]">
                  {subject_field(@selected_change_log, "ip")}
                </span>
              </.detail_row>
              <.detail_row
                :if={subject_field(@selected_change_log, "user_agent")}
                label="User agent"
              >
                <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
                  {subject_field(@selected_change_log, "user_agent")}
                </span>
              </.detail_row>
            </dl>
          </section>
        </.show_panel_sidebar>
      </.show_panel>
    </div>
    """
  end

  defp subject_field(%{subject: nil}, _key), do: nil
  defp subject_field(%{subject: subject}, key), do: Map.get(subject, key)

  defp change_log_location_caption(log) do
    region_code = subject_field(log, "ip_region")
    region = if region_code, do: Portal.Geo.country_common_name!(region_code) || region_code

    case Enum.reject([subject_field(log, "ip_city"), region], &(&1 in [nil, ""])) do
      [] -> "Location unknown"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp format_coord(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 3)

  defp diff_change_count(%{operation: :update, before: before, after: aft}) do
    count = JSONDiff.changed_field_count(before, aft)
    "#{count} field#{if count != 1, do: "s"}"
  end

  defp diff_change_count(_), do: ""

  attr :op, :atom, required: true
  attr :count, :integer, required: true

  defp changes_cell(%{op: :update} = assigns) do
    ~H"""
    <span class="text-xs text-[var(--text-secondary)]">
      {@count} field{if @count != 1, do: "s"}
    </span>
    """
  end

  defp changes_cell(assigns) do
    ~H"""
    <span class="text-xs text-[var(--text-muted)]">-</span>
    """
  end

  # The `show_system` toggle is off by default, so when the URL omits the
  # filter we still want to hide entries whose subject is nil. The user
  # explicitly opts in by enabling the toggle, which adds `show_system=true`
  # to the URL and overrides this default.
  defp default_show_system(filter) do
    if Keyword.has_key?(filter, :show_system), do: filter, else: [{:show_system, false} | filter]
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.ChangeLog
    alias Portal.Safe
    alias Portal.Types.LogId

    def list_change_logs(subject, opts \\ []) do
      from(cl in ChangeLog, as: :change_logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def fetch_change_log(log_id, subject) do
      # `LogId.parse/1` is the strict 24-char-hex validator; `cast/1` only
      # checks length and would let a malformed value reach `dump/1`, which
      # then errors on base16 decode and crashes the LiveView.
      with {:ok, log_id} <- LogId.parse(log_id) do
        result =
          from(cl in ChangeLog, as: :change_logs)
          |> where([change_logs: cl], cl.log_id == ^log_id)
          |> Safe.scoped(subject, :replica)
          |> Safe.one(fallback_to_primary: true)

        case result do
          nil -> {:error, :not_found}
          {:error, :unauthorized} -> {:error, :unauthorized}
          change_log -> {:ok, change_log}
        end
      else
        :error -> {:error, :not_found}
      end
    end

    def cursor_fields, do: [{:change_logs, :desc, :log_id}]

    @object_values [
      {"Accounts", "accounts"},
      {"Actors", "actors"},
      {"API tokens", "api_tokens"},
      {"Auth providers", "auth_providers"},
      {"Client sessions", "client_sessions"},
      {"Client tokens", "client_tokens"},
      {"Devices", "devices"},
      {"Directories", "directories"},
      {"Entra auth providers", "entra_auth_providers"},
      {"Entra directories", "entra_directories"},
      {"Email OTP auth providers", "email_otp_auth_providers"},
      {"External identities", "external_identities"},
      {"Gateway sessions", "gateway_sessions"},
      {"Gateway tokens", "gateway_tokens"},
      {"Google auth providers", "google_auth_providers"},
      {"Google directories", "google_directories"},
      {"Groups", "groups"},
      {"Memberships", "memberships"},
      {"OIDC auth providers", "oidc_auth_providers"},
      {"Okta auth providers", "okta_auth_providers"},
      {"Okta directories", "okta_directories"},
      {"One-time passcodes", "one_time_passcodes"},
      {"Outbound email deliveries", "outbound_email_deliveries"},
      {"Outbound emails", "outbound_emails"},
      {"Policies", "policies"},
      {"Portal sessions", "portal_sessions"},
      {"Resources", "resources"},
      {"Sites", "sites"},
      {"Static device pool members", "static_device_pool_members"},
      {"Userpass auth providers", "userpass_auth_providers"}
    ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :actor,
          title: "Actor or event ID",
          type: {:string, :websearch},
          fun: &filter_by_actor/2
        },
        %Portal.Repo.Filter{
          name: :show_system,
          title: "Show system updates",
          type: :boolean,
          fun: &filter_show_system/2
        },
        %Portal.Repo.Filter{
          name: :operation,
          title: "Operation",
          type: :string,
          values: [
            {"Insert", "insert"},
            {"Update", "update"},
            {"Delete", "delete"}
          ],
          fun: &filter_by_operation/2
        },
        %Portal.Repo.Filter{
          name: :object,
          title: "Object",
          type: {:list, :string},
          values: @object_values,
          fun: &filter_by_object/2
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
      do: dynamic([change_logs: cl], cl.timestamp >= ^from and cl.timestamp <= ^to)

    defp timestamp_dynamic(%DateTime{} = from, nil),
      do: dynamic([change_logs: cl], cl.timestamp >= ^from)

    defp timestamp_dynamic(nil, %DateTime{} = to),
      do: dynamic([change_logs: cl], cl.timestamp <= ^to)

    # Combined search box matches against actor identity (id, name, email) and
    # the log_id of the entry itself. log_id is stored as a 12-byte bytea
    # whose canonical public form is its 24-char lowercase hex encoding, so we
    # `encode(log_id, 'hex') ILIKE ...` to support prefix searches.
    defp filter_by_actor(queryable, value) do
      pattern = "%" <> value <> "%"

      {queryable,
       dynamic(
         [change_logs: cl],
         fragment("?->>'actor_id' ILIKE ?", cl.subject, ^pattern) or
           fragment("?->>'actor_name' ILIKE ?", cl.subject, ^pattern) or
           fragment("?->>'actor_email' ILIKE ?", cl.subject, ^pattern) or
           fragment("encode(?, 'hex') ILIKE ?", cl.log_id, ^pattern)
       )}
    end

    defp filter_by_operation(queryable, value) when value in ["insert", "update", "delete"] do
      op_atom = String.to_existing_atom(value)
      {queryable, dynamic([change_logs: cl], cl.operation == ^op_atom)}
    end

    defp filter_by_object(queryable, values) when is_list(values) and values != [] do
      {queryable, dynamic([change_logs: cl], cl.object in ^values)}
    end

    defp filter_show_system(queryable, true), do: {queryable, nil}

    defp filter_show_system(queryable, false),
      do: {queryable, dynamic([change_logs: cl], not is_nil(cl.subject))}
  end
end
