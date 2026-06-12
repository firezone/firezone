defmodule PortalWeb.Logs.Components do
  @moduledoc """
  Shared building blocks for the audit log viewers
  (`PortalWeb.Logs.ChangeLogs`, `SessionLogs`, `FlowLogs`, `APIRequestLogs`).

  Cell and detail-row components live here so each viewer renders consistently
  and so the timezone-toggle pattern, slide-in show panel, and subject metadata
  block are defined once.
  """
  use Phoenix.Component
  alias PortalWeb.CoreComponents

  @doc """
  Single timestamp table cell. `event_id` keeps the wrapper's id unique so LV's
  diff can patch it independently. `tz_mode`/`display_tz` flow as explicit
  props so column re-rendering picks up timezone toggles.
  """
  attr :event_id, :string, required: true
  attr :timestamp, DateTime, required: true
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true
  attr :id_prefix, :string, default: "timestamp"

  def timestamp_cell(assigns) do
    ~H"""
    <span
      id={"#{@id_prefix}-#{@event_id}"}
      data-tz-mode={@tz_mode}
      title={"#{DateTime.to_iso8601(@timestamp)} (#{@display_tz})"}
      class="text-xs text-[var(--text-primary)] tabular-nums"
    >
      {PortalWeb.Format.short_datetime(@timestamp, @display_tz)}
    </span>
    """
  end

  @doc """
  Renders an actor description from a `subject` map (the JSON payload stored
  on change/session/flow logs). Falls back to `system` when no subject is
  attached.
  """
  attr :subject, :any, required: true

  def actor_cell(%{subject: nil} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-xs text-[var(--text-tertiary)] italic">
      <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--text-muted)]"></span> system
    </span>
    """
  end

  def actor_cell(%{subject: subject} = assigns) do
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

  @doc """
  Renders a colored rectangular badge for an insert/update/delete operation.
  """
  attr :op, :atom, required: true

  def op_label(%{op: :insert} = assigns) do
    ~H"""
    <CoreComponents.badge type="success" class="uppercase">Insert</CoreComponents.badge>
    """
  end

  def op_label(%{op: :update} = assigns) do
    ~H"""
    <CoreComponents.badge type="warning" class="uppercase">Update</CoreComponents.badge>
    """
  end

  def op_label(%{op: :delete} = assigns) do
    ~H"""
    <CoreComponents.badge type="danger" class="uppercase">Delete</CoreComponents.badge>
    """
  end

  @doc """
  Single key-value row in a show panel sidebar.
  """
  attr :label, :string, required: true
  slot :inner_block, required: true

  def detail_row(assigns) do
    ~H"""
    <div>
      <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc """
  Section heading in a show panel sidebar.
  """
  attr :label, :string, required: true

  def section_heading(assigns) do
    ~H"""
    <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
      {@label}
    </h3>
    """
  end

  @doc """
  Slide-in show panel container. Triggered open when `open?` is true.
  Renders the close button + Escape handler; body comes from the slot.
  """
  attr :id, :string, required: true
  attr :open?, :boolean, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def show_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@open?, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <div :if={@open?} class="flex flex-col h-full overflow-hidden">
        <.show_panel_header title={@title} />
        <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Show panel header bar with title and close button.
  """
  attr :title, :string, required: true

  def show_panel_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)] flex items-center justify-between gap-3">
      <div class="flex items-center gap-3 min-w-0">
        <h2 class="text-sm font-semibold text-[var(--text-primary)] truncate">
          {@title}
        </h2>
      </div>
      <button
        phx-click="close_panel"
        class="shrink-0 flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
        title="Close (Esc)"
      >
        <CoreComponents.icon name="ri-close-line" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  @doc """
  Right-side sidebar column inside a show panel. Width and overflow handled
  here so callers just render sections inside.
  """
  slot :inner_block, required: true

  def show_panel_sidebar(assigns) do
    ~H"""
    <div class="w-80 shrink-0 overflow-y-auto p-5 space-y-5 bg-[var(--surface-overlay)]">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a subject metadata block from a change/session log's `subject` map.
  Hides rows with blank values; falls back to an italic note when the map is
  nil (system events) or fully empty.
  """
  attr :subject, :any, required: true

  def subject_section(%{subject: nil} = assigns) do
    ~H"""
    <section>
      <.section_heading label="Subject" />
      <p class="text-xs text-[var(--text-tertiary)] italic">
        No authenticated subject. This change was performed by the system.
      </p>
    </section>
    """
  end

  def subject_section(%{subject: subject} = assigns) do
    rows =
      [
        {"Actor", Map.get(subject, "actor_name")},
        {"Email", Map.get(subject, "actor_email")},
        {"Actor type", Map.get(subject, "actor_type")},
        {"Actor ID", Map.get(subject, "actor_id")},
        {"Auth provider ID", Map.get(subject, "auth_provider_id")},
        {"IP", Map.get(subject, "ip")},
        {"IP location", ip_location_from_subject(subject)},
        {"User agent", Map.get(subject, "user_agent")}
      ]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    assigns = assign(assigns, rows: rows)

    ~H"""
    <section>
      <.section_heading label="Subject" />
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

  defp ip_location_from_subject(subject) do
    [Map.get(subject, "ip_city"), Map.get(subject, "ip_region")]
    |> Enum.reject(&(&1 in [nil, "", "null"]))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  @doc """
  Pulls the browser's IANA timezone out of the LiveView connect params (set by
  app.js via `Intl.DateTimeFormat().resolvedOptions().timeZone`). Defaults to
  UTC when unavailable.
  """
  def browser_tz_from_connect(socket) do
    case Phoenix.LiveView.get_connect_params(socket) do
      %{"timezone" => tz} when is_binary(tz) and tz != "" -> tz
      _ -> "Etc/UTC"
    end
  end

  @doc """
  Reads the URL-encoded timezone mode (utc/local) under the given table's
  timestamp filter. Defaults to UTC when missing.
  """
  def tz_mode_from_params(params, filter_key) do
    case params do
      %{^filter_key => %{"timestamp" => %{"mode" => mode}}} when mode in ["utc", "local"] -> mode
      _ -> "utc"
    end
  end

  @doc """
  Assigns `tz_mode` and `display_tz` from URL params: `local` resolves to the
  browser timezone captured on connect, `utc` to UTC. Every timestamp cell
  formats against `display_tz`, so flipping the mode re-renders inline.
  """
  def assign_tz(socket, params, filter_key) do
    tz_mode = tz_mode_from_params(params, filter_key)

    display_tz =
      case tz_mode do
        "local" -> socket.assigns.browser_tz
        _ -> "Etc/UTC"
      end

    Phoenix.Component.assign(socket, tz_mode: tz_mode, display_tz: display_tz)
  end
end
