defmodule PortalWeb.Logs.Components do
  @moduledoc """
  Shared building blocks for the audit log viewers
  (`PortalWeb.Logs.ChangeLogs`, `SessionLogs`, `FlowLogs`, `APIRequestLogs`).

  Cell and detail-row components live here so each viewer renders consistently
  and so the timezone-toggle pattern, slide-in show panel, and subject metadata
  block are defined once.
  """
  use Phoenix.Component
  use PortalWeb, :verified_routes
  alias PortalWeb.Clients
  alias PortalWeb.CoreComponents

  @doc """
  Single timestamp table cell. `log_id` keeps the wrapper's id unique so LV's
  diff can patch it independently. `tz_mode`/`display_tz` flow as explicit
  props so column re-rendering picks up timezone toggles.
  """
  attr :log_id, :string, required: true
  attr :timestamp, DateTime, required: true
  attr :tz_mode, :string, required: true
  attr :display_tz, :string, required: true
  attr :id_prefix, :string, default: "timestamp"

  def timestamp_cell(assigns) do
    ~H"""
    <span
      id={"#{@id_prefix}-#{@log_id}"}
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
  Single IP address table cell. Full IPv6 addresses are wider than the IP
  column, so the value truncates with an ellipsis.
  """
  attr :ip, :any, required: true

  def ip_cell(assigns) do
    assigns = assign(assigns, :ip, format_ip(assigns.ip))

    ~H"""
    <span class="block truncate font-mono text-xs text-[var(--text-secondary)]">
      {@ip || "-"}
    </span>
    """
  end

  def format_ip(nil), do: nil

  def format_ip(%Postgrex.INET{address: address}) when tuple_size(address) in [4, 8],
    do: to_string(:inet.ntoa(address))

  def format_ip(ip) when is_binary(ip), do: ip

  def format_ip(other), do: to_string(other)

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
  Callers provide the header via the `title` slot so operation badges,
  method chips, etc. can be rendered inline.
  """
  attr :id, :string, required: true
  attr :open?, :boolean, required: true
  slot :title, required: true
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
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)] flex items-center justify-between gap-3">
          <div class="flex items-center gap-3 min-w-0">
            {render_slot(@title)}
          </div>
          <button
            phx-click="close_panel"
            class="shrink-0 flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <CoreComponents.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </div>
        <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
          {render_slot(@inner_block)}
        </div>
      </div>
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
  Actor card, shared across all log show panels (change_logs, session_logs,
  api_request_logs) so every panel renders an identical block for its
  actor. Layout matches the other panel cards: a floating uppercase title
  above a rounded, padded card body.

  Callers pass string values pulled from wherever the actor lives in their
  data (a subject JSONB map or a preloaded `%Portal.Actor{}`). When `name`
  and `email` are both empty and `fallback_id` is set, the card renders a
  "Deleted actor" placeholder — used by api_request_logs when the referenced
  actor row is gone.
  """
  attr :name, :any, default: nil
  attr :email, :any, default: nil
  attr :type, :any, default: nil
  attr :fallback_id, :any, default: nil

  def actor_card(assigns) do
    assigns =
      assign(assigns, :type_str, actor_type_to_string(assigns.type))

    ~H"""
    <section class="flex flex-col">
      <div class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-2">
        Actor
      </div>
      <div class="rounded border border-[var(--border)] bg-[var(--surface)] p-4">
        <div class="flex items-start gap-3">
          <div class={[
            "shrink-0 w-10 h-10 rounded-full flex items-center justify-center",
            actor_type_bg(@type_str)
          ]}>
            <CoreComponents.icon
              name={actor_type_icon(@type_str)}
              class={"w-5 h-5 #{actor_type_fg(@type_str)}"}
            />
          </div>
          <div class="min-w-0 flex-1">
            <%= if @name not in [nil, ""] or @email not in [nil, ""] do %>
              <div class="flex items-center gap-2 flex-wrap">
                <span
                  :if={@name not in [nil, ""]}
                  class="text-sm font-semibold text-[var(--text-primary)] truncate"
                >
                  {@name}
                </span>
                <.actor_type_badge :if={@type_str} type={@type_str} />
              </div>
              <div
                :if={@email not in [nil, ""]}
                class="mt-1 flex items-center gap-1.5 text-xs text-[var(--text-secondary)] min-w-0"
              >
                <CoreComponents.icon
                  name="ri-mail-line"
                  class="w-3.5 h-3.5 shrink-0 text-[var(--text-tertiary)]"
                />
                <span class="truncate">{@email}</span>
              </div>
            <% else %>
              <div class="text-sm italic text-[var(--text-tertiary)]">Deleted actor</div>
              <div
                :if={@fallback_id not in [nil, ""]}
                class="mt-1 font-mono text-[10px] text-[var(--text-tertiary)] break-all"
              >
                {@fallback_id}
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp actor_type_to_string(nil), do: nil
  defp actor_type_to_string(atom) when is_atom(atom), do: to_string(atom)
  defp actor_type_to_string(str) when is_binary(str), do: str

  attr :type, :string, required: true

  defp actor_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-semibold tracking-wide uppercase",
      actor_type_badge_class(@type)
    ]}>
      {actor_type_label(@type)}
    </span>
    """
  end

  defp actor_type_icon("account_admin_user"), do: "ri-shield-user-line"
  defp actor_type_icon("service_account"), do: "ri-server-line"
  defp actor_type_icon("api_client"), do: "ri-terminal-line"
  defp actor_type_icon(_), do: "ri-user-line"

  defp actor_type_bg("account_admin_user"), do: "bg-purple-100 dark:bg-purple-900/40"
  defp actor_type_bg("service_account"), do: "bg-blue-100 dark:bg-blue-900/40"
  defp actor_type_bg("api_client"), do: "bg-amber-100 dark:bg-amber-900/40"
  defp actor_type_bg(_), do: "bg-neutral-100 dark:bg-neutral-800"

  defp actor_type_fg("account_admin_user"), do: "text-purple-700 dark:text-purple-300"
  defp actor_type_fg("service_account"), do: "text-blue-700 dark:text-blue-300"
  defp actor_type_fg("api_client"), do: "text-amber-700 dark:text-amber-300"
  defp actor_type_fg(_), do: "text-neutral-700 dark:text-neutral-300"

  defp actor_type_badge_class("account_admin_user"),
    do: "bg-purple-100 text-purple-800 dark:bg-purple-900/50 dark:text-purple-200"

  defp actor_type_badge_class("service_account"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900/50 dark:text-blue-200"

  defp actor_type_badge_class("api_client"),
    do: "bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-200"

  defp actor_type_badge_class(_),
    do: "bg-neutral-100 text-neutral-800 dark:bg-neutral-800 dark:text-neutral-200"

  defp actor_type_label("account_admin_user"), do: "Admin"
  defp actor_type_label("account_user"), do: "User"
  defp actor_type_label("service_account"), do: "Service"
  defp actor_type_label("api_client"), do: "API client"
  defp actor_type_label(other) when is_binary(other), do: other

  @doc """
  Renders an icon representing a session_log's context. Gateway sessions get
  the server/machine icon. Portal sessions get the admin shield. Client
  sessions defer to the existing client OS icon picker so Windows/Mac/iOS/etc
  surface the same icon they do on the Clients page.
  """
  attr :context, :atom, required: true
  attr :user_agent, :string, default: nil
  attr :class, :string, default: "w-5 h-5"

  def session_context_icon(%{context: :gateway} = assigns) do
    ~H"""
    <CoreComponents.icon name="ri-server-line" title="Gateway" class={@class} />
    """
  end

  def session_context_icon(%{context: :portal} = assigns) do
    ~H"""
    <CoreComponents.icon name="ri-shield-user-line" title="Portal" class={@class} />
    """
  end

  def session_context_icon(%{context: :client} = assigns) do
    assigns =
      assign(assigns, :icon_name, Clients.Components.client_os_icon_name(assigns.user_agent))

    ~H"""
    <CoreComponents.icon name={@icon_name} title={@user_agent || "Client"} class={@class} />
    """
  end

  @doc """
  Centered notice for the paginator bar linking to log sink settings.
  """
  attr :account, :any, required: true

  def log_sinks_notice(assigns) do
    ~H"""
    <span class="hidden lg:inline-flex items-center gap-1.5 whitespace-nowrap">
      <CoreComponents.icon name="ri-information-line" class="w-3.5 h-3.5 shrink-0" />
      <span>
        Log streaming to SIEMs and other destinations can be configured in
        <.link navigate={~p"/#{@account}/settings/log_sinks"} class={CoreComponents.link_style()}>
          log sinks</.link>.
      </span>
    </span>
    """
  end

  # Natural Earth 110m simplified land polygons, projected to equirectangular
  # on a 1000x500 viewBox. Baked into the module at compile time so we don't
  # rely on cross-file <use> (Firefox's handling is quirky) and so LV treats
  # the whole path blob as a single static string that never diffs.
  @external_resource Path.join(
                       :code.priv_dir(:portal),
                       "static/images/world-map.svg"
                     )
  @world_map_paths (Path.join(:code.priv_dir(:portal), "static/images/world-map.svg")
                    |> File.read!()
                    |> then(fn svg ->
                      Regex.run(~r{<g id="land"[^>]*>([\s\S]+)</g>}, svg,
                        capture: :all_but_first
                      )
                      |> hd()
                    end)
                    |> Phoenix.HTML.raw())

  @doc """
  Renders a Natural Earth 110m simplified world map with a highlighted
  marker projected onto it via equirectangular. Falls back to a "No
  location available" placeholder when either coordinate is missing.
  Optional `caption` slot renders below the map (city, region, coordinates).

  The land paths are inlined at compile time and painted via `fill="currentColor"`
  so the parent's `text-[var(--text-tertiary)]` class controls the color and
  the map themes correctly in both light and dark mode.
  """
  attr :lat, :any, required: true
  attr :lon, :any, required: true
  slot :caption

  def location_map(%{lat: lat, lon: lon} = assigns)
      when is_number(lat) and is_number(lon) do
    {mx, my} = project(lat, lon)

    assigns =
      assigns
      |> assign(:marker_x, mx)
      |> assign(:marker_y, my)
      |> assign(:land_svg, @world_map_paths)

    ~H"""
    <div class="rounded border border-[var(--border)] overflow-hidden bg-[var(--surface-raised)]">
      <svg
        viewBox="0 0 1000 500"
        preserveAspectRatio="xMidYMid meet"
        class="w-full block aspect-[2/1] text-[var(--text-tertiary)]"
        role="img"
        aria-label="Location map"
      >
        <rect width="1000" height="500" fill="var(--surface-raised)" />
        <g stroke="var(--border)" stroke-width="1" opacity="0.35" fill="none">
          <line x1="0" y1="125" x2="1000" y2="125" />
          <line x1="0" y1="375" x2="1000" y2="375" />
          <line x1="250" y1="0" x2="250" y2="500" />
          <line x1="500" y1="0" x2="500" y2="500" />
          <line x1="750" y1="0" x2="750" y2="500" />
        </g>
        <g fill="currentColor" opacity="0.55">{@land_svg}</g>
        <circle cx={@marker_x} cy={@marker_y} r="16" fill="var(--brand)" opacity="0.2" />
        <circle cx={@marker_x} cy={@marker_y} r="7" fill="var(--brand)" />
        <circle cx={@marker_x} cy={@marker_y} r="2.5" fill="white" />
      </svg>
      <div :if={@caption != []} class="px-3 py-2 border-t border-[var(--border)] bg-[var(--surface)]">
        {render_slot(@caption)}
      </div>
      <a
        href={"https://www.google.com/maps/place/#{@lat},#{@lon}"}
        target="_blank"
        rel="noopener noreferrer"
        class="flex items-center justify-center gap-1 px-3 py-2 border-t border-[var(--border)] text-[11px] text-[var(--text-secondary)] hover:text-[var(--brand)] hover:bg-[var(--surface)] transition-colors"
      >
        <CoreComponents.icon name="ri-external-link-line" class="w-3 h-3" />
        View on Google Maps
      </a>
    </div>
    """
  end

  def location_map(assigns) do
    ~H"""
    <div class="rounded border border-dashed border-[var(--border)] bg-[var(--surface-raised)] overflow-hidden">
      <div class="aspect-[2/1] flex flex-col items-center justify-center gap-2 text-center">
        <CoreComponents.icon name="ri-map-pin-line" class="w-6 h-6 text-[var(--text-tertiary)]" />
        <p class="text-xs text-[var(--text-tertiary)]">Location unknown</p>
      </div>
      <div :if={@caption != []} class="px-3 py-2 border-t border-[var(--border)] bg-[var(--surface)]">
        {render_slot(@caption)}
      </div>
    </div>
    """
  end

  defp project(lat, lon) do
    x = (lon + 180) * 1000 / 360
    y = (90 - lat) * 500 / 180
    {Float.round(x, 1), Float.round(y, 1)}
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
