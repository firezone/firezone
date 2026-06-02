defmodule PortalWeb.Logs.ChangeLogs do
  use PortalWeb, :live_view

  alias PortalWeb.Logs.JSONDiff
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    browser_tz = browser_tz_from_connect(socket)

    socket =
      socket
      |> assign(page_title: "Change Logs")
      |> assign(selected_change_log: nil, browser_tz: browser_tz)
      |> assign(tz_mode: "utc", display_tz: "Etc/UTC")
      |> assign_live_table("change_logs",
        query_module: Database,
        sortable_fields: [{:change_logs, :timestamp}, {:change_logs, :event_id}],
        callback: &handle_change_logs_update!/2
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
      |> assign_tz(params)
      |> handle_live_tables_params(params, uri)

    case Database.fetch_change_log(event_id, socket.assigns.subject) do
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
      |> assign_tz(params)
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
          <.icon name="ri-file-list-3-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Logs</:title>
        <:description>
          Audit logs related to configuration changes and network activity in your organization.
        </:description>
        <:action>
          <.docs_action path="/administer/logs" />
        </:action>
      </.page_header>

      <.logs_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="change_logs"
          rows={@change_logs}
          row_id={&"change_log-#{&1.change_log.event_id}"}
          row_click={
            fn row ->
              ~p"/#{@account}/logs/change_logs/#{row.change_log.event_id}?#{@query_params}"
            end
          }
          row_selected={
            fn row ->
              not is_nil(@selected_change_log) and
                row.change_log.event_id == @selected_change_log.event_id
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
              event_id={row.change_log.event_id}
              timestamp={row.change_log.timestamp}
              tz_mode={@tz_mode}
              display_tz={@display_tz}
            />
          </:col>
          <:col :let={row} field={{:change_logs, :event_id}} label="Event ID" class="w-52">
            <span class="font-mono text-[10px] text-[var(--text-tertiary)] break-all">
              {row.change_log.event_id}
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
            <.op_badge op={row.change_log.operation} />
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

      <.change_log_panel
        account={@account}
        change_log={@selected_change_log}
        tz_mode={@tz_mode}
        display_tz={@display_tz}
      />
    </div>
    """
  end

  # Inline function component so `display_tz` flows as an explicit prop.
  # Without this wrapper the slot's `{@display_tz}` reference doesn't
  # re-evaluate when display_tz changes, because LV's change tracker only
  # re-invokes the slot body when the surrounding function component's
  # props (rows, etc.) change, not when an outer assign moves.
  attr :event_id, :string, required: true
  attr :timestamp, DateTime, required: true
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true

  defp timestamp_cell(assigns) do
    ~H"""
    <span
      id={"timestamp-#{@event_id}"}
      data-tz-mode={@tz_mode}
      title={"#{DateTime.to_iso8601(@timestamp)} (#{@display_tz})"}
      class="text-xs text-[var(--text-primary)] tabular-nums"
    >
      {PortalWeb.Format.short_datetime(@timestamp, @display_tz)}
    </span>
    """
  end

  defp actor_cell(%{subject: nil} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-xs text-[var(--text-tertiary)] italic">
      <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--text-muted)]"></span> system
    </span>
    """
  end

  defp actor_cell(%{subject: subject} = assigns) do
    assigns =
      assign(assigns,
        name: Map.get(subject, "actor_name"),
        email: Map.get(subject, "actor_email")
      )

    ~H"""
    <div :if={@name not in [nil, ""]} class="min-w-0">
      <div class="text-sm font-medium text-[var(--text-primary)] truncate">{@name}</div>
      <div :if={@email not in [nil, ""]} class="text-xs text-[var(--text-tertiary)] truncate">
        {@email}
      </div>
    </div>
    <span
      :if={@name in [nil, ""] and @email not in [nil, ""]}
      class="text-sm text-[var(--text-secondary)] truncate"
    >
      {@email}
    </span>
    <span
      :if={@name in [nil, ""] and @email in [nil, ""]}
      class="inline-flex items-center gap-1.5 text-xs text-[var(--text-tertiary)] italic"
    >
      <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--text-muted)]"></span> system
    </span>
    """
  end

  defp op_badge(assigns) do
    cfg = op_badge_config(assigns.op)
    assigns = assign(assigns, cfg: cfg)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[11px] font-medium",
      @cfg.pill_class
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full shrink-0", @cfg.dot_class]}></span>
      {@cfg.label}
    </span>
    """
  end

  defp op_badge_config(:insert) do
    %{
      label: "Insert",
      pill_class: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
      dot_class: "bg-green-500"
    }
  end

  defp op_badge_config(:update) do
    %{
      label: "Update",
      pill_class: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400",
      dot_class: "bg-amber-500"
    }
  end

  defp op_badge_config(:delete) do
    %{
      label: "Delete",
      pill_class: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400",
      dot_class: "bg-red-500"
    }
  end

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

  attr :account, :any, required: true
  attr :change_log, :any, default: nil
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true

  defp change_log_panel(assigns) do
    ~H"""
    <div
      id="change-log-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@change_log, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <div :if={@change_log} class="flex flex-col h-full overflow-hidden">
        <.change_log_panel_header change_log={@change_log} />
        <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
          <.change_log_diff change_log={@change_log} />
          <.change_log_sidebar
            change_log={@change_log}
            tz_mode={@tz_mode}
            display_tz={@display_tz}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :change_log, :any, required: true

  defp change_log_panel_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)] flex items-center justify-between gap-3">
      <div class="flex items-center gap-3 min-w-0">
        <h2 class="text-sm font-semibold text-[var(--text-primary)] truncate">
          {change_title(@change_log)}
        </h2>
        <.op_badge op={@change_log.operation} />
      </div>
      <button
        phx-click="close_panel"
        class="shrink-0 flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
        title="Close (Esc)"
      >
        <.icon name="ri-close-line" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr :change_log, :any, required: true

  defp change_log_diff(assigns) do
    op = assigns.change_log.operation
    {legend_label, legend_dot} = diff_legend(op)

    assigns =
      assign(assigns, op: op, legend_label: legend_label, legend_dot: legend_dot)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
      <div class="shrink-0 px-5 py-2.5 border-b border-[var(--border)] bg-[var(--surface)] flex items-center justify-between gap-3">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
          Diff
        </h3>
        <span class="inline-flex items-center gap-1.5 text-[10px] text-[var(--text-tertiary)]">
          <span class={["w-1.5 h-1.5 rounded-full", @legend_dot]}></span> {@legend_label}
        </span>
      </div>
      <div class="flex-1 overflow-auto bg-[var(--surface)]">
        <div class="json-diff">
          <JSONDiff.diff old={@change_log.before} new={@change_log.after} />
        </div>
      </div>
    </div>
    """
  end

  attr :change_log, :any, required: true
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true

  defp change_log_sidebar(assigns) do
    ~H"""
    <div class="w-80 shrink-0 overflow-y-auto p-5 space-y-5 bg-[var(--surface-overlay)]">
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
          Details
        </h3>
        <dl class="space-y-2.5">
          <.detail_row label="Object">
            <span class="font-mono text-xs text-[var(--text-primary)]">{@change_log.object}</span>
          </.detail_row>
          <.detail_row label="Operation">
            <.op_badge op={@change_log.operation} />
          </.detail_row>
          <.detail_row label="Timestamp">
            <span
              id={"panel-timestamp-#{@change_log.event_id}"}
              data-tz-mode={@tz_mode}
              title={"#{DateTime.to_iso8601(@change_log.timestamp)} (#{@display_tz})"}
              class="text-xs text-[var(--text-secondary)] tabular-nums"
            >
              {PortalWeb.Format.short_datetime(@change_log.timestamp, @display_tz)}
            </span>
          </.detail_row>
          <.detail_row label="Event ID">
            <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
              {@change_log.event_id}
            </span>
          </.detail_row>
        </dl>
      </section>

      <div class="border-t border-[var(--border)]"></div>

      <.subject_section subject={@change_log.subject} />
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail_row(assigns) do
    ~H"""
    <div>
      <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp subject_section(%{subject: nil} = assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
        Subject
      </h3>
      <p class="text-xs text-[var(--text-tertiary)] italic">
        No authenticated subject. This change was performed by the system.
      </p>
    </section>
    """
  end

  defp subject_section(%{subject: subject} = assigns) do
    rows =
      [
        {"Actor", Map.get(subject, "actor_name")},
        {"Email", Map.get(subject, "actor_email")},
        {"Actor type", Map.get(subject, "actor_type")},
        {"Actor ID", Map.get(subject, "actor_id")},
        {"Auth provider ID", Map.get(subject, "auth_provider_id")},
        {"IP", Map.get(subject, "ip")},
        {"IP location",
         [Map.get(subject, "ip_city"), Map.get(subject, "ip_region")]
         |> Enum.reject(&(&1 in [nil, "", "null"]))
         |> Enum.join(", ")
         |> case do
           "" -> nil
           s -> s
         end},
        {"User agent", Map.get(subject, "user_agent")}
      ]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    assigns = assign(assigns, rows: rows)

    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
        Subject
      </h3>
      <dl :if={@rows != []} class="space-y-2.5">
        <.detail_row :for={{label, value} <- @rows} label={label}>
          <span class={[
            "text-xs break-all",
            label in ["Actor ID", "Auth provider ID", "IP", "User agent"] &&
              "font-mono text-[var(--text-secondary)]",
            label not in ["Actor ID", "Auth provider ID", "IP", "User agent"] &&
              "text-[var(--text-primary)]"
          ]}>
            {value}
          </span>
        </.detail_row>
      </dl>
      <p :if={@rows == []} class="text-xs text-[var(--text-tertiary)] italic">
        No subject details available.
      </p>
    </section>
    """
  end

  defp diff_legend(:insert), do: {"Inserted record shown", "bg-green-500"}
  defp diff_legend(:delete), do: {"Deleted record shown", "bg-red-500"}
  defp diff_legend(:update), do: {"Changes shown inline", "bg-amber-500"}

  defp change_title(%{operation: operation, object: object}) do
    "#{operation |> Atom.to_string() |> String.capitalize()} on #{object}"
  end

  # The `show_system` toggle is off by default, so when the URL omits the
  # filter we still want to hide entries whose subject is nil. The user
  # explicitly opts in by enabling the toggle, which adds `show_system=true`
  # to the URL and overrides this default.
  defp default_show_system(filter) do
    if Keyword.has_key?(filter, :show_system), do: filter, else: [{:show_system, false} | filter]
  end

  # The UTC/Local mode lives under the timestamp filter so the toggle's URL
  # state survives reloads. Read it off the params on every handle_params so
  # the timestamp column re-renders in the active timezone.
  defp tz_mode_from_params(%{"change_logs_filter" => %{"timestamp" => %{"mode" => mode}}})
       when mode in ["utc", "local"],
       do: mode

  defp tz_mode_from_params(_params), do: "utc"

  defp browser_tz_from_connect(socket) do
    case Phoenix.LiveView.get_connect_params(socket) do
      %{"timezone" => tz} when is_binary(tz) and tz != "" -> tz
      _ -> "Etc/UTC"
    end
  end

  # tz_mode is purely a display preference: "utc" renders in UTC, "local"
  # renders in the browser's IANA zone (captured at connect time). The
  # active zone (`display_tz`) is what every timestamp cell actually
  # formats against, so the rendered text changes when the mode flips,
  # and LV's diff patches the cells without any client-side reformat.
  defp assign_tz(socket, params) do
    tz_mode = tz_mode_from_params(params)

    display_tz =
      case tz_mode do
        "local" -> socket.assigns.browser_tz
        _ -> "Etc/UTC"
      end

    assign(socket, tz_mode: tz_mode, display_tz: display_tz)
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.ChangeLog
    alias Portal.Safe
    alias Portal.Types.EventId

    def list_change_logs(subject, opts \\ []) do
      from(cl in ChangeLog, as: :change_logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def fetch_change_log(event_id, subject) do
      with {:ok, event_id} <- EventId.cast(event_id) do
        result =
          from(cl in ChangeLog, as: :change_logs)
          |> where([change_logs: cl], cl.event_id == ^event_id)
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

    def cursor_fields, do: [{:change_logs, :desc, :event_id}]

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
    # the event_id of the entry itself. event_id is stored as a 12-byte bytea
    # whose canonical public form is its 24-char lowercase hex encoding, so we
    # `encode(event_id, 'hex') ILIKE ...` to support prefix searches.
    defp filter_by_actor(queryable, value) do
      pattern = "%" <> value <> "%"

      {queryable,
       dynamic(
         [change_logs: cl],
         fragment("?->>'actor_id' ILIKE ?", cl.subject, ^pattern) or
           fragment("?->>'actor_name' ILIKE ?", cl.subject, ^pattern) or
           fragment("?->>'actor_email' ILIKE ?", cl.subject, ^pattern) or
           fragment("encode(?, 'hex') ILIKE ?", cl.event_id, ^pattern)
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
