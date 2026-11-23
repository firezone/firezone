defmodule PortalWeb.Sites.Components do
  use PortalWeb, :component_library

  attr :state, :map, required: true

  def new_site_panel(assigns) do
    assigns = assign(assigns, assigns.state)

    ~H"""
    <Page.detail_modal id="new-site-panel" size="md" open={@open} on_close="handle_keydown">
      <div :if={@open} class="flex flex-col h-full overflow-hidden">
        <Form.panel_header title="Add a site" close_event="close_new_site_panel">
          <:leading><Core.icon name="ri-route-line" class="w-4 h-4 text-muted" /></:leading>
        </Form.panel_header>
        <div class="flex-1 overflow-y-auto px-6 py-5">
          <.form id="new-site-form" for={@form} phx-change="new_site_change" phx-submit="new_site_submit">
            <div class="space-y-4">
              <Form.input
                label="Name"
                field={@form[:name]}
                placeholder="Enter a name for this site"
                phx-debounce="300"
                required
              />
            </div>
            <div class="flex items-center justify-end gap-2 mt-6">
              <Form.button type="button" phx-click="close_new_site_panel">
                Cancel
              </Form.button>
              <Form.button type="submit" style="primary" disabled={not @form.source.valid?}>
                Create Site
              </Form.button>
            </div>
          </.form>
        </div>
      </div>
    </Page.detail_modal>
    """
  end

  @doc """
  Which device routes for which site, as a grid: a site per row, a device per column,
  a filled square where the device is in the site.
  """
  attr :account, :any, required: true
  attr :sites, :list, required: true
  attr :attachments, :list, required: true
  attr :online_ids, :any, required: true

  def attachment_grid(assigns) do
    devices =
      assigns.attachments
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(16)

    assigns =
      assign(assigns,
        devices: devices,
        attached: MapSet.new(assigns.attachments, fn {device, site_id} -> {site_id, device.id} end)
      )

    ~H"""
    <section :if={@devices != []} id="site-attachments" class="px-6 pt-10 pb-6">
      <h2 class="flex items-center gap-1.5 text-[11px] font-semibold tracking-[.12em] uppercase text-muted mb-3">
        <Core.icon name="ri-grid-line" class="w-3.5 h-3.5" /> Which device routes for which site
      </h2>
      <div class="overflow-x-auto">
        <table class="text-sm">
          <thead>
            <tr class="border-b border-rule">
              <th></th>
              <th :for={device <- @devices} class="px-4 py-2 text-xs font-normal text-fg whitespace-nowrap">
                <Navigation.link navigate={~p"/#{@account}/devices/#{device.id}"} class="inline-flex items-center gap-1.5 hover:underline">
                  <span class={[
                    "inline-block w-[7px] h-[7px] rounded-full shrink-0",
                    MapSet.member?(@online_ids, device.id) && "bg-fg",
                    not MapSet.member?(@online_ids, device.id) && "ring-[1.5px] ring-inset ring-faint"
                  ]}></span>
                  {device.name}
                </Navigation.link>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={site <- @sites} class="border-b border-hair">
              <td class="py-2 pr-10 text-fg whitespace-nowrap">
                <Navigation.link navigate={~p"/#{@account}/sites/#{site.id}"} class="hover:underline">
                  {site.name}
                </Navigation.link>
              </td>
              <td :for={device <- @devices} class="px-4 py-2 text-center">
                <span
                  data-attached={to_string(MapSet.member?(@attached, {site.id, device.id}))}
                  class={[
                    "inline-block w-2.5 h-2.5",
                    MapSet.member?(@attached, {site.id, device.id}) && "bg-fg",
                    not MapSet.member?(@attached, {site.id, device.id}) && "ring-1 ring-inset ring-hair"
                  ]}
                ></span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :site, :any, required: true
  attr :account, :any, required: true
  attr :resources_counts, :map, required: true
  attr :policies_counts, :map, required: true
  attr :panel, :map, required: true
  attr :deploy_state, :map, required: true
  attr :resource_form_state, :map, required: true
  attr :edit_state, :map, required: true
  attr :unified_devices?, :boolean, default: false
  attr :devices_picker, :map, default: nil

  def site_panel(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(
        deploy_env: assigns.deploy_state.env,
        deploy_tab: assigns.deploy_state.tab,
        deploy_connected?: assigns.deploy_state.connected?,
        deploy_token: assigns.deploy_state.token,
        resource_form: assigns.resource_form_state.form,
        filters_dropdown_open: assigns.resource_form_state.filters_dropdown_open,
        active_protocols: assigns.resource_form_state.active_protocols,
        form: assigns.edit_state.form
      )

    filter_ports =
      if assigns.resource_form do
        assigns.resource_form.source
        |> Ecto.Changeset.get_field(:filters, [])
        |> Map.new(fn f -> {f.protocol, Enum.join(f.ports, ", ")} end)
      else
        %{}
      end

    assigns = assign(assigns, :filter_ports, filter_ports)

    # The listed gateways include every online one, and device_tokens is keyed
    # by the id of each gateway holding a single-owner token
    {status, _offline_count} =
      site_health(
        assigns.gateways |> Enum.filter(& &1.online?) |> MapSet.new(& &1.id),
        assigns.device_tokens |> Map.keys() |> MapSet.new()
      )

    assigns = assign(assigns, :status, status)

    ~H"""
    <Page.detail_modal id="site-panel" size="xl" open={not is_nil(@site)} on_close="handle_keydown">
      <div :if={@site} class="flex flex-col min-h-0 h-[80vh] overflow-hidden">
        <.site_panel_header
          :if={@view != :edit_site}
          site={@site}
          view={@view}
          status={@status}
        />

        <.site_overview_view
          :if={@view == :gateways}
          site={@site}
          account={@account}
          panel={@panel}
          gateways={@gateways}
          resources={@resources}
          resources_counts={@resources_counts}
          unified_devices?={@unified_devices?}
        />

        <.site_deploy_view
          :if={@view == :deploy}
          account={@account}
          site={@site}
          deploy_env={@deploy_env}
          deploy_tab={@deploy_tab}
          deploy_connected?={@deploy_connected?}
        />

        <.site_add_resource_view
          :if={@view == :add_resource}
          resource_form={@resource_form}
          filters_dropdown_open={@filters_dropdown_open}
          active_protocols={@active_protocols}
          filter_ports={@filter_ports}
        />

        <.site_edit_view :if={@view == :edit_site} site={@site} form={@form} />

        <.site_add_devices_view
          :if={@unified_devices? and @view == :add_devices and not is_nil(@devices_picker)}
          site={@site}
          picker={@devices_picker}
        />
      </div>
    </Page.detail_modal>
    """
  end

  attr :site, :any, required: true
  attr :view, :atom, required: true
  attr :status, :atom, required: true

  def site_panel_header(assigns) do
    ~H"""
    <div class="shrink-0 px-6 py-4 border-b border-rule">
      <div class="flex items-center gap-4">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <Core.icon
              name={if @site.managed_by == :system, do: "ri-earth-line", else: "ri-route-line"}
              class="w-5 h-5 text-muted shrink-0"
            />
            <h2 class="text-lg font-bold text-fg truncate">{@site.name}</h2>
            <Core.badge :if={@site.managed_by == :system} type="accent" size="xs">system</Core.badge>
            <.site_status_badge status={@status} />
          </div>
          <p class="font-mono text-xs text-muted mt-1 truncate">{@site.id}</p>
        </div>
        <%!-- Right: actions --%>
        <div class="flex items-center gap-1.5 shrink-0">
          <Form.button
            :if={@view == :gateways and @site.managed_by == :account}
            phx-click="open_site_edit_form"
            size="sm"
          >
            <Core.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </Form.button>
          <Form.icon_button
            icon="ri-close-line"
            title="Close (Esc)"
            phx-click={Page.close_modal({:closest, "[data-modal-layer]"}, "close_panel")}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :account, :any, required: true
  attr :panel, :map, required: true
  attr :gateways, :list, required: true
  attr :resources, :list, required: true
  attr :resources_counts, :map, required: true
  attr :unified_devices?, :boolean, default: false

  def site_overview_view(assigns) do
    assigns = assign(assigns, assigns.panel)

    ~H"""
    <div class="flex flex-1 min-h-0 divide-x divide-hair overflow-hidden">
      <div class="flex-1 flex flex-col overflow-hidden">
        <.site_panel_tabs
          site={@site}
          tab={@tab}
          show_all_gateways={@show_all_gateways}
          total_count={@total_gateway_count}
          resource_count={length(@resources)}
          gateway_tokens={@gateway_tokens}
          confirm_revoke_all_tokens={@confirm_revoke_all_tokens}
          unified_devices?={@unified_devices?}
          device_count={length(@devices)}
        />

        <.site_gateways_tab
          :if={@tab == :gateways}
          site={@site}
          gateways={@gateways}
          total_gateway_count={@total_gateway_count}
          gateway_tokens={@gateway_tokens}
          expanded_gateway_id={@expanded_gateway_id}
          confirm_delete_gateway_id={@confirm_delete_gateway_id}
          confirm_rotate_gateway_id={@confirm_rotate_gateway_id}
          rename_gateway_id={@rename_gateway_id}
          gateway_actions_open_id={@gateway_actions_open_id}
          rotated_gateway_token={@rotated_gateway_token}
          device_tokens={@device_tokens}
          unified_devices?={@unified_devices?}
          account={@account}
          devices={@devices}
          confirm_remove_device_id={@confirm_remove_device_id}
        />

        <.site_resources_tab
          :if={@tab == :resources}
          site={@site}
          account={@account}
          resources={@resources}
        />

        <.site_tokens_tab
          :if={@tab == :tokens}
          site={@site}
          gateway_tokens={@gateway_tokens}
          legacy_token_connections={@legacy_token_connections}
          confirm_revoke_token_id={@confirm_revoke_token_id}
          confirm_revoke_all_tokens={@confirm_revoke_all_tokens}
        />
      </div>

      <.site_sidebar site={@site} confirm_delete_site={@confirm_delete_site} />
    </div>
    """
  end

  attr :site, :any, required: true
  attr :tab, :atom, required: true
  attr :show_all_gateways, :boolean, required: true
  attr :total_count, :integer, required: true
  attr :resource_count, :integer, required: true
  attr :gateway_tokens, :list, required: true
  attr :confirm_revoke_all_tokens, :boolean, required: true
  attr :unified_devices?, :boolean, default: false
  attr :device_count, :integer, default: 0

  def site_panel_tabs(assigns) do
    ~H"""
    <div class="flex items-end gap-0 px-5 border-b border-hair bg-hover shrink-0">
      <button
        :if={@unified_devices?}
        id="site-panel-devices-tab"
        phx-click="switch_panel_tab"
        phx-value-tab="devices"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :gateways,
            do: "border-fg text-fg",
            else: "border-transparent text-muted hover:text-fg hover:border-hair"
          )
        ]}
      >
        Devices
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :gateways, do: "bg-hover text-fg", else: "bg-hover text-muted")
        ]}>
          {@total_count + @device_count}
        </span>
      </button>
      <button
        :if={not @unified_devices?}
        phx-click="switch_panel_tab"
        phx-value-tab="gateways"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :gateways,
            do: "border-fg text-fg",
            else:
              "border-transparent text-muted hover:text-fg hover:border-hair"
          )
        ]}
      >
        Gateways
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :gateways,
            do: "bg-hover text-fg",
            else: "bg-hover text-muted"
          )
        ]}>
          {@total_count}
        </span>
      </button>
      <button
        phx-click="switch_panel_tab"
        phx-value-tab="resources"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :resources,
            do: "border-fg text-fg",
            else:
              "border-transparent text-muted hover:text-fg hover:border-hair"
          )
        ]}
      >
        Resources
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :resources,
            do: "bg-hover text-fg",
            else: "bg-hover text-muted"
          )
        ]}>
          {@resource_count}
        </span>
      </button>
      <button
        :if={@gateway_tokens != []}
        phx-click="switch_panel_tab"
        phx-value-tab="tokens"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :tokens,
            do: "border-fg text-fg",
            else: "border-transparent text-muted hover:text-fg hover:border-hair"
          )
        ]}
      >
        Legacy tokens
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :tokens, do: "bg-hover text-fg", else: "bg-hover text-muted")
        ]}>
          {length(@gateway_tokens)}
        </span>
      </button>
      <div class="ml-auto pb-2 flex items-center gap-2">
        <Form.button
          :if={not @unified_devices? and @tab == :gateways}
          phx-click="deploy_gateway"
          size="xs"
        >
          <Core.icon name="ri-add-line" class="w-3 h-3" /> Deploy gateway
        </Form.button>
        <Form.button
          :if={@unified_devices? and @tab == :gateways}
          id="site-add-devices-button"
          phx-click="open_add_devices"
          size="xs"
        >
          <Core.icon name="ri-add-line" class="w-3 h-3" /> Add devices
        </Form.button>
        <Form.button
          :if={@tab == :resources and @site.managed_by == :account}
          phx-click="add_resource"
          size="xs"
        >
          <Core.icon name="ri-add-line" class="w-3 h-3" /> Add resource
        </Form.button>
        <Form.button
          :if={@tab == :gateways and not @show_all_gateways}
          phx-click="show_all_gateways"
          size="xs"
        >
          View all <Core.icon name="ri-arrow-right-line" class="w-3 h-3" />
        </Form.button>
        <Form.button
          :if={@tab == :gateways and @show_all_gateways}
          phx-click="show_online_gateways"
          size="xs"
        >
          Online only
        </Form.button>
        <Form.button
          :if={@tab == :tokens and @gateway_tokens != [] and not @confirm_revoke_all_tokens}
          type="button"
          style="danger"
          size="xs"
          phx-click="confirm_revoke_all_tokens"
        >
          <Core.icon name="ri-delete-bin-line" class="w-3 h-3" /> Revoke all tokens
        </Form.button>
        <div
          :if={@tab == :tokens and @confirm_revoke_all_tokens}
          class="flex items-center gap-2"
        >
          <span class="text-xs text-attn">Revoke all tokens?</span>
          <Form.button type="button" phx-click="cancel_revoke_all_tokens" size="xs">
            Cancel
          </Form.button>
          <Form.button type="button" phx-click="revoke_all_gateway_tokens" style="danger" size="xs">
            Revoke all
          </Form.button>
        </div>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :gateways, :list, required: true
  attr :total_gateway_count, :integer, required: true
  attr :gateway_tokens, :list, default: []
  attr :expanded_gateway_id, :string, default: nil
  attr :confirm_delete_gateway_id, :string, default: nil
  attr :confirm_rotate_gateway_id, :string, default: nil
  attr :rename_gateway_id, :string, default: nil
  attr :gateway_actions_open_id, :string, default: nil
  attr :rotated_gateway_token, :map, default: nil
  attr :device_tokens, :map, default: %{}
  attr :unified_devices?, :boolean, default: false
  attr :account, :any, default: nil
  attr :devices, :list, default: []
  attr :confirm_remove_device_id, :string, default: nil

  def site_gateways_tab(assigns) do
    assigns =
      assign(assigns, :legacy_token_ids, MapSet.new(assigns.gateway_tokens, & &1.id))
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li
          :for={gateway <- @gateways}
          class={[
            "border-b border-hair transition-colors",
            if(@confirm_delete_gateway_id == gateway.id,
              do: "bg-attn-wash",
              else: ""
            )
          ]}
        >
          <% action = token_action(@device_tokens, gateway, @legacy_token_ids) %>
          <% reveal? = @rotated_gateway_token && @rotated_gateway_token.gateway_id == gateway.id %>
          <%!-- Normal clickable row --%>
          <div
            :if={@confirm_delete_gateway_id != gateway.id}
            phx-click="toggle_gateway_expand"
            phx-value-id={gateway.id}
            class="flex items-center gap-3 px-5 py-3 cursor-pointer hover:bg-hover transition-colors group"
          >
            <Core.ping_icon
              color={if gateway.online?, do: "success", else: "danger"}
              title={if gateway.online?, do: "Online", else: "Offline"}
            />
            <div class="flex items-center justify-center w-7 h-7 rounded border border-hair bg-hover shrink-0">
              <svg
                class="w-3.5 h-3.5 text-muted"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <rect x="1.5" y="4" width="13" height="8" rx="1" />
                <circle cx="4" cy="8" r="0.75" fill="currentColor" stroke="none" />
                <circle cx="6.5" cy="8" r="0.75" fill="currentColor" stroke="none" />
                <path d="M10 8h3.5" />
              </svg>
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <p class="font-mono text-sm font-medium text-fg truncate group-hover:text-fg transition-colors">
                  {gateway.name}
                </p>
                <Core.badge :if={@unified_devices?} type="neutral" size="xs">Gateway</Core.badge>
                <Core.badge
                  :if={legacy_connected?(gateway, @legacy_token_ids)}
                  type="warning"
                  size="xs"
                  title="This gateway last connected with a legacy site token"
                >
                  legacy token
                </Core.badge>
              </div>
              <p :if={gateway.last_seen_remote_ip} class="font-mono text-xs text-muted mt-0.5">
                {gateway.last_seen_remote_ip}
              </p>
            </div>
            <Core.actions_dropdown
              open={@gateway_actions_open_id == gateway.id}
              close_event="close_gateway_actions"
              phx-click="toggle_gateway_actions"
              phx-value-id={gateway.id}
              title="More actions"
            >
              <button
                type="button"
                phx-click="rename_gateway"
                phx-value-id={gateway.id}
                class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-muted hover:text-fg hover:bg-hover transition-colors"
              >
                <Core.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Rename gateway
              </button>
              <button
                :if={!reveal?}
                type="button"
                phx-click="rotate_gateway_token"
                phx-value-id={gateway.id}
                class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-muted hover:text-fg hover:bg-hover transition-colors"
              >
                <Core.icon name={token_action_icon(action)} class="w-3.5 h-3.5 shrink-0" />
                {token_action_label(action)}
              </button>
              <button
                type="button"
                phx-click="delete_gateway"
                phx-value-id={gateway.id}
                class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-attn hover:bg-hover transition-colors"
              >
                <Core.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Delete gateway
              </button>
            </Core.actions_dropdown>
            <Core.icon
              name={
                if @expanded_gateway_id == gateway.id,
                  do: "ri-arrow-up-s-line",
                  else: "ri-arrow-down-s-line"
              }
              class="w-4 h-4 text-muted shrink-0"
            />
          </div>
          <%!-- Confirm delete row --%>
          <div
            :if={@confirm_delete_gateway_id == gateway.id}
            class="flex items-center gap-3 px-5 py-3"
          >
            <Core.ping_icon
              color={if gateway.online?, do: "success", else: "danger"}
              title={if gateway.online?, do: "Online", else: "Offline"}
            />
            <div class="flex items-center justify-center w-7 h-7 rounded border border-hair bg-hover shrink-0">
              <svg
                class="w-3.5 h-3.5 text-muted"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <rect x="1.5" y="4" width="13" height="8" rx="1" />
                <circle cx="4" cy="8" r="0.75" fill="currentColor" stroke="none" />
                <circle cx="6.5" cy="8" r="0.75" fill="currentColor" stroke="none" />
                <path d="M10 8h3.5" />
              </svg>
            </div>
            <div class="flex-1 min-w-0">
              <p class="font-mono text-sm font-medium text-fg truncate">{gateway.name}</p>
              <p :if={gateway.last_seen_remote_ip} class="font-mono text-xs text-muted mt-0.5">
                {gateway.last_seen_remote_ip}
              </p>
            </div>
            <span class="text-xs text-attn shrink-0">Delete this gateway?</span>
            <Form.button type="button" phx-click="cancel_delete_gateway" size="xs">
              Cancel
            </Form.button>
            <Form.button
              type="button"
              style="danger"
              size="xs"
              phx-click="confirm_delete_gateway"
              phx-value-id={gateway.id}
            >
              Delete
            </Form.button>
          </div>
          <%!-- Expanded details --%>
          <div
            :if={@expanded_gateway_id == gateway.id and @confirm_delete_gateway_id != gateway.id}
            class="px-5 pb-3 pt-1 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5"
          >
            <span class="text-xs text-muted">Last started</span>
            <span class="text-xs text-fg">
              <Core.relative_datetime
                datetime={gateway.last_seen_at}
                popover={false}
                empty="Unknown"
              />
            </span>
            <span class="text-xs text-muted">Remote IP</span>
            <span class="text-xs text-fg">
              <Core.last_seen schema={gateway} />
            </span>
            <span class="text-xs text-muted">Version</span>
            <span class="font-mono text-xs text-fg">
              {gateway.last_seen_version}
            </span>
            <span class="text-xs text-muted">User agent</span>
            <span class="font-mono text-xs text-fg break-all">
              {gateway.last_seen_user_agent}
            </span>
            <span class="text-xs text-muted">Tunnel IPv4</span>
            <span class="font-mono text-xs text-fg">
              {gateway.ipv4}
            </span>
            <span class="text-xs text-muted">Tunnel IPv6</span>
            <span class="font-mono text-xs text-fg">
              {gateway.ipv6}
            </span>
            <span class="text-xs text-muted">Token</span>
            <span class="text-xs text-fg">
              {gateway_token_status(gateway, Map.get(@device_tokens, gateway.id), @legacy_token_ids)}
            </span>
          </div>
          <%!-- Token rotation controls --%>
          <div
            :if={@expanded_gateway_id == gateway.id and @confirm_delete_gateway_id != gateway.id}
            class="px-5 pb-3 space-y-2"
          >
            <.gateway_token_controls
              gateway={gateway}
              device_tokens={@device_tokens}
              legacy_token_ids={@legacy_token_ids}
              rotated_gateway_token={@rotated_gateway_token}
              rename_gateway_id={@rename_gateway_id}
              confirm_rotate_gateway_id={@confirm_rotate_gateway_id}
            />
          </div>
        </li>
        <li
          :for={device <- @devices}
          id={"site-device-#{device.id}"}
          class={[
            "border-b border-hair transition-colors",
            if(@confirm_remove_device_id == device.id, do: "bg-attn-wash", else: "")
          ]}
        >
          <div class="flex items-center gap-3 px-5 py-3">
            <Core.ping_icon
              color={if device.online?, do: "success", else: "danger"}
              title={if device.online?, do: "Online", else: "Offline"}
            />
            <div class="flex items-center justify-center w-7 h-7 rounded border border-hair bg-hover shrink-0">
              <PortalWeb.Devices.Components.device_os_icon device={device} />
            </div>
            <div class="flex-1 min-w-0">
              <Navigation.link
                navigate={~p"/#{@account}/devices/#{device.id}"}
                class="block font-mono text-sm font-medium text-fg truncate hover:text-fg transition-colors"
              >
                {device.name}
              </Navigation.link>
              <p class="text-xs text-muted mt-0.5 truncate">
                {PortalWeb.Devices.Components.os_name_and_version(device.last_seen_user_agent)}
                <span :if={device.last_seen_remote_ip} class="font-mono">
                  {device.last_seen_remote_ip}
                </span>
              </p>
              <p :if={not device.online?} class="text-xs text-attn mt-0.5">
                {offline_note(device)}
              </p>
            </div>
            <Form.button
              :if={@confirm_remove_device_id != device.id}
              type="button"
              size="xs"
              phx-click="remove_site_device"
              phx-value-id={device.id}
            >
              Remove from site
            </Form.button>
            <div
              :if={@confirm_remove_device_id == device.id}
              class="flex items-center gap-2 shrink-0"
            >
              <span class="text-xs text-attn">Stop routing for this site?</span>
              <Form.button type="button" phx-click="cancel_remove_site_device" size="xs">
                Cancel
              </Form.button>
              <Form.button
                type="button"
                style="danger"
                size="xs"
                phx-click="confirm_remove_site_device"
                phx-value-id={device.id}
              >
                Remove
              </Form.button>
            </div>
          </div>
        </li>
      </ul>
      <div
        :if={@unified_devices? and @gateways == [] and @total_gateway_count == 0 and @devices == []}
        id="site-devices-empty"
        class="flex flex-col items-center justify-center gap-3 py-16"
      >
        <Core.icon name="ri-computer-line" class="w-6 h-6 text-faint" />
        <p class="text-sm text-muted">No devices serve this site yet.</p>
        <Form.button phx-click="open_add_devices" size="sm" icon="ri-add-line">
          Add devices
        </Form.button>
      </div>
      <div
        :if={not @unified_devices? and @gateways == [] and @total_gateway_count == 0 and @devices == []}
        class="flex flex-col items-center justify-center gap-3 py-16"
      >
        <p class="text-sm text-muted">No gateways deployed to this site.</p>
        <button
          phx-click="deploy_gateway"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium border border-hair text-muted hover:text-fg hover:border-rule bg-bg transition-colors"
        >
          <Core.icon name="ri-add-line" class="w-3.5 h-3.5" /> Deploy a gateway
        </button>
      </div>
      <div
        :if={@gateways == [] and @total_gateway_count > 0}
        class="flex items-center justify-center py-16"
      >
        <p class="text-sm text-muted">
          {if @unified_devices?,
            do: "None of this site's devices are online.",
            else: "No gateways are currently online."}
        </p>
      </div>
    </div>
    """
  end

  attr :gateway, :any, required: true
  attr :device_tokens, :map, required: true
  attr :legacy_token_ids, :any, required: true
  attr :rotated_gateway_token, :map, default: nil
  attr :rename_gateway_id, :string, default: nil
  attr :confirm_rotate_gateway_id, :string, default: nil

  def gateway_token_controls(assigns) do
    assigns =
      assign(assigns,
        action: token_action(assigns.device_tokens, assigns.gateway, assigns.legacy_token_ids),
        reveal?:
          assigns.rotated_gateway_token &&
            assigns.rotated_gateway_token.gateway_id == assigns.gateway.id
      )

    ~H"""
    <div
      :if={@reveal?}
      id={"gateway-token-reveal-#{@gateway.id}"}
      phx-hook="CopyClipboard"
      class="rounded-md border-2 border-fg bg-hover p-4 space-y-3"
    >
      <div class="flex items-center gap-2">
        <Core.icon name="ri-key-2-line" class="w-4 h-4 text-fg" />
        <span class="text-xs font-semibold text-fg">New gateway token</span>
      </div>
      <p class="text-xs text-fg">
        Copy it now - it won't be shown again.
        <span :if={rotation_pending?(@device_tokens, @gateway.id)}>
          The expiring token keeps working until this gateway connects with the
          replacement, or 4 hours pass.
        </span>
        <span :if={legacy_connected?(@gateway, @legacy_token_ids)}>
          The legacy site token keeps working until you revoke it from the Legacy tokens tab.
        </span>
        <span :if={@rotated_gateway_token.replaced_unused}>
          The previous token was never used and has been replaced - it no longer works.
        </span>
      </p>
      <code
        id={"gateway-token-reveal-#{@gateway.id}-code"}
        class="block w-full rounded border border-hair bg-bg p-2 font-mono text-xs text-fg break-all"
        phx-no-format
      >{@rotated_gateway_token.encoded}</code>
      <div class="flex items-center gap-2">
        <Form.button
          type="button"
          size="xs"
          style="primary"
          data-copy-to-clipboard-target={"gateway-token-reveal-#{@gateway.id}-code"}
        >
          <span
            id={"gateway-token-reveal-#{@gateway.id}-default-message"}
            class="inline-flex items-center gap-1.5"
          >
            <Core.icon name="ri-clipboard-line" class="w-3.5 h-3.5" /> Copy token
          </span>
          <span
            id={"gateway-token-reveal-#{@gateway.id}-success-message"}
            class="hidden items-center gap-1.5"
          >
            <Core.icon name="ri-check-line" class="w-3.5 h-3.5" /> Copied
          </span>
        </Form.button>
        <Form.button type="button" size="xs" phx-click="dismiss_rotated_gateway_token">
          Done
        </Form.button>
      </div>
    </div>
    <form
      :if={@rename_gateway_id == @gateway.id}
      phx-submit="save_gateway_name"
      class="rounded border border-hair bg-hover p-3 space-y-3"
    >
      <label
        for={"rename-gateway-#{@gateway.id}"}
        class="block text-xs font-medium text-fg"
      >
        Rename gateway
      </label>
      <input
        id={"rename-gateway-#{@gateway.id}"}
        type="text"
        name="name"
        value={@gateway.name}
        maxlength="255"
        required
        autocomplete="off"
        class="block w-full rounded border border-hair bg-transparent px-2 py-1.5 font-mono text-xs text-fg"
      />
      <div class="flex items-center gap-2">
        <Form.button type="button" size="xs" phx-click="cancel_rename_gateway">
          Cancel
        </Form.button>
        <Form.button type="submit" size="xs">
          Save
        </Form.button>
      </div>
    </form>
    <div
      :if={@confirm_rotate_gateway_id == @gateway.id}
      class="rounded border border-hair bg-hover p-3 space-y-3"
    >
      <p :if={@action == :rotate} class="text-xs text-fg">
        <span class="font-medium">Rotate this gateway's token?</span><br />
        <% active_state = active_token_state(@device_tokens, @gateway) %>
        <span :if={active_state == :in_use}>
          The current token keeps working until the gateway connects with the new token,
          or 4 hours pass - whichever comes first.
        </span>
        <span :if={active_state == :never_used}>
          This gateway has never connected with its current token,
          so it will be replaced immediately.
        </span>
        <span :if={active_state == :none}>
          This issues a new gateway token.
        </span>
      </p>
      <p :if={@action == :upgrade} class="text-xs text-fg">
        <span class="font-medium">Upgrade this gateway to its own token?</span><br />
        This issues a gateway token that only this gateway can use, replacing its
        legacy site token.
        <span :if={has_gateway_token?(@device_tokens, @gateway.id)}>
          The unused gateway token from the earlier upgrade will be replaced.
        </span>
        The legacy site token keeps working until you revoke it
        from the Legacy tokens tab.
      </p>
      <p :if={@action == :generate} class="text-xs text-fg">
        <span class="font-medium">Generate a gateway token?</span><br />
        This issues a gateway token that only this gateway can use.
      </p>
      <div class="flex items-center gap-2">
        <Form.button type="button" size="xs" phx-click="cancel_rotate_gateway_token">
          Cancel
        </Form.button>
        <Form.button
          type="button"
          size="xs"
          phx-click="confirm_rotate_gateway_token"
          phx-value-id={@gateway.id}
        >
          {token_action_confirm_label(@action)}
        </Form.button>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :account, :any, required: true
  attr :resources, :list, required: true

  def site_resources_tab(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li :for={resource <- @resources} class="border-b border-hair">
          <Navigation.link
            navigate={~p"/#{@account}/resources/#{resource.id}"}
            class="flex items-center gap-3 px-5 py-3 hover:bg-hover transition-colors group"
          >
            <div class={[
              "shrink-0 flex",
              ResourceType.type_badge_col_class(Enum.map(@resources, & &1.type))
            ]}>
              <span class={ResourceType.type_badge_class(resource.type)}>
                {ResourceType.resource_type_label(resource.type)}
              </span>
            </div>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-fg truncate group-hover:text-fg transition-colors">
                {resource.name}
              </p>
              <p class="font-mono text-xs text-muted mt-0.5">
                {resource.address}
              </p>
            </div>
          </Navigation.link>
        </li>
      </ul>
      <div :if={@resources == []} class="flex flex-col items-center justify-center gap-3 py-16">
        <p class="text-sm text-muted">No resources assigned to this site.</p>
        <Form.button :if={@site.managed_by == :account} phx-click="add_resource" size="xs">
          <Core.icon name="ri-add-line" class="w-3.5 h-3.5" /> Add a resource
        </Form.button>
      </div>
    </div>
    """
  end

  attr :site, :any, required: true
  attr :picker, :map, required: true

  def site_add_devices_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <Form.panel_header title="Add devices" close_event="close_add_devices" />
      <form
        id="site-add-devices-form"
        phx-submit="add_devices_submit"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-2">
          <p class="text-xs text-muted">
            Picked devices route traffic for {@site.name}. A device can route for one site, and
            only on the latest Firezone client.
          </p>
          <PortalWeb.Resources.Components.device_picker
            selected_devices={@picker.selected_devices}
            device_search={@picker.device_search}
            device_search_results={@picker.device_search_results}
            device_search_online_only={@picker.device_search_online_only?}
            device_search_recently_seen={@picker.device_search_recently_seen?}
            device_search_loading={@picker.device_search_loading?}
            unavailable={unavailable_reasons(@picker.device_search_results)}
            notes={offline_notes(@picker.device_search_results)}
          />
        </div>
        <Form.panel_footer>
          <Form.panel_footer_button type="button" phx-click="close_add_devices">
            Cancel
          </Form.panel_footer_button>
          <Form.panel_footer_button
            type="submit"
            style="primary"
            disabled={@picker.selected_devices == []}
          >
            {add_devices_label(length(@picker.selected_devices))}
          </Form.panel_footer_button>
        </Form.panel_footer>
      </form>
    </div>
    """
  end

  defp add_devices_label(1), do: "Add 1 device"
  defp add_devices_label(count), do: "Add #{count} devices"

  defp offline_notes(%{devices: devices}) do
    for device <- devices, not device.online?, into: %{}, do: {device.id, offline_note(device)}
  end

  defp offline_notes(_results), do: %{}

  defp offline_note(%{last_seen_at: nil}),
    do: "Offline, never seen. It routes for this site once it connects."

  defp offline_note(%{last_seen_at: last_seen_at}),
    do: "Offline, last seen #{PortalWeb.Format.relative_datetime(last_seen_at)}. It routes for this site once it connects."

  defp unavailable_reasons(%{unavailable: unavailable}) do
    Map.new(unavailable, fn
      {id, {:site, site_name}} -> {id, "Routes for #{site_name}"}
      {id, :outdated} -> {id, "Update to the latest Firezone client to route for a site"}
    end)
  end

  defp unavailable_reasons(_results), do: %{}

  attr :site, :any, required: true
  attr :gateway_tokens, :list, required: true
  attr :legacy_token_connections, :map, default: %{}
  attr :confirm_revoke_token_id, :string, default: nil
  attr :confirm_revoke_all_tokens, :boolean, required: true

  def site_tokens_tab(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li
          :for={token <- @gateway_tokens}
          class={[
            "border-b border-hair px-5 py-3 transition-colors",
            if(@confirm_revoke_token_id == token.id, do: "bg-attn-wash", else: "")
          ]}
        >
          <div class="flex items-center gap-3">
            <div class="flex items-center justify-center w-7 h-7 rounded border border-hair bg-hover shrink-0">
              <Core.icon name="ri-key-line" class="w-3.5 h-3.5 text-muted" />
            </div>
            <div class="flex-1 min-w-0">
              <p class="font-mono text-xs text-fg truncate">{token.id}</p>
              <p class="text-[10px] text-muted mt-0.5">
                Created <Core.relative_datetime datetime={token.inserted_at} popover={false} />
              </p>
            </div>
            <.legacy_token_usage_badge count={Map.get(@legacy_token_connections, token.id, 0)} />
            <Form.icon_button
              :if={@confirm_revoke_token_id != token.id}
              icon="ri-delete-bin-line"
              title="Revoke token"
              phx-click="revoke_gateway_token"
              phx-value-id={token.id}
              class="text-muted hover:text-attn shrink-0"
            />
            <div :if={@confirm_revoke_token_id == token.id} class="flex items-center gap-2 shrink-0">
              <span class="text-xs text-attn">Revoke this token?</span>
              <Form.button type="button" phx-click="cancel_revoke_gateway_token" size="xs">
                Cancel
              </Form.button>
              <Form.button
                type="button"
                style="danger"
                size="xs"
                phx-click="confirm_revoke_gateway_token"
                phx-value-id={token.id}
              >
                Revoke
              </Form.button>
            </div>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :count, :integer, required: true

  defp legacy_token_usage_badge(assigns) do
    ~H"""
    <span
      :if={@count == 0}
      class="shrink-0 px-1.5 py-0.5 rounded text-[10px] font-semibold bg-hover text-muted"
      title="No gateways are currently connected with this token"
    >
      unused
    </span>
    <span
      :if={@count > 0}
      class="shrink-0 px-1.5 py-0.5 rounded text-[10px] font-semibold bg-hover text-fg"
      title="Gateways currently connected with this token"
    >
      {@count} connected
    </span>
    """
  end

  defp has_gateway_token?(device_tokens, gateway_id) do
    Map.get(device_tokens, gateway_id, []) != []
  end

  # An active token existed before but no rotated sibling remains: the
  # never-used token was replaced outright rather than put in grace
  def replaced_unused_token?(prior_tokens, tokens) do
    Enum.any?(prior_tokens, &is_nil(&1.rotated_at)) and not Enum.any?(tokens, & &1.rotated_at)
  end

  defp rotation_pending?(device_tokens, gateway_id) do
    device_tokens |> Map.get(gateway_id, []) |> Enum.any?(& &1.rotated_at)
  end

  # Whether the gateway's active single-owner token is actually in use.
  # token_id is a proxy for the server-side "referenced by a device"
  # check that decides between grace-period rotation and outright
  # replacement - it matches exactly for never-connected gateways.
  defp active_token_state(device_tokens, gateway) do
    active =
      device_tokens
      |> Map.get(gateway.id, [])
      |> Enum.find(&is_nil(&1.rotated_at))

    cond do
      is_nil(active) -> :none
      gateway.token_id == active.id -> :in_use
      true -> :never_used
    end
  end

  defp legacy_connected?(gateway, legacy_token_ids) do
    gateway.token_id != nil and
      MapSet.member?(legacy_token_ids, gateway.token_id)
  end

  # A gateway still connected with a legacy token is mid-upgrade even if a
  # single-owner token was already minted for it - the upgrade only "sticks"
  # once the gateway reconnects with its own token.
  def token_action(device_tokens, gateway, legacy_token_ids) do
    cond do
      legacy_connected?(gateway, legacy_token_ids) -> :upgrade
      has_gateway_token?(device_tokens, gateway.id) -> :rotate
      true -> :generate
    end
  end

  def token_action_icon(:rotate), do: "ri-refresh-line"
  def token_action_icon(:upgrade), do: "ri-arrow-up-circle-line"
  def token_action_icon(:generate), do: "ri-key-line"

  def token_action_label(:rotate), do: "Rotate token"
  def token_action_label(:upgrade), do: "Upgrade token"
  def token_action_label(:generate), do: "Generate token"

  defp token_action_confirm_label(:rotate), do: "Rotate"
  defp token_action_confirm_label(:upgrade), do: "Upgrade"
  defp token_action_confirm_label(:generate), do: "Generate"

  # Leads with what the gateway is connected with (or last connected with,
  # when offline), then notes an unused gateway token when one exists.
  def gateway_token_status(gateway, tokens, legacy_token_ids) do
    tokens = tokens || []
    active = Enum.find(tokens, &is_nil(&1.rotated_at))
    rotated = Enum.find(tokens, & &1.rotated_at)

    live_token_status(gateway, active, rotated) ||
      session_token_status(gateway, active, rotated, legacy_token_ids)
  end

  # For online gateways the live PG registry is authoritative: sessions are
  # written through an async queue, so the latest session can lag a reconnect
  # by several seconds (and token deletion cascades the old ones away).
  defp live_token_status(%{online?: false}, _active, _rotated), do: nil

  defp live_token_status(_gateway, active, rotated) do
    cond do
      active != nil and live_connection?(active) ->
        "Connected with gateway token"

      rotated != nil and live_connection?(rotated) ->
        expiring_status("Connected with", active)

      true ->
        nil
    end
  end

  defp session_token_status(gateway, active, rotated, legacy_token_ids) do
    verb = if gateway.online?, do: "Connected with", else: "Last connected with"

    cond do
      is_nil(gateway.last_seen_at) and active ->
        "Never connected - Gateway token provisioned"

      is_nil(gateway.last_seen_at) ->
        "Never connected - No token provisioned"

      active && gateway.token_id == active.id ->
        "#{verb} gateway token"

      rotated && gateway.token_id == rotated.id ->
        expiring_status(verb, active)

      MapSet.member?(legacy_token_ids, gateway.token_id) ->
        with_unused_token_note("#{verb} legacy site token", active)

      true ->
        with_unused_token_note("#{verb} revoked token", active)
    end
  end

  # Gateway channels join the PG group under their token id at registration
  defp live_connection?(token), do: Portal.PG.members(token.id) != []

  defp expiring_status(verb, nil) do
    "#{verb} expiring gateway token - No replacement provisioned"
  end

  defp expiring_status(verb, _active) do
    "#{verb} expiring gateway token - Replacement provisioned, but never used"
  end

  defp with_unused_token_note(status, nil), do: status

  defp with_unused_token_note(status, _active) do
    status <> " - Gateway token provisioned, but never used"
  end

  attr :site, :any, required: true
  attr :confirm_delete_site, :boolean, required: true

  def site_sidebar(assigns) do
    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <.site_details_section site={@site} />
      <div :if={@site.managed_by == :account} class="border-t border-hair"></div>
      <.site_danger_zone
        :if={@site.managed_by == :account}
        confirm_delete_site={@confirm_delete_site}
      />
    </div>
    """
  end

  attr :site, :any, required: true

  def site_details_section(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-muted mb-3">
        Details
      </h3>
      <dl class="space-y-2.5">
        <div>
          <dt class="text-[10px] text-muted mb-0.5">Name</dt>
          <dd class="text-xs text-fg truncate font-medium" title={@site.name}>
            {@site.name}
          </dd>
        </div>
        <div>
          <dt class="text-[10px] text-muted mb-0.5">ID</dt>
          <dd class="font-mono text-[11px] text-fg break-all font-medium">
            {@site.id}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :confirm_delete_site, :boolean, required: true

  def site_danger_zone(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-attn mb-3">
        Danger Zone
      </h3>
      <button
        :if={not @confirm_delete_site}
        type="button"
        phx-click="confirm_delete_site"
        class="w-full flex items-center gap-2 px-3 py-2 rounded border border-attn/20 text-xs text-attn hover:bg-attn-wash transition-colors"
      >
        <Core.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete site
      </button>
      <div
        :if={@confirm_delete_site}
        class="rounded border border-attn/20 bg-attn-wash p-3 space-y-3"
      >
        <p class="text-xs text-attn">
          <span class="font-medium">Delete this Site?</span>
          <br />
          All associated gateways and resources will also be permanently deleted.
        </p>
        <div class="flex items-center gap-2">
          <Form.button type="button" phx-click="cancel_delete_site" size="xs">
            Cancel
          </Form.button>
          <Form.button type="button" phx-click="delete_site" style="danger" size="xs" class="font-medium">
            Delete site
          </Form.button>
        </div>
      </div>
    </section>
    """
  end

  attr :account, :any, required: true
  attr :site, :any, required: true
  attr :deploy_env, :any, default: nil
  attr :deploy_tab, :string, required: true
  attr :deploy_connected?, :boolean, required: true

  def site_deploy_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <.site_deploy_header />
      <div class="flex-1 overflow-y-auto">
        <.site_deploy_tabs deploy_tab={@deploy_tab} />
        <.site_deploy_instructions deploy_tab={@deploy_tab} deploy_env={@deploy_env} />
      </div>
      <div class="shrink-0 px-5 py-3 border-t border-hair bg-hover flex items-center justify-between gap-4">
        <p class="text-xs text-muted">
          Gateway not connecting? See our
          <Navigation.website_link path="/kb/administer/troubleshooting" fragment="gateway-not-connecting">
            troubleshooting guide.
          </Navigation.website_link>
        </p>
        <Core.initial_connection_status
          :if={@deploy_env}
          type="gateway"
          navigate={~p"/#{@account}/sites/#{@site}"}
          connected?={@deploy_connected?}
        />
      </div>
    </div>
    """
  end

  def site_deploy_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-hair bg-bg">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-fg">Deploy a Gateway</h2>
        <Form.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_deploy" />
      </div>
    </div>
    """
  end

  attr :deploy_tab, :string, required: true

  def site_deploy_tabs(assigns) do
    ~H"""
    <div class="p-5 border-b border-hair">
      <p class="text-sm text-fg mb-3">
        Choose your deployment environment:
      </p>
      <div class="grid grid-cols-2 md:grid-cols-5 gap-2">
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="debian-instructions"
          label="Debian/Ubuntu"
          icon="icon-os-debian"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="systemd-instructions"
          label="systemd"
          icon="ri-terminal-line"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="docker-instructions"
          label="Docker"
          icon="icon-docker"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="terraform-instructions"
          label="Terraform"
          icon="icon-terraform"
        />
        <.deploy_tab_button
          deploy_tab={@deploy_tab}
          value="custom-instructions"
          label="Custom"
          icon="ri-tools-line"
        />
      </div>
    </div>
    """
  end

  attr :deploy_tab, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  def deploy_tab_button(assigns) do
    ~H"""
    <button
      phx-click="deploy_tab_selected"
      phx-value-tab={@value}
      class={[
        "flex items-center justify-center gap-1.5 px-3 py-2 rounded text-xs font-medium border transition-colors",
        if(@deploy_tab == @value,
          do: "border-fg bg-hover text-fg",
          else:
            "border-hair text-muted hover:text-fg hover:bg-hover"
        )
      ]}
    >
      <Core.icon name={@icon} class="w-3.5 h-3.5 shrink-0" />
      {@label}
    </button>
    """
  end

  attr :deploy_tab, :string, required: true
  attr :deploy_env, :any, default: nil

  def site_deploy_instructions(assigns) do
    ~H"""
    <.site_deploy_debian :if={@deploy_tab == "debian-instructions"} deploy_env={@deploy_env} />
    <.site_deploy_systemd :if={@deploy_tab == "systemd-instructions"} deploy_env={@deploy_env} />
    <.site_deploy_docker :if={@deploy_tab == "docker-instructions"} deploy_env={@deploy_env} />
    <.site_deploy_terraform
      :if={@deploy_tab == "terraform-instructions"}
      deploy_env={@deploy_env}
    />
    <.site_deploy_custom :if={@deploy_tab == "custom-instructions"} deploy_env={@deploy_env} />
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_docker(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-fg">Run this command on your host:</p>
      <Core.code_block
        id="deploy-code-docker"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_docker_command(@deploy_env) %></Core.code_block>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_systemd(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-fg">Install via systemd:</p>
      <Core.code_block
        id="deploy-code-systemd"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_systemd_command(@deploy_env) %></Core.code_block>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_debian(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-fg">
        Step 1: Add the Firezone APT repository:
      </p>
      <Core.code_block
        id="deploy-code-debian-repo"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_apt_repository() %></Core.code_block>

      <p class="text-xs text-fg">
        Step 2: Install the Firezone Gateway:
      </p>
      <Core.code_block
        id="deploy-code-debian-install"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_install(@deploy_env) %></Core.code_block>

      <p class="text-xs text-fg">
        Step 3: Authenticate the Firezone Gateway:
      </p>
      <Core.code_block
        id="deploy-code-debian-auth"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_debian_authenticate() %></Core.code_block>

      <p class="text-xs text-fg">
        Step 4: Use this token when prompted:
      </p>
      <Core.code_block
        id="deploy-code-debian-token"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_token(@deploy_env) %></Core.code_block>

      <p class="text-xs text-fg">
        Step 5: You are now ready to manage the Gateway using the <code class="font-mono">firezone</code>
        CLI.
      </p>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_custom(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-fg">
        Step 1: Download the latest binary for your architecture:
      </p>
      <p>
        <Navigation.website_link path="/changelog">Firezone changelog</Navigation.website_link>
      </p>

      <p class="text-xs text-fg">
        Step 2: Set required environment variables:
      </p>
      <Core.code_block
        id="deploy-code-custom-env"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_manual_env(@deploy_env) %></Core.code_block>

      <p class="text-xs text-fg">
        Step 3: Enable packet forwarding for IPv4 and IPv6:
      </p>
      <Core.code_block
        id="deploy-code-custom-forwarding"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_manual_forwarding() %></Core.code_block>

      <p class="text-xs text-fg">
        Step 4: Enable masquerading for ethernet and Wi-Fi interfaces:
      </p>
      <Core.code_block
        id="deploy-code-custom-masquerading"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_manual_masquerading() %></Core.code_block>

      <p class="text-xs text-fg">
        Step 5: Run the binary you downloaded:
      </p>
      <Core.code_block
        id="deploy-code-custom-run"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= "sudo ./firezone-gateway-<version>-<architecture>" %></Core.code_block>

      <p class="text-xs text-fg">
        Make sure to save the <code class="font-mono">FIREZONE_TOKEN</code>
        shown above to a secure location before continuing. It won't be shown again.
      </p>
    </div>
    """
  end

  attr :deploy_env, :any, default: nil

  def site_deploy_terraform(assigns) do
    ~H"""
    <div class="p-5 space-y-4">
      <p class="text-xs text-fg">
        Use `FIREZONE_TOKEN` in your Terraform-managed gateway environment:
      </p>
      <Core.code_block
        id="deploy-code-terraform"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_token(@deploy_env) %></Core.code_block>
      <p :if={gateway_api_url(@deploy_env)} class="text-xs text-fg">
        Set `FIREZONE_API_URL` to:
      </p>
      <Core.code_block
        :if={gateway_api_url(@deploy_env)}
        id="deploy-code-terraform-api-url"
        class="w-full text-xs whitespace-pre-line"
        phx-no-format
        phx-update="ignore"
      ><%= gateway_api_url(@deploy_env) %></Core.code_block>
      <p class="text-xs text-fg">
        <Navigation.website_link path="/kb/automate">Terraform guides</Navigation.website_link>
      </p>
    </div>
    """
  end

  attr :resource_form, :any, default: nil
  attr :filters_dropdown_open, :boolean, required: true
  attr :active_protocols, :list, required: true
  attr :filter_ports, :map, required: true

  def site_add_resource_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <.site_add_resource_header />
      <.form
        :if={@resource_form}
        id="site-add-resource-form"
        for={@resource_form}
        phx-submit="resource_submit"
        phx-change="resource_change"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <.resource_type_picker resource_form={@resource_form} />
          <.resource_primary_fields resource_form={@resource_form} />
          <.resource_dns_stack
            :if={"#{@resource_form[:type].value}" == "dns"}
            resource_form={@resource_form}
          />
          <.resource_filters_section
            filters_dropdown_open={@filters_dropdown_open}
            active_protocols={@active_protocols}
            filter_ports={@filter_ports}
          />
        </div>
        <.resource_form_actions />
      </.form>
    </div>
    """
  end

  def site_add_resource_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-hair bg-bg">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-fg">Add Resource</h2>
        <Form.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_add_resource" />
      </div>
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_type_picker(assigns) do
    ~H"""
    <div>
      <span class="block text-xs font-medium text-fg mb-1.5">
        Type <span class="text-attn">*</span>
      </span>
      <ul class="grid w-full gap-3 grid-cols-3">
        <li>
          <Form.input
            id="panel-resource-form-type--dns"
            type="radio_button_group"
            field={@resource_form[:type]}
            value="dns"
            checked={to_string(@resource_form[:type].value) == "dns"}
            required
          />
          <label
            for="panel-resource-form-type--dns"
            class="inline-flex items-center justify-between w-full p-3 text-fg bg-bg border border-hair rounded cursor-pointer peer-checked:border-fg peer-checked:text-muted hover:text-fg hover:bg-hover transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <Core.icon name="ri-global-line" class="w-4 h-4 mr-1" /> DNS
              </div>
              <div class="w-full text-[10px]">By DNS address</div>
            </div>
          </label>
        </li>
        <li>
          <Form.input
            id="panel-resource-form-type--ip"
            type="radio_button_group"
            field={@resource_form[:type]}
            value="ip"
            checked={to_string(@resource_form[:type].value) == "ip"}
            required
          />
          <label
            for="panel-resource-form-type--ip"
            class="inline-flex items-center justify-between w-full p-3 text-fg bg-bg border border-hair rounded cursor-pointer peer-checked:border-fg peer-checked:text-muted hover:text-fg hover:bg-hover transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <Core.icon name="ri-server-line" class="w-4 h-4 mr-1" /> IP
              </div>
              <div class="w-full text-[10px]">By IP address</div>
            </div>
          </label>
        </li>
        <li>
          <Form.input
            id="panel-resource-form-type--cidr"
            type="radio_button_group"
            field={@resource_form[:type]}
            value="cidr"
            checked={to_string(@resource_form[:type].value) == "cidr"}
            required
          />
          <label
            for="panel-resource-form-type--cidr"
            class="inline-flex items-center justify-between w-full p-3 text-fg bg-bg border border-hair rounded cursor-pointer peer-checked:border-fg peer-checked:text-muted hover:text-fg hover:bg-hover transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <Core.icon name="ri-server-line" class="w-4 h-4 mr-1" /> CIDR
              </div>
              <div class="w-full text-[10px]">By CIDR range</div>
            </div>
          </label>
        </li>
      </ul>
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_primary_fields(assigns) do
    ~H"""
    <div>
      <label
        for={@resource_form[:address].id}
        class="block text-xs font-medium text-fg mb-1.5"
      >
        Address <span class="text-attn">*</span>
      </label>
      <Form.input
        field={@resource_form[:address]}
        autocomplete="off"
        placeholder={
          cond do
            to_string(@resource_form[:type].value) == "dns" -> "gitlab.company.com"
            to_string(@resource_form[:type].value) == "cidr" -> "10.0.0.0/24"
            to_string(@resource_form[:type].value) == "ip" -> "10.3.2.1"
            true -> "First select a type above"
          end
        }
        disabled={is_nil(@resource_form[:type].value)}
        phx-debounce="300"
        required
        class="font-mono"
      />
    </div>
    <div>
      <label
        for={@resource_form[:address_description].id}
        class="block text-xs font-medium text-fg mb-1.5"
      >
        Address Description <span class="text-muted font-normal">(optional)</span>
      </label>
      <Form.input
        field={@resource_form[:address_description]}
        type="text"
        placeholder="Enter a description or URL"
        phx-debounce="300"
      />
      <p class="mt-1 text-xs text-muted">
        Optional description or URL shown in Clients.
      </p>
    </div>
    <div>
      <label
        for={@resource_form[:name].id}
        class="block text-xs font-medium text-fg mb-1.5"
      >
        Name <span class="text-attn">*</span>
      </label>
      <Form.input
        field={@resource_form[:name]}
        type="text"
        placeholder="Name this resource"
        phx-debounce="300"
        required
      />
    </div>
    """
  end

  attr :resource_form, :any, required: true

  def resource_dns_stack(assigns) do
    ~H"""
    <div>
      <Form.input
        id="panel-resource-form-ip-stack--dual"
        type="radio_button_group"
        field={@resource_form[:ip_stack]}
        value="dual"
        checked={
          "#{@resource_form[:ip_stack].value}" == "" or
            "#{@resource_form[:ip_stack].value}" == "dual"
        }
      />
      <Form.input
        id="panel-resource-form-ip-stack--ipv4"
        type="radio_button_group"
        field={@resource_form[:ip_stack]}
        value="ipv4_only"
        checked={"#{@resource_form[:ip_stack].value}" == "ipv4_only"}
      />
      <Form.input
        id="panel-resource-form-ip-stack--ipv6"
        type="radio_button_group"
        field={@resource_form[:ip_stack]}
        value="ipv6_only"
        checked={"#{@resource_form[:ip_stack].value}" == "ipv6_only"}
      />
      <span class="block text-xs font-medium text-fg mb-1.5">
        IP Stack
      </span>
      <div class="inline-flex rounded border border-hair overflow-hidden">
        <label
          for="panel-resource-form-ip-stack--dual"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-hair first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "" or
                "#{@resource_form[:ip_stack].value}" == "dual",
              do: "bg-fg text-bg",
              else:
                "bg-bg text-muted hover:text-fg"
            )
          ]}
        >
          Both
        </label>
        <label
          for="panel-resource-form-ip-stack--ipv4"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-hair first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "ipv4_only",
              do: "bg-fg text-bg",
              else:
                "bg-bg text-muted hover:text-fg"
            )
          ]}
        >
          IPv4
        </label>
        <label
          for="panel-resource-form-ip-stack--ipv6"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-hair first:border-l-0 cursor-pointer",
            if(
              "#{@resource_form[:ip_stack].value}" == "ipv6_only",
              do: "bg-fg text-bg",
              else:
                "bg-bg text-muted hover:text-fg"
            )
          ]}
        >
          IPv6
        </label>
      </div>
      <p class="mt-1.5 text-xs text-fg leading-snug">
        {case "#{@resource_form[:ip_stack].value}" do
          "ipv4_only" ->
            "Resolves only A records - clients connect over IPv4."

          "ipv6_only" ->
            "Resolves only AAAA records - clients connect over IPv6."

          _ ->
            "Resolves A and AAAA records - clients connect over IPv4 or IPv6, whichever is available."
        end}
      </p>
    </div>
    """
  end

  attr :filters_dropdown_open, :boolean, required: true
  attr :active_protocols, :list, required: true
  attr :filter_ports, :map, required: true

  def resource_filters_section(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-2">
        <span class="block text-xs font-medium text-fg">
          Traffic Restrictions <span class="font-normal text-muted">(optional)</span>
        </span>
        <.resource_filters_dropdown
          filters_dropdown_open={@filters_dropdown_open}
          active_protocols={@active_protocols}
        />
      </div>
      <.resource_filters_empty_state :if={@active_protocols == []} />
      <div :if={@active_protocols != []} class="flex flex-col gap-2">
        <.resource_filter_row
          :for={protocol <- @active_protocols}
          protocol={protocol}
          ports={Map.get(@filter_ports, protocol, "")}
        />
      </div>
    </div>
    """
  end

  attr :filters_dropdown_open, :boolean, required: true
  attr :active_protocols, :list, required: true

  def resource_filters_dropdown(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_resource_filters_dropdown"
        class="inline-flex items-center gap-1 text-xs text-muted hover:text-fg border border-hair rounded px-2 py-1 bg-bg hover:bg-hover transition-colors"
      >
        <Core.icon name="ri-add-line" class="w-3 h-3" /> Add protocol
        <Core.icon name="ri-arrow-down-s-line" class="w-3 h-3" />
      </button>
      <div
        :if={@filters_dropdown_open}
        phx-click-away="close_resource_filters_dropdown"
        class="absolute right-0 top-full mt-1 z-20 bg-bg border border-hair rounded shadow-md min-w-[120px]"
      >
        <.resource_filter_dropdown_item :if={:tcp not in @active_protocols} protocol="tcp" />
        <.resource_filter_dropdown_item :if={:udp not in @active_protocols} protocol="udp" />
        <.resource_filter_dropdown_item :if={:icmp not in @active_protocols} protocol="icmp" />
        <div
          :if={Enum.sort(@active_protocols) == [:icmp, :tcp, :udp]}
          class="px-3 py-2 text-xs text-muted"
        >
          All protocols added
        </div>
      </div>
    </div>
    """
  end

  attr :protocol, :string, required: true

  def resource_filter_dropdown_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="add_resource_filter"
      phx-value-protocol={@protocol}
      class="flex items-center w-full px-3 py-2 text-xs text-fg hover:bg-hover transition-colors"
    >
      {String.upcase(@protocol)}
    </button>
    """
  end

  def resource_filters_empty_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center rounded border border-dashed border-hair px-4 py-5 text-xs text-muted">
      No restrictions - all traffic is permitted
    </div>
    """
  end

  attr :protocol, :atom, required: true
  attr :ports, :string, required: true

  def resource_filter_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 rounded border border-hair bg-bg px-3 py-2">
      <input type="hidden" name={"resource[filters][#{@protocol}][enabled]"} value="true" />
      <input type="hidden" name={"resource[filters][#{@protocol}][protocol]"} value={"#{@protocol}"} />
      <span class="w-10 shrink-0 text-xs font-medium text-fg uppercase">
        {@protocol}
      </span>
      <div :if={@protocol != :icmp} class="flex-1">
        <input
          type="text"
          name={"resource[filters][#{@protocol}][ports]"}
          value={@ports}
          placeholder="All ports"
          class="w-full px-3 py-2 text-sm rounded-md border font-mono bg-bg text-fg placeholder:text-muted outline-none transition-colors border-hair focus:border-border-focus focus:ring-1 focus:ring-border-focus/30"
        />
      </div>
      <span :if={@protocol == :icmp} class="flex-1 text-xs text-muted italic">
        echo request/reply
      </span>
      <button
        type="button"
        phx-click="remove_resource_filter"
        phx-value-protocol={"#{@protocol}"}
        class="shrink-0 text-muted hover:text-fg transition-colors"
        aria-label={"Remove #{@protocol} filter"}
      >
        <Core.icon name="ri-close-line" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  def resource_form_actions(assigns) do
    ~H"""
    <Form.panel_footer>
      <Form.panel_footer_button type="button" phx-click="close_add_resource">
        Cancel
      </Form.panel_footer_button>
      <Form.panel_footer_button type="submit" style="primary">
        Create Resource
      </Form.panel_footer_button>
    </Form.panel_footer>
    """
  end

  attr :site, :any, required: true
  attr :form, :any, default: nil

  def site_edit_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <Form.panel_header title="Edit Site" close_event="cancel_site_edit_form" />
      <.form
        :if={@form}
        id="site-edit-form"
        for={@form}
        phx-submit="submit_site_edit_form"
        phx-change="change_site_edit_form"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <div>
            <label
              for={@form[:name].id}
              class="block text-xs font-medium text-fg mb-1.5"
            >
              Name <span class="text-attn">*</span>
            </label>
            <Form.input
              field={@form[:name]}
              type="text"
              placeholder="Name of this site"
              phx-debounce="300"
              required
            />
          </div>
        </div>
        <Form.panel_footer>
          <Form.panel_footer_button type="button" phx-click="cancel_site_edit_form">
            Cancel
          </Form.panel_footer_button>
          <Form.panel_footer_button type="submit" style="primary" class="font-medium">
            Save
          </Form.panel_footer_button>
        </Form.panel_footer>
      </.form>
    </div>
    """
  end

  attr :status, :atom, required: true, values: [:healthy, :degraded, :offline]

  def site_status_badge(assigns) do
    ~H"""
    <Core.status_badge style={site_badge_style(@status)}>
      {Phoenix.Naming.humanize(@status)}
    </Core.status_badge>
    """
  end

  defp site_badge_style(:healthy), do: :success
  defp site_badge_style(:degraded), do: :warning
  defp site_badge_style(:offline), do: :neutral

  @doc """
  A site's health and how many of its provisioned gateways are offline.

  Provisioned gateways are the ones holding a single-owner token: each was
  created deliberately, so every one of them is expected to be online. Gateways
  connected with a legacy multi-owner token count as online but are never
  expected, since their token can't tell how many there should be.
  """
  @spec site_health(MapSet.t(Ecto.UUID.t()), MapSet.t(Ecto.UUID.t())) ::
          {:healthy | :degraded | :offline, non_neg_integer()}
  def site_health(online_ids, provisioned_ids) do
    offline_count = provisioned_ids |> MapSet.difference(online_ids) |> MapSet.size()

    status =
      cond do
        MapSet.size(online_ids) == 0 -> :offline
        offline_count > 0 -> :degraded
        true -> :healthy
      end

    {status, offline_count}
  end

  @doc "The Gateway token in a deploy environment."
  @spec gateway_token([{String.t(), String.t()}]) :: String.t()
  def gateway_token(env) do
    {"FIREZONE_TOKEN", value} = List.keyfind(env, "FIREZONE_TOKEN", 0)
    value
  end

  @doc """
  The environment a freshly deployed Gateway runs with: its token, and the API URL
  when this deployment doesn't use the Gateway's default. The Gateway generates its
  own `FIREZONE_ID` and keeps it in `/var/lib/firezone`, so none is handed out.
  """
  @spec gateway_env(String.t()) :: [{String.t(), String.t()}]
  def gateway_env(encoded_token) do
    [
      {"FIREZONE_TOKEN", encoded_token}
      | if(url = PortalWeb.DeploymentURLs.api_url(),
          do: [{"FIREZONE_API_URL", url}],
          else: []
        )
    ]
  end

  defp gateway_api_url(env) do
    case List.keyfind(env, "FIREZONE_API_URL", 0) do
      {"FIREZONE_API_URL", value} -> value
      nil -> nil
    end
  end

  @doc "A `docker run` command that starts a Gateway with the deploy environment."
  @spec gateway_docker_command([{String.t(), String.t()}]) :: String.t()
  def gateway_docker_command(env) do
    [
      "docker run -d",
      "--restart=unless-stopped",
      "--pull=always",
      "--health-cmd=\"ip link | grep tun-firezone\"",
      "--name=firezone-gateway",
      "--cap-add=NET_ADMIN",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      "--volume /var/lib/firezone:/var/lib/firezone",
      Enum.map(env, fn {key, value} -> "--env #{key}=\"#{value}\"" end),
      "--env RUST_LOG=info",
      "#{Portal.Config.fetch_env!(:portal, :docker_registry)}/gateway:1"
    ]
    |> List.flatten()
    |> Enum.join(" \\\n  ")
  end

  @doc "A command that installs a Gateway as a systemd service with the deploy environment."
  @spec gateway_systemd_command([{String.t(), String.t()}]) :: String.t()
  def gateway_systemd_command(env) do
    """
    #{Enum.map_join(env, " \\\n", fn {key, value} -> "#{key}=\"#{value}\"" end)} \\
      bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)
    """
  end

  defp gateway_debian_apt_repository do
    """
    sudo mkdir --parents /etc/apt/keyrings
    wget -qO- https://artifacts.firezone.dev/apt/key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/firezone.gpg
    echo "deb [signed-by=/etc/apt/keyrings/firezone.gpg] https://artifacts.firezone.dev/apt/ stable main" | sudo tee /etc/apt/sources.list.d/firezone.list > /dev/null
    """
  end

  defp gateway_debian_install(env) do
    """
    sudo apt update
    sudo apt install firezone-gateway
    """ <> gateway_debian_api_url(gateway_api_url(env))
  end

  # The package's service reads its settings from /etc/firezone/gateway-env.
  defp gateway_debian_api_url(nil), do: ""

  defp gateway_debian_api_url(url),
    do: ~s(echo "FIREZONE_API_URL=#{url}" | sudo tee -a /etc/firezone/gateway-env > /dev/null\n)

  @doc """
  The commands that add the Firezone APT repository and install the Gateway package,
  as one block.
  """
  @spec gateway_debian_install_commands([{String.t(), String.t()}]) :: String.t()
  def gateway_debian_install_commands(env) do
    gateway_debian_apt_repository() <> gateway_debian_install(env)
  end

  defp gateway_debian_authenticate do
    """
    sudo firezone-gateway authenticate
    """
  end

  defp gateway_manual_env(env) do
    """
    RUST_LOG=info
    #{Enum.map_join(env, "\n", fn {key, value} -> "#{key}=#{value}" end)}
    """
  end

  defp gateway_manual_forwarding do
    """
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sudo sysctl -w net.ipv6.conf.all.forwarding=1
    sudo sysctl -w net.ipv6.conf.default.forwarding=1
    """
  end

  defp gateway_manual_masquerading do
    """
    sudo iptables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo iptables -A FORWARD -i tun-firezone -j ACCEPT
    sudo iptables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo iptables -A FORWARD -o tun-firezone -j ACCEPT
    sudo iptables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || sudo iptables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    sudo iptables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || sudo iptables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    sudo ip6tables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo ip6tables -A FORWARD -i tun-firezone -j ACCEPT
    sudo ip6tables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo ip6tables -A FORWARD -o tun-firezone -j ACCEPT
    sudo ip6tables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || sudo ip6tables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    sudo ip6tables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || sudo ip6tables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    """
  end
end
