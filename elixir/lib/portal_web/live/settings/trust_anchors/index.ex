defmodule PortalWeb.Settings.TrustAnchors.Index do
  use PortalWeb, :live_view

  import Ecto.Changeset, only: [cast: 3, put_change: 3, add_error: 3, get_field: 3]

  alias Portal.{Safe, TrustAnchor}
  alias Portal.Crypto.X509

  @max_upload_size 1_000_000
  @max_upload_entries 10
  @max_trust_anchors 10
  @max_trust_anchor_certificates 20

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, TrustAnchor}

    def count_trust_anchors(subject) do
      from(t in TrustAnchor)
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    # Counts certificates rather than anchors, since one anchor may hold a
    # whole bundle. The anchor being edited is excluded so its own rows are
    # not counted twice against the certificates replacing them.
    def count_trust_anchor_certificates(subject, except_trust_anchor_id) do
      from(c in Portal.TrustAnchorCertificate)
      |> then(fn queryable ->
        if except_trust_anchor_id do
          where(queryable, [c], c.trust_anchor_id != ^except_trust_anchor_id)
        else
          queryable
        end
      end)
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    def list_trust_anchors(subject) do
      from(t in TrustAnchor, order_by: [asc: t.inserted_at, asc: t.id])
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Safe.preload(:certificates)
    end

    def get_trust_anchor!(id, subject) do
      from(t in TrustAnchor, where: t.id == ^id, preload: [:certificates])
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    # Keyed on the issuer rather than on the anchor, so an endpoint is shown
    # against whichever uploaded certificate bears that name.
    def list_revocation_endpoints(issuers, subject) do
      from(e in Portal.RevocationEndpoint, where: e.issuer in ^issuers)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    # Distinct serials rather than rows: a CA that partitions its list can hold
    # the same serial in more than one partition, and the connect check reads
    # their union.
    def count_revocations(issuers, subject) do
      from(r in Portal.CrlRevocation,
        where: r.issuer in ^issuers,
        group_by: r.issuer,
        select: {r.issuer, count(r.serial, :distinct)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    # One row per issuer for the whole table, so the list does not read an
    # endpoint per anchor.
    def revocation_health(issuers, subject) do
      from(e in Portal.RevocationEndpoint,
        where: e.issuer in ^issuers,
        group_by: e.issuer,
        select: {
          e.issuer,
          %{
            disabled: fragment("bool_or(?)", e.is_disabled),
            errored: fragment("bool_or(? IS NOT NULL)", e.errored_at),
            error_message: fragment("max(coalesce(?, ?))", e.crl_error, e.ocsp_error)
          }
        }
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    # Editing the anchor is the only way back: a disabled endpoint never fetches,
    # so it can never notice that the CA has recovered.
    def clear_revocation_errors(issuers, subject) do
      now = DateTime.utc_now()

      from(e in Portal.RevocationEndpoint, where: e.issuer in ^issuers)
      |> update(
        set: [
          errored_at: nil,
          is_disabled: false,
          disabled_reason: nil,
          crl_error: nil,
          delta_error: nil,
          ocsp_error: nil,
          updated_at: ^now
        ]
      )
      |> Safe.scoped(subject)
      |> Safe.update_all([])
    end

    def count_revoked_statuses(issuers, subject) do
      from(s in Portal.OcspStatus,
        where: s.issuer in ^issuers,
        where: s.status == "revoked",
        group_by: s.issuer,
        select: {s.issuer, count(s.serial)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

  end

  def mount(_params, _session, socket) do
    trust_anchors_enabled? = PortalWeb.NavigationComponents.trust_anchors_enabled?()

    if trust_anchors_enabled? do
      trust_anchors = Database.list_trust_anchors(socket.assigns.subject)

      socket =
        socket
        |> assign(page_title: "Trust Anchors")
        |> assign(trust_anchors: trust_anchors)
        |> assign_revocation_health(trust_anchors)
        |> assign(selected_trust_anchor: nil)
        |> assign(form: nil, input_mode: :paste)
        |> assign(confirm_delete?: false)
        |> assign(revocation: [])
        |> assign(panel_tab: :overview, expanded_endpoint: nil)
        |> assign(trust_anchors_enabled?: trust_anchors_enabled?)
        |> assign(device_posture_enabled?: PortalWeb.NavigationComponents.device_posture_enabled?())
        |> allow_upload(:cert_file,
          accept: ~w(.pem .crt .cer .der .txt),
          max_entries: @max_upload_entries,
          max_file_size: @max_upload_size,
          auto_upload: true
        )

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/account")}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = build_creation_changeset(%{}, socket.assigns.subject)

    socket =
      socket
      |> assign(selected_trust_anchor: nil, input_mode: :paste, confirm_delete?: false)
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    trust_anchor = Database.get_trust_anchor!(id, socket.assigns.subject)
    changeset = build_edit_changeset(trust_anchor, %{}, socket.assigns.subject)

    socket =
      socket
      |> assign(selected_trust_anchor: trust_anchor, input_mode: :paste, confirm_delete?: false)
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    trust_anchor = Database.get_trust_anchor!(id, socket.assigns.subject)

    socket =
      socket
      |> assign(
        selected_trust_anchor: trust_anchor,
        form: nil,
        confirm_delete?: false,
        panel_tab: :overview,
        expanded_endpoint: nil
      )
      |> assign_revocation(trust_anchor)

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       selected_trust_anchor: nil,
       form: nil,
       input_mode: :paste,
       confirm_delete?: false
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" phx-window-keydown="handle_keydown" phx-key="Escape">
      <.settings_nav
        account={@account}
        current_path={@current_path}
        trust_anchors_enabled?={@trust_anchors_enabled?}
        device_posture_enabled?={@device_posture_enabled?}
      />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-xs font-semibold text-heading">Trust Anchors</h2>
            <span class="text-xs text-subtle tabular-nums">
              {length(@trust_anchors)}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.link
              patch={~p"/#{@account}/settings/trust_anchors/new"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
            >
              <.icon name="ri-add-line" class="w-3 h-3" /> Add
            </.link>
          </div>
        </div>

        <div class="flex-1 overflow-auto">
          <%= if Enum.empty?(@trust_anchors) do %>
            <div class="flex items-center justify-center h-full">
              <div class="flex flex-col items-center gap-3 py-16">
                <div class="w-9 h-9 rounded-lg border border-border bg-raised flex items-center justify-center">
                  <.icon name="ri-shield-check-line" class="w-3 h-3" />
                </div>
                <div class="text-center">
                  <p class="text-sm font-medium text-heading">No trust anchors yet</p>
                  <p class="text-xs text-subtle mt-0.5">
                    Add a CA certificate chain to validate presented certificates against.
                  </p>
                </div>
                <.link
                  patch={~p"/#{@account}/settings/trust_anchors/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add a trust anchor
                </.link>
              </div>
            </div>
          <% else %>
            <table class="w-full text-sm border-collapse">
              <thead class="sticky top-0 z-10 bg-raised">
                <tr class="border-b border-border-strong">
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
                    Name
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-36">
                    Certificates
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-36">
                    Created
                  </th>
                </tr>
              </thead>
              <tbody>
                <.trust_anchor_row
                  :for={trust_anchor <- @trust_anchors}
                  trust_anchor={trust_anchor}
                  health={@revocation_health[trust_anchor.id]}
                  selected?={
                    !!@selected_trust_anchor && @selected_trust_anchor.id == trust_anchor.id
                  }
                />
              </tbody>
            </table>
          <% end %>
        </div>
      </div>

    <!-- Show Panel (:show) -->
      <div
        id="trust-anchor-show-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :show && "translate-x-0") || "translate-x-full"
        ]}
      >
        <.trust_anchor_show_panel
          :if={@live_action == :show && @selected_trust_anchor}
          account={@account}
          trust_anchor={@selected_trust_anchor}
          confirm_delete?={@confirm_delete?}
          revocation={@revocation}
          panel_tab={@panel_tab}
          expanded_endpoint={@expanded_endpoint}
        />
      </div>

    <!-- Creation Panel (:new) -->
      <div
        id="trust-anchor-new-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :new && "translate-x-0") || "translate-x-full"
        ]}
      >
        <div :if={@live_action == :new && @form} class="flex flex-col h-full overflow-hidden">
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-heading">New Trust Anchor</h2>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
          </div>

          <.form
            id="trust-anchor-new-form"
            for={@form}
            phx-change="validate_new"
            phx-submit="create_trust_anchor"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <.trust_anchor_form_fields form={@form} input_mode={@input_mode} uploads={@uploads} />
            </div>

            <.panel_footer>
              <.panel_footer_button type="button" phx-click="close_panel">
                Cancel
              </.panel_footer_button>
              <.panel_footer_button type="submit" style="primary">
                Create
              </.panel_footer_button>
            </.panel_footer>
          </.form>
        </div>
      </div>

    <!-- Edit Panel (:edit) -->
      <div
        id="trust-anchor-edit-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :edit && "translate-x-0") || "translate-x-full"
        ]}
      >
        <div
          :if={@live_action == :edit && @selected_trust_anchor && @form}
          class="flex flex-col h-full overflow-hidden"
        >
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-heading">Edit Trust Anchor</h2>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
          </div>

          <.form
            id="trust-anchor-edit-form"
            for={@form}
            phx-change="validate_edit"
            phx-submit="update_trust_anchor"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <.trust_anchor_form_fields form={@form} input_mode={@input_mode} uploads={@uploads} />
            </div>

            <.panel_footer>
              <.panel_footer_button type="button" phx-click="close_panel">
                Cancel
              </.panel_footer_button>
              <.panel_footer_button type="submit" style="primary">
                Save
              </.panel_footer_button>
            </.panel_footer>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :health, :any, required: true

  # An icon rather than a status column: an anchor with no revocation endpoint
  # yet is not unhealthy, so the common case should say nothing at all. The
  # detail lives one click away, on the panel's Revocation tab.
  defp revocation_warning_icon(%{health: nil} = assigns) do
    ~H"""
    """
  end

  defp revocation_warning_icon(%{health: %{state: :disabled}} = assigns) do
    ~H"""
    <span title="Revocation is not being checked for at least one of this CA's addresses.">
      <.icon name="ri-error-warning-fill" class="w-4 h-4 text-red-600 dark:text-red-400" />
    </span>
    """
  end

  defp revocation_warning_icon(assigns) do
    ~H"""
    <span title="Firezone is having trouble reaching at least one of this CA's addresses.">
      <.icon name="ri-error-warning-fill" class="w-4 h-4 text-amber-500 dark:text-amber-400" />
    </span>
    """
  end

  attr :trust_anchor, :any, required: true
  attr :selected?, :boolean, required: true
  attr :health, :any, required: true

  defp trust_anchor_row(assigns) do
    ~H"""
    <tr
      phx-click="select_trust_anchor"
      phx-value-id={@trust_anchor.id}
      class={[
        "border-b border-border cursor-pointer transition-colors",
        @selected? && "bg-raised",
        !@selected? && "hover:bg-raised"
      ]}
    >
      <td class="px-6 py-3">
        <div class="flex items-center gap-1.5 min-w-0">
          <div class="text-sm font-medium text-heading truncate">{@trust_anchor.name}</div>
          <.revocation_warning_icon health={@health} />
        </div>
        <div class="font-mono text-[10px] text-subtle mt-0.5 truncate">
          {@trust_anchor.id}
        </div>
      </td>
      <td class="px-6 py-3 w-36">
        <span class="text-sm text-body">{cert_count_label(@trust_anchor.certificates)}</span>
      </td>
      <td class="px-6 py-3 w-36">
        <span class="text-sm text-body">
          <.relative_datetime datetime={@trust_anchor.inserted_at} />
        </span>
      </td>
    </tr>
    """
  end

  attr :label, :string, required: true
  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :warn, :boolean, default: false

  defp panel_tab(assigns) do
    ~H"""
    <button
      role="tab"
      aria-selected={@active == @tab}
      phx-click="switch_anchor_tab"
      phx-value-tab={@tab}
      class={[
        "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
        if(@active == @tab,
          do: "border-brand text-brand",
          else: "border-transparent text-body hover:text-heading"
        )
      ]}
    >
      {@label}
      <.icon
        :if={@warn}
        name="ri-error-warning-fill"
        class="w-3.5 h-3.5 text-amber-500 dark:text-amber-400"
      />
    </button>
    """
  end

  attr :endpoint, :any, required: true

  defp endpoint_status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @endpoint.is_disabled -> %>
        <.status_badge style={:danger} dot={false}>Not checked</.status_badge>
      <% @endpoint.errored_at -> %>
        <.status_badge style={:warning} dot={false}>Failing</.status_badge>
      <% checked_at(@endpoint) -> %>
        <.status_badge style={:success} dot={false}>OK</.status_badge>
      <% true -> %>
        <.status_badge style={:neutral} dot={false}>Pending</.status_badge>
    <% end %>
    """
  end

  attr :entry, :any, required: true

  defp endpoint_details(assigns) do
    ~H"""
    <div class="space-y-3">
      <p
        :if={@entry.endpoint.is_disabled}
        class="flex items-start gap-1.5 text-xs text-red-600 dark:text-red-400"
      >
        <.icon name="ri-forbid-line" class="w-3.5 h-3.5 shrink-0 mt-0.5" />
        <span>
          Firezone has stopped checking this address, so certificates this CA has
          revoked are still let on. Edit and Save this trust anchor to start
          checking again.
        </span>
      </p>

      <p
        :if={!@entry.endpoint.is_disabled && @entry.endpoint.errored_at}
        class="flex items-start gap-1.5 text-xs text-amber-600 dark:text-amber-400"
      >
        <.icon name="ri-error-warning-line" class="w-3.5 h-3.5 shrink-0 mt-0.5" />
        <span>
          Firezone is retrying. Checking stops if this keeps failing for 24 hours.
        </span>
      </p>

      <div :for={group <- endpoint_detail_groups(@entry)}>
        <p class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-1.5">
          {group.title}
        </p>
        <dl class="grid grid-cols-2 gap-x-6 gap-y-1.5">
          <div :for={{label, value} <- group.rows} class="min-w-0">
            <dt class="text-[10px] text-subtle">{label}</dt>
            <dd class={[
              "text-xs break-all",
              label == "Error" && "text-danger",
              label != "Error" && "text-heading"
            ]}>
              <.detail_value value={value} />
            </dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  attr :value, :any, required: true

  defp detail_value(%{value: %DateTime{}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@value} />
    """
  end

  defp detail_value(assigns) do
    ~H"""
    {@value}
    """
  end

  attr :account, :any, required: true
  attr :trust_anchor, :any, required: true
  attr :confirm_delete?, :boolean, required: true
  attr :revocation, :list, required: true
  attr :panel_tab, :atom, required: true
  attr :expanded_endpoint, :string, default: nil

  defp trust_anchor_show_panel(assigns) do
    certificate_details = Enum.map(assigns.trust_anchor.certificates, &describe_certificate/1)
    assigns = assign(assigns, :certificate_details, certificate_details)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0">
            <h2 class="text-sm font-semibold text-heading truncate">{@trust_anchor.name}</h2>
            <p class="font-mono text-[10px] text-subtle mt-0.5 truncate">{@trust_anchor.id}</p>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <.link
              patch={~p"/#{@account}/settings/trust_anchors/#{@trust_anchor.id}/edit"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
            >
              <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
            </.link>
            <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
          </div>
        </div>
      </div>

      <div
        role="tablist"
        class="flex items-end gap-0 px-5 border-b border-border bg-raised shrink-0"
      >
        <.panel_tab label="Overview" tab={:overview} active={@panel_tab} />
        <.panel_tab
          label={"Certificates (#{length(@certificate_details)})"}
          tab={:certificates}
          active={@panel_tab}
        />
        <.panel_tab
          label={"Revocation (#{length(@revocation)})"}
          tab={:revocation}
          active={@panel_tab}
          warn={Enum.any?(@revocation, &failing?(&1.endpoint))}
        />
      </div>

      <div class="flex-1 overflow-y-auto px-5 py-4 space-y-5">
        <section :if={@panel_tab == :overview}>
          <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
            Details
          </h3>
          <dl class="space-y-2.5">
            <div>
              <dt class="text-[10px] text-subtle mb-0.5">Created</dt>
              <dd class="text-xs text-body">
                <.relative_datetime datetime={@trust_anchor.inserted_at} />
              </dd>
            </div>
            <div>
              <dt class="text-[10px] text-subtle mb-0.5">Certificates</dt>
              <dd class="text-xs text-body">{cert_count_label(@trust_anchor.certificates)}</dd>
            </div>
          </dl>
        </section>

        <section :if={@panel_tab == :revocation}>
          <p :if={@revocation == []} class="text-xs text-subtle">
            No revocation endpoint known yet. A CA publishes its address in the certificates it
            issues, so this fills in the first time a device connects with one.
          </p>

          <table :if={@revocation != []} class="w-full table-fixed text-xs">
            <thead>
              <tr class="border-b border-border text-subtle">
                <th class="text-left px-2 py-2 font-medium">Certificate authority</th>
                <th class="text-left px-2 py-2 font-medium w-20">Checked via</th>
                <th class="text-left px-2 py-2 font-medium w-24">Status</th>
                <th class="w-10"></th>
              </tr>
            </thead>
            <tbody>
              <%= for entry <- @revocation do %>
                <tr
                  phx-click="toggle_revocation_endpoint"
                  phx-keydown="toggle_revocation_endpoint"
                  phx-key="Enter"
                  phx-value-id={endpoint_key(entry.endpoint)}
                  tabindex="0"
                  class="border-b border-border hover:bg-raised cursor-pointer focus:outline-none focus:bg-raised"
                >
                  <td class="px-2 py-2 text-heading">
                    <span class="block truncate">
                      {X509.describe_name(entry.endpoint.issuer) || "(unnamed issuer)"}
                    </span>
                    <span class="block font-mono text-[10px] text-subtle truncate">
                      {entry.endpoint.distribution_point}
                    </span>
                  </td>
                  <td class="px-2 py-2 text-body">{checked_via(entry.endpoint)}</td>
                  <td class="px-2 py-2">
                    <.endpoint_status_badge endpoint={entry.endpoint} />
                  </td>
                  <td class="px-2 py-2 text-subtle">
                    <.icon
                      name={
                        if @expanded_endpoint == endpoint_key(entry.endpoint),
                          do: "ri-arrow-up-s-line",
                          else: "ri-arrow-down-s-line"
                      }
                      class="w-4 h-4"
                    />
                  </td>
                </tr>
                <tr
                  :if={@expanded_endpoint == endpoint_key(entry.endpoint)}
                  class="border-b border-border bg-raised"
                >
                  <td colspan="4" class="px-3 py-3">
                    <.endpoint_details entry={entry} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </section>

        <section :if={@panel_tab == :certificates}>
          <div class="space-y-3">
            <div
              :for={detail <- @certificate_details}
              class="border border-border rounded p-3 bg-surface space-y-3"
            >
              <div class="flex items-center justify-between gap-2">
                <p class="text-xs font-semibold text-heading truncate">
                  {detail.common_name || "(no Common Name)"}
                </p>
                <a
                  href={"data:application/x-pem-file;base64," <> Base.encode64(detail.pem)}
                  download={download_filename(@trust_anchor.name, detail)}
                  class="shrink-0 flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-elevated transition-colors"
                >
                  <.icon name="ri-download-line" class="w-3 h-3" /> Download PEM
                </a>
              </div>
              <dl class="space-y-2">
                <div :for={{label, value} <- certificate_detail_rows(detail)}>
                  <dt class="text-[10px] text-subtle mb-0.5">{label}</dt>
                  <dd class="text-xs text-heading font-mono break-all">
                    <.detail_value value={value} />
                  </dd>
                </div>
              </dl>
            </div>
          </div>
        </section>

        <div class="border-t border-border"></div>

        <section>
          <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error/60 mb-3">
            Danger Zone
          </h3>
          <button
            :if={!@confirm_delete?}
            type="button"
            phx-click="confirm_delete_trust_anchor"
            class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
          >
            <.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete trust anchor
          </button>
          <div
            :if={@confirm_delete?}
            class="rounded border border-error/20 bg-error-light p-3 space-y-3"
          >
            <p class="text-xs text-error">
              <span class="font-medium">Delete this trust anchor?</span>
              <br /> Certificates issued by it will no longer be trusted, and this cannot be undone.
            </p>
            <div class="flex items-center gap-2">
              <.button type="button" phx-click="cancel_delete_trust_anchor" size="xs">
                Cancel
              </.button>
              <.button
                type="button"
                phx-click="delete_trust_anchor"
                style="danger"
                size="xs"
                class="font-medium"
              >
                Delete
              </.button>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :input_mode, :atom, required: true
  attr :uploads, :any, required: true

  defp trust_anchor_form_fields(assigns) do
    certs_field = assigns.form[:certs]

    certs_errors =
      if Phoenix.Component.used_input?(certs_field) do
        Enum.map(certs_field.errors, &translate_error/1)
      else
        []
      end

    assigns =
      assigns
      |> assign(:certs_errors, certs_errors)
      |> assign(:certs_display_value, certs_display_value(assigns.form))

    ~H"""
    <div>
      <.input
        field={@form[:name]}
        label="Name"
        placeholder="E.g. 'Corporate Issuing CA'"
        phx-debounce="300"
        required
      />
    </div>

    <div>
      <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-2">
        Certificate Chain
      </h3>

      <div class="grid gap-3 grid-cols-2 mb-4">
        <div>
          <.input
            id="trust-anchor-input-mode--paste"
            type="radio_button_group"
            name="trust_anchor[input_mode]"
            value="paste"
            checked={@input_mode == :paste}
            required
          />
          <label
            for="trust-anchor-input-mode--paste"
            class={[
              "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
              "peer-checked:border-brand peer-checked:bg-raised",
              "border-border hover:border-border-emphasis"
            ]}
          >
            <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
              <.icon name="ri-clipboard-line" class="w-4 h-4 shrink-0" /> Paste
            </span>
            <span class="text-xs text-body my-auto">Paste PEM or base64 DER text.</span>
          </label>
        </div>

        <div>
          <.input
            id="trust-anchor-input-mode--upload"
            type="radio_button_group"
            name="trust_anchor[input_mode]"
            value="upload"
            checked={@input_mode == :upload}
            required
          />
          <label
            for="trust-anchor-input-mode--upload"
            class={[
              "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
              "peer-checked:border-brand peer-checked:bg-raised",
              "border-border hover:border-border-emphasis"
            ]}
          >
            <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
              <.icon name="ri-upload-2-line" class="w-4 h-4 shrink-0" /> Upload File
            </span>
            <span class="text-xs text-body my-auto">Upload one or more chain files.</span>
          </label>
        </div>
      </div>

      <div :if={@input_mode == :paste}>
        <.input
          type="textarea"
          field={@form[:certs]}
          multiple={true}
          value={@certs_display_value}
          label="Certificate chain (PEM or base64 DER)"
          placeholder="-----BEGIN CERTIFICATE-----"
          rows="10"
          class="font-mono text-xs"
          phx-debounce="300"
        />
      </div>

      <div :if={@input_mode == :upload} class="space-y-2">
        <.label>Chain file(s)</.label>
        <.live_file_input
          upload={@uploads.cert_file}
          class="block w-full text-xs text-subtle file:mr-3 file:cursor-pointer file:rounded file:border file:border-border-strong file:bg-surface file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-body file:transition-colors hover:file:bg-raised hover:file:text-heading"
        />
        <p class="text-xs text-subtle">
          Accepts .pem, .crt, .cer, .der, or .txt, up to 1&nbsp;MB each. Select multiple files to upload
          a root and intermediate CA separately; a DER file holds a single certificate.
        </p>
        <div
          :for={entry <- @uploads.cert_file.entries}
          class="flex flex-col gap-0.5"
        >
          <div class="flex items-center gap-2 text-xs text-body">
            <.icon name="ri-file-line" class="w-3.5 h-3.5 shrink-0" />
            <span class="truncate">{entry.client_name}</span>
            <progress value={entry.progress} max="100" class="w-16">{entry.progress}%</progress>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="text-error"
            >
              <.icon name="ri-close-line" class="w-3.5 h-3.5" />
            </button>
          </div>
          <.error :for={err <- upload_errors(@uploads.cert_file, entry)} inline>
            {upload_error_to_string(err)}
          </.error>
        </div>
        <.error :for={msg <- @certs_errors}>{msg}</.error>
        <.error :for={err <- upload_errors(@uploads.cert_file)}>
          {upload_error_to_string(err)}
        </.error>
      </div>
    </div>
    """
  end

  def handle_event("switch_anchor_tab", %{"tab" => tab}, socket)
      when tab in ~w[overview certificates revocation] do
    {:noreply, assign(socket, panel_tab: String.to_existing_atom(tab))}
  end

  def handle_event("toggle_revocation_endpoint", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_endpoint == id, do: nil, else: id
    {:noreply, assign(socket, expanded_endpoint: expanded)}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/trust_anchors")}
  end

  def handle_event(
        "handle_keydown",
        %{"key" => "Escape"},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:new, :edit, :show] do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/trust_anchors")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("select_trust_anchor", %{"id" => id}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/trust_anchors/#{id}")}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :cert_file, ref)}
  end

  def handle_event("validate_new", %{"trust_anchor" => attrs}, socket) do
    changeset =
      attrs
      |> build_creation_changeset(socket.assigns.subject)
      |> Map.put(:action, :insert)

    socket =
      socket
      |> assign(input_mode: input_mode_from_attrs(attrs, socket.assigns.input_mode))
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_event("create_trust_anchor", %{"trust_anchor" => attrs}, socket) do
    attrs = resolve_certs_attrs(socket, attrs)
    changeset = build_creation_changeset(attrs, socket.assigns.subject)

    case Safe.scoped(changeset, socket.assigns.subject) |> Safe.insert() do
      {:ok, _trust_anchor} ->
        socket =
          socket
          |> assign(trust_anchors: Database.list_trust_anchors(socket.assigns.subject))
          |> put_flash(:success, "Trust anchor created successfully")
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

        {:noreply, socket}

      {:error, changeset} ->
        changeset = surface_certificate_errors(changeset)
        {:noreply, assign(socket, form: to_form(changeset, as: "trust_anchor"))}
    end
  end

  def handle_event("validate_edit", %{"trust_anchor" => attrs}, socket) do
    changeset =
      socket.assigns.selected_trust_anchor
      |> build_edit_changeset(attrs, socket.assigns.subject)
      |> Map.put(:action, :update)

    socket =
      socket
      |> assign(input_mode: input_mode_from_attrs(attrs, socket.assigns.input_mode))
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_event("update_trust_anchor", %{"trust_anchor" => attrs}, socket) do
    attrs = resolve_certs_attrs(socket, attrs)
    changeset =
      build_edit_changeset(socket.assigns.selected_trust_anchor, attrs, socket.assigns.subject)

    case Safe.scoped(changeset, socket.assigns.subject) |> Safe.update() do
      {:ok, trust_anchor} ->
        clear_revocation_errors(trust_anchor, socket.assigns.subject)
        trust_anchors = Database.list_trust_anchors(socket.assigns.subject)

        socket =
          socket
          |> assign(trust_anchors: trust_anchors)
          |> assign_revocation_health(trust_anchors)
          |> put_flash(:success, "Trust anchor updated successfully")
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

        {:noreply, socket}

      {:error, changeset} ->
        changeset = surface_certificate_errors(changeset)
        {:noreply, assign(socket, form: to_form(changeset, as: "trust_anchor"))}
    end
  end

  def handle_event("confirm_delete_trust_anchor", _params, socket) do
    {:noreply, assign(socket, confirm_delete?: true)}
  end

  def handle_event("cancel_delete_trust_anchor", _params, socket) do
    {:noreply, assign(socket, confirm_delete?: false)}
  end

  def handle_event("delete_trust_anchor", _params, socket) do
    case Safe.scoped(socket.assigns.selected_trust_anchor, socket.assigns.subject)
         |> Safe.delete() do
      {:ok, _trust_anchor} ->
        socket =
          socket
          |> assign(trust_anchors: Database.list_trust_anchors(socket.assigns.subject))
          |> put_flash(:success, "Trust anchor deleted successfully")
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

        {:noreply, socket}

      # Another session deleted this trust anchor after it was loaded into the
      # panel. The end state already matches the user's intent, so just
      # refresh and close.
      {:error, :not_found} ->
        socket =
          socket
          |> assign(trust_anchors: Database.list_trust_anchors(socket.assigns.subject))
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          socket
          |> put_flash(:error, "Could not delete trust anchor. Please try again.")
          |> assign(confirm_delete?: false)

        {:noreply, socket}
    end
  end

  defp build_creation_changeset(attrs, subject) do
    %TrustAnchor{}
    |> cast(attrs, [:name, :certs])
    |> TrustAnchor.changeset()
    |> validate_anchor_limit(subject)
    |> validate_certificate_limit(subject, nil)
  end

  # Every attested connect validates the presented certificate against every
  # anchor the account holds, so the pool is capped to keep that work bounded.
  defp validate_anchor_limit(changeset, subject) do
    if Database.count_trust_anchors(subject) >= @max_trust_anchors do
      add_error(
        changeset,
        :name,
        "an account may have at most #{@max_trust_anchors} trust anchors"
      )
    else
      changeset
    end
  end

  defp build_edit_changeset(trust_anchor, attrs, subject) do
    trust_anchor
    |> cast(attrs, [:name, :certs])
    |> seed_certs_pem_if_untouched(attrs, trust_anchor)
    |> TrustAnchor.changeset()
    |> validate_certificate_limit(subject, trust_anchor.id)
  end

  # The anchor cap alone does not bound the work an attested connect does: one
  # anchor may carry a bundle of any size, and an edit can grow it without ever
  # adding an anchor. Every connect validates against every certificate the
  # account holds, so the certificates are what has to be capped.
  defp validate_certificate_limit(changeset, subject, trust_anchor_id) do
    pending = changeset |> get_field(:certs, []) |> length()
    existing = Database.count_trust_anchor_certificates(subject, trust_anchor_id)

    if existing + pending > @max_trust_anchor_certificates do
      add_error(
        changeset,
        :certs,
        "an account may have at most #{@max_trust_anchor_certificates} CA certificates"
      )
    else
      changeset
    end
  end

  defp seed_certs_pem_if_untouched(changeset, attrs, trust_anchor) do
    if Map.has_key?(attrs, "certs") or Map.has_key?(attrs, :certs) do
      changeset
    else
      put_change(changeset, :certs, [armor_certs_as_pem(trust_anchor.certificates)])
    end
  end

  defp armor_certs_as_pem(certificates) do
    Enum.map_join(certificates, & &1.pem)
  end

  # `TrustAnchor.changeset/1` normalizes `:certs` in place, replacing whatever
  # PEM/base64/DER text the admin typed with the normalized raw DER bytes
  # (see `normalize_certs/2` and the schema test asserting on that). Showing
  # those bytes back in the textarea would corrupt the field, so once
  # normalization has produced `:certificates` changesets, read their
  # already-armored `:pem` back for display instead of `@form[:certs].value`.
  defp certs_display_value(form) do
    case Ecto.Changeset.get_change(form.source, :certificates) do
      [_ | _] = certificate_changesets ->
        certificate_changesets
        # `put_assoc/3` can't match freshly-built cert changesets against the
        # existing (unsaved-input) `:id`-less ones they replace, so editing
        # always emits a `:replace` entry for the old row alongside the
        # `:insert` for the new one. Only the surviving side belongs on screen.
        |> Enum.reject(&(&1.action == :replace))
        |> Enum.map_join(&Ecto.Changeset.get_field(&1, :pem))

      _ ->
        List.first(form[:certs].value || [], "")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp resolve_certs_attrs(%{assigns: %{input_mode: :upload}} = socket, attrs) do
    # `path` is LiveView's own temp upload path, not user-controlled.
    certs =
      consume_uploaded_entries(socket, :cert_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    Map.put(attrs, "certs", certs)
  end

  defp resolve_certs_attrs(_socket, attrs), do: attrs

  defp input_mode_from_attrs(%{"input_mode" => "upload"}, _current), do: :upload
  defp input_mode_from_attrs(%{"input_mode" => "paste"}, _current), do: :paste
  defp input_mode_from_attrs(_attrs, current), do: current

  defp cert_count_label(certs) do
    count = length(certs)
    "#{count} certificate#{if count == 1, do: "", else: "s"}"
  end

  # A CA advertises where it publishes in the certificates it issues, not in its
  # own, so nothing is known here until a device presents one. Until then the
  # panel says so rather than implying the CA publishes nothing.
  # Saving the anchor is what an admin is told to do to start checking again, so
  # it clears the failure state whether or not the certificates changed.
  defp clear_revocation_errors(trust_anchor, subject) do
    trust_anchor = Safe.preload(trust_anchor, :certificates)

    case anchor_issuers(trust_anchor) do
      [] -> :ok
      issuers -> Database.clear_revocation_errors(issuers, subject)
    end
  end

  defp anchor_issuers(trust_anchor) do
    trust_anchor.certificates
    |> Enum.flat_map(fn certificate ->
      case X509.pem_decode(certificate.pem) do
        {:ok, [{_type, der, _headers} | _rest]} -> [X509.subject(der)]
        _other -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Every anchor's issuers in one lookup, keyed by anchor, so the table reads
  # the endpoints once rather than once per row.
  defp assign_revocation_health(socket, trust_anchors) do
    issuers = Enum.flat_map(trust_anchors, &anchor_issuers/1) |> Enum.uniq()

    by_issuer =
      if issuers == [] do
        %{}
      else
        Database.revocation_health(issuers, socket.assigns.subject)
      end

    health =
      Map.new(trust_anchors, fn trust_anchor ->
        {trust_anchor.id,
         trust_anchor |> anchor_issuers() |> Enum.map(&Map.get(by_issuer, &1)) |> worst_health()}
      end)

    assign(socket, revocation_health: health)
  end

  # An anchor is only as healthy as its unhealthiest issuer: one CA that cannot
  # be reached is one CA whose revocations are not being seen.
  defp worst_health(entries) do
    entries = Enum.reject(entries, &is_nil/1)

    cond do
      Enum.any?(entries, & &1.disabled) -> Enum.find(entries, & &1.disabled) |> Map.put(:state, :disabled)
      Enum.any?(entries, & &1.errored) -> Enum.find(entries, & &1.errored) |> Map.put(:state, :errored)
      true -> nil
    end
  end

  defp assign_revocation(socket, trust_anchor) do
    subject = socket.assigns.subject

    issuers = anchor_issuers(trust_anchor)

    endpoints =
      if issuers == [] do
        []
      else
        counts = %{
          crl: Database.count_revocations(issuers, subject),
          ocsp: Database.count_revoked_statuses(issuers, subject)
        }

        issuers
        |> Database.list_revocation_endpoints(subject)
        |> Enum.map(&with_revoked_count(&1, counts))
        |> Enum.sort_by(&X509.describe_name(&1.endpoint.issuer))
      end

    assign(socket, revocation: endpoints)
  end

  defp with_revoked_count(endpoint, counts) do
    by_issuer = if checks_via_list?(endpoint), do: counts.crl, else: counts.ocsp

    %{endpoint: endpoint, revoked_count: Map.get(by_issuer, endpoint.issuer, 0)}
  end

  # A list that we cannot fetch, such as an ldap:// distribution point, is not
  # coverage, so those issuers are checked through their responder instead.
  defp checks_via_list?(endpoint) do
    Enum.any?(endpoint.crl_urls, &String.starts_with?(&1, ["http://", "https://"]))
  end

  defp checked_via(endpoint) do
    if checks_via_list?(endpoint), do: "CRL", else: "OCSP"
  end

  # The primary key is the issuer bytes and the address, and the issuer is DER
  # rather than text, so it is hashed to something that survives a DOM id.
  defp endpoint_key(endpoint) do
    :crypto.hash(:sha256, endpoint.issuer <> endpoint.distribution_point)
    |> Base.url_encode64(padding: false)
  end

  defp failing?(endpoint), do: endpoint.is_disabled or not is_nil(endpoint.errored_at)

  defp checked_at(endpoint), do: endpoint.crl_fetched_at || endpoint.ocsp_checked_at

  # Everything recorded about one endpoint, grouped the way the fetching works:
  # the complete list, the delta published on top of it, and the responder. A
  # CA using only one of the three leaves the other groups out rather than
  # showing a column of blanks.
  defp endpoint_detail_groups(%{endpoint: endpoint, revoked_count: revoked_count}) do
    [
      %{title: "Endpoint", rows: endpoint_rows(endpoint, revoked_count)},
      %{title: "Revocation list", rows: crl_rows(endpoint)},
      %{title: "Delta list", rows: delta_rows(endpoint)},
      %{title: "Responder (OCSP)", rows: ocsp_rows(endpoint)}
    ]
    |> Enum.reject(&(&1.rows == []))
  end

  defp endpoint_rows(endpoint, revoked_count) do
    [
      {"Certificate authority", X509.describe_name(endpoint.issuer)},
      {"Distribution point", endpoint.distribution_point},
      {"Checked via", checked_via(endpoint)},
      {"Revoked certificates", to_string(revoked_count)},
      {"List addresses", format_urls(endpoint.crl_urls)},
      {"Responder addresses", format_urls(endpoint.ocsp_urls)},
      {"Failing since", endpoint.errored_at},
      {"Stopped because", endpoint.is_disabled && endpoint.disabled_reason},
      {"First seen", endpoint.inserted_at}
    ]
    |> drop_blanks()
  end

  defp crl_rows(endpoint) do
    if endpoint.crl_urls == [] do
      []
    else
      [
        {"Last fetched", endpoint.crl_fetched_at || "Never"},
        {"Published", endpoint.crl_this_update},
        {"Expires", endpoint.crl_next_update},
        {"CRL number", endpoint.crl_number && to_string(endpoint.crl_number)},
        {"Error", endpoint.crl_error}
      ]
      |> drop_blanks()
    end
  end

  defp delta_rows(endpoint) do
    [
      {"Last fetched", endpoint.delta_fetched_at},
      {"Published", endpoint.delta_this_update},
      {"Expires", endpoint.delta_next_update},
      {"Delta number", endpoint.delta_number && to_string(endpoint.delta_number)},
      {"Error", endpoint.delta_error}
    ]
    |> drop_blanks()
  end

  defp ocsp_rows(endpoint) do
    if endpoint.ocsp_urls == [] do
      []
    else
      [
        {"Last checked", endpoint.ocsp_checked_at || "Never"},
        {"Error", endpoint.ocsp_error}
      ]
      |> drop_blanks()
    end
  end

  defp format_urls([]), do: nil
  defp format_urls(urls), do: Enum.join(urls, "\n")

  defp drop_blanks(rows) do
    Enum.reject(rows, fn {_label, value} -> value in [nil, "", false] end)
  end

  defp describe_certificate(certificate) do
    with {:ok, [{_type, der, _headers} | _rest]} <- X509.pem_decode(certificate.pem),
         {:ok, otp_cert} <- X509.decode_der_certificate(der) do
      key_info = X509.public_key_info(otp_cert)
      aia = X509.authority_info_access(otp_cert)

      %{
        pem: certificate.pem,
        fingerprint: certificate.fingerprint,
        common_name: X509.subject_common_name(otp_cert),
        subject_name: X509.subject_name(otp_cert),
        issuer_name: X509.issuer_name(otp_cert),
        serial_number: X509.serial_number(otp_cert),
        version: X509.version(otp_cert),
        not_before: X509.not_before(otp_cert),
        not_after: X509.not_after(otp_cert),
        signature_algorithm: X509.signature_algorithm(otp_cert),
        public_key_algorithm: key_info.algorithm,
        public_key_size: key_info.key_size,
        basic_constraints: X509.basic_constraints(otp_cert),
        key_usages: X509.key_usages(otp_cert),
        extended_key_usages: X509.extended_key_usages(otp_cert),
        subject_key_identifier: X509.subject_key_identifier(otp_cert),
        authority_key_identifier: X509.authority_key_identifier(otp_cert),
        subject_alt_names: X509.subject_alt_names(otp_cert),
        crl_distribution_points: otp_cert |> X509.crl_distribution_points() |> List.flatten(),
        ocsp_urls: aia.ocsp,
        ca_issuer_urls: aia.ca_issuers
      }
    else
      _other ->
        %{pem: certificate.pem, fingerprint: certificate.fingerprint, common_name: nil}
    end
  end

  # Ordered label/value pairs for display; fields with nothing to show
  # (nil, empty string, or empty list) are dropped rather than shown blank.
  defp certificate_detail_rows(detail) do
    [
      {"Subject", Map.get(detail, :subject_name)},
      {"Issuer", Map.get(detail, :issuer_name)},
      {"Serial Number", detail |> Map.get(:serial_number) |> format_serial()},
      {"Version", detail |> Map.get(:version) |> format_version()},
      {"Valid From", Map.get(detail, :not_before)},
      {"Expires", Map.get(detail, :not_after)},
      {"Public Key",
       format_public_key(Map.get(detail, :public_key_algorithm), Map.get(detail, :public_key_size))},
      {"Signature Algorithm", Map.get(detail, :signature_algorithm)},
      {"Basic Constraints", detail |> Map.get(:basic_constraints) |> format_basic_constraints()},
      {"Key Usage", detail |> Map.get(:key_usages, []) |> format_list()},
      {"Extended Key Usage", detail |> Map.get(:extended_key_usages, []) |> format_list()},
      {"Subject Key Identifier", Map.get(detail, :subject_key_identifier)},
      {"Authority Key Identifier", Map.get(detail, :authority_key_identifier)},
      {"Subject Alternative Names", detail |> Map.get(:subject_alt_names, []) |> format_list()},
      {"CRL Distribution Points",
       detail |> Map.get(:crl_distribution_points, []) |> format_list()},
      {"OCSP", detail |> Map.get(:ocsp_urls, []) |> format_list()},
      {"CA Issuers", detail |> Map.get(:ca_issuer_urls, []) |> format_list()},
      {"Fingerprint (SHA-256)", Map.get(detail, :fingerprint)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
  end

  defp format_serial(nil), do: nil

  defp format_serial(serial) when is_integer(serial) do
    hex = Integer.to_string(serial, 16)
    hex = if rem(String.length(hex), 2) == 1, do: "0" <> hex, else: hex

    hex
    |> String.downcase()
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &List.to_string/1)
  end

  defp format_version(nil), do: nil
  defp format_version(version), do: version |> Atom.to_string() |> String.trim_leading("v")

  defp format_public_key(nil, _key_size), do: nil
  defp format_public_key(algorithm, nil), do: algorithm
  defp format_public_key(algorithm, key_size), do: "#{algorithm} (#{key_size}-bit)"

  defp format_basic_constraints(nil), do: nil
  defp format_basic_constraints(%{ca: false}), do: "CA:FALSE"
  defp format_basic_constraints(%{ca: true, path_length: nil}), do: "CA:TRUE"

  defp format_basic_constraints(%{ca: true, path_length: path_length}),
    do: "CA:TRUE, pathlen:#{path_length}"

  defp format_list([]), do: nil
  defp format_list(list), do: Enum.join(list, ", ")

  defp download_filename(trust_anchor_name, detail) do
    base = detail.common_name || trust_anchor_name
    suffix = String.slice(detail.fingerprint, 0, 8)
    "#{sanitize_filename(base)}-#{suffix}.pem"
  end

  defp sanitize_filename(name), do: String.replace(name, ~r/[^a-zA-Z0-9._-]+/, "-")

  defp surface_certificate_errors(changeset) do
    cert_changesets = Map.get(changeset.changes, :certificates, [])

    if Enum.any?(cert_changesets, &(not &1.valid?)) do
      add_error(
        changeset,
        :certs,
        "one of these certificates is already used by another trust anchor in this account"
      )
    else
      changeset
    end
  end

  defp upload_error_to_string(:too_large),
    do: "File is too large (max #{div(@max_upload_size, 1_000_000)} MB)."

  defp upload_error_to_string(:not_accepted),
    do: "Unsupported file type. Use .pem, .crt, .cer, .der, or .txt."

  defp upload_error_to_string(:too_many_files),
    do: "Too many files selected (max #{@max_upload_entries})."

  defp upload_error_to_string(_reason), do: "Could not upload file."
end
