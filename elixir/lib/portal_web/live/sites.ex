defmodule PortalWeb.Sites do
  use PortalWeb, :live_view
  alias PortalWeb.Sites.Components, as: SiteComponents
  alias PortalWeb.Resources.Components, as: ResourceComponents
  alias Portal.Presence
  alias __MODULE__.Database

  @resource_form_events ~w[resource_change resource_submit]

  @edit_form_events ~w[change_site_edit_form submit_site_edit_form]

  @selected_site_events ~w[
    confirm_rotate_gateway_token confirm_delete_gateway confirm_revoke_gateway_token
    revoke_all_gateway_tokens show_all_gateways show_online_gateways deploy_gateway
    delete_site open_site_edit_form cancel_site_edit_form
    open_add_devices remove_site_device confirm_remove_site_device
  ]

  @device_picker_events ~w[
    focus_device_search blur_device_search search_device device_search_page
    toggle_device_search_filter add_device remove_device add_devices_submit close_add_devices
  ]

  @site_devices_events ~w[open_add_devices remove_site_device cancel_remove_site_device confirm_remove_site_device] ++
                         @device_picker_events

  @device_search_page_size 10

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Presence.Devices.Account.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Sites")
      |> assign(sites_loading?: true)
      |> assign(sites: [])
      |> assign(resources_counts: %{})
      |> assign(policies_counts: %{})
      |> assign(gateway_counts: %{})
      |> assign(online_gateway_ids: %{})
      |> assign(provisioned_gateway_ids: %{})
      |> assign(internet_resource: nil)
      |> assign(internet_site: nil)
      |> assign(site_search: "", resource_names: %{}, site_attachments: [], online_ids: MapSet.new())
      |> assign(unified_devices?: Portal.Account.unified_devices?(socket.assigns.subject.account))
      |> assign(site_state_reset_assigns())
      |> PortalWeb.Live.Helpers.drop_stale_events(&stale_event?/2)

    socket =
      if connected?(socket) do
        load_sites_index_data(socket)
      else
        socket
      end

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :show}} = socket) do
    if selected_site_matches?(socket, id) do
      {:noreply,
       socket
       |> merge_state(:site_panel, %{
         tab: parse_panel_tab(params, socket.assigns.site_panel.gateway_tokens),
         view: :gateways,
         confirm_delete_site: false,
         expanded_gateway_id: nil
       })
       |> assign(devices_picker: nil)
       |> put_state(:site_deploy, base_site_deploy_state())
       |> put_state(:site_resource_form, base_site_resource_form_state())
       |> put_state(:site_edit, base_site_edit_state())}
    else
      case Database.get_site(id, socket.assigns.subject) do
        nil ->
          redirect_to_sites_index(socket, "Site does not exist.")

        site ->
          {:noreply,
           socket
           |> assign(site_panel_assigns(site, params, socket))}
      end
    end
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :edit}} = socket) do
    cond do
      match?(%{id: ^id, managed_by: :system}, socket.assigns.selected_site) ->
        patch_to_site(socket, id)

      selected_site_matches?(socket, id) ->
        edit_selected_site(socket, params)

      true ->
        load_site_for_edit(socket, id, params)
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = Database.change_site(%Portal.Site{})

    {:noreply,
     socket
     |> assign(site_state_reset_assigns())
     |> put_state(:new_site, %{open: true, form: to_form(changeset)})}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, site_state_reset_assigns())}
  end

  # System-managed sites have nothing to edit
  defp patch_to_site(socket, id) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{id}"))}
  end

  defp edit_selected_site(socket, params) do
    changeset = Database.change_site(socket.assigns.selected_site)

    {:noreply,
     socket
     |> merge_state(:site_panel, %{
       tab: parse_panel_tab(params, socket.assigns.site_panel.gateway_tokens),
       view: :edit_site,
       confirm_delete_site: false
     })
     |> assign(devices_picker: nil)
     |> put_state(:site_deploy, base_site_deploy_state())
     |> put_state(:site_resource_form, base_site_resource_form_state())
     |> put_state(:site_edit, %{form: to_form(changeset)})}
  end

  defp load_site_for_edit(socket, id, params) do
    case Database.get_site(id, socket.assigns.subject) do
      nil ->
        redirect_to_sites_index(socket, "Site does not exist.")

      %{managed_by: :system} ->
        patch_to_site(socket, id)

      site ->
        changeset = Database.change_site(site)
        site_assigns = site_panel_assigns(site, params, socket)

        {:noreply,
         assign(
           socket,
           Keyword.merge(site_assigns,
             site_panel: Map.put(Keyword.fetch!(site_assigns, :site_panel), :view, :edit_site),
             site_edit: %{form: to_form(changeset)}
           )
         )}
    end
  end

  defp redirect_to_sites_index(socket, message) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites"))}
  end

  defp site_panel_assigns(site, params, socket) do
    device_tokens = load_device_tokens(site.id, socket.assigns.subject)

    {gateways, total_gateway_count} =
      load_panel_gateways(site.id, false, device_tokens, socket.assigns.subject)

    resources =
      if site.managed_by == :account do
        Database.list_resources_for_site(site.id, socket.assigns.subject)
      else
        internet_resource = socket.assigns.internet_resource

        if internet_resource && internet_resource.site_id == site.id do
          [internet_resource]
        else
          []
        end
      end

    gateway_tokens = Portal.Devices.list_gateway_tokens_for_site(site.id, socket.assigns.subject)

    [
      selected_site: site,
      site_panel:
        Map.merge(base_site_panel_state(), %{
          tab: parse_panel_tab(params, gateway_tokens),
          devices: load_site_devices(site.id, socket.assigns.unified_devices?, socket.assigns.subject),
          gateways: gateways,
          total_gateway_count: total_gateway_count,
          resources: resources,
          gateway_tokens: gateway_tokens,
          legacy_token_connections: legacy_token_connections(gateway_tokens),
          device_tokens: device_tokens
        }),
      site_deploy: base_site_deploy_state(),
      site_resource_form: base_site_resource_form_state(),
      site_edit: base_site_edit_state(),
      new_site: base_new_site_state(),
      devices_picker: nil
    ]
  end

  defp stale_event?(event, %{unified_devices?: false}) when event in @site_devices_events, do: true

  defp stale_event?(event, %{devices_picker: nil}) when event in @device_picker_events, do: true

  defp stale_event?(event, %{site_resource_form: %{form: nil}}) when event in @resource_form_events, do: true
  defp stale_event?(event, %{site_edit: %{form: nil}}) when event in @edit_form_events, do: true

  defp stale_event?("new_site_submit", %{new_site: %{form: nil}}), do: true
  defp stale_event?(event, %{selected_site: nil}) when event in @selected_site_events, do: true
  defp stale_event?(_event, _assigns), do: false

  defp site_state_reset_assigns do
    [
      selected_site: nil,
      site_panel: base_site_panel_state(),
      site_deploy: base_site_deploy_state(),
      site_resource_form: base_site_resource_form_state(),
      site_edit: base_site_edit_state(),
      new_site: base_new_site_state(),
      devices_picker: nil
    ]
  end

  def render(assigns) do
    assigns = assign(assigns, :shown_sites, filter_sites(assigns.sites, assigns.site_search))

    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <Page.page_header>
        <:title>Sites</:title>
        <:description>
          A site is a set of devices that carry traffic to the resources behind it.
        </:description>
        <:action>
          <Navigation.docs_action show_label size="md" path="/deploy/sites" />
          <Form.button style="primary" icon="ri-add-line" phx-click="open_new_site_panel">
            Add a site
          </Form.button>
        </:action>
        <:stats :if={not @sites_loading?}>
          {length(@sites) + if @internet_site, do: 1, else: 0}
        </:stats>
      </Page.page_header>

      <div class="px-6 pb-3 shrink-0">
        <form id="sites-search-form" phx-change="search_sites" phx-submit="search_sites" class="relative max-w-sm">
          <Core.icon
            name="ri-search-line"
            class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-muted pointer-events-none"
          />
          <input
            type="text"
            name="site_search"
            value={@site_search}
            placeholder="Search sites"
            phx-debounce="200"
            autocomplete="off"
            data-1p-ignore
            class="w-full pl-8 pr-3 py-1.5 text-sm border border-rule bg-bg text-fg placeholder:text-faint outline-none focus:border-fg"
          />
        </form>
      </div>

      <div class="flex-1 overflow-auto">
        <table id="sites" class="w-full text-sm text-left text-fg table-fixed">
          <thead>
            <tr class="border-b border-rule">
              <th class="py-2 px-4 pl-6 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Site
              </th>
              <th class="py-2 px-4 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Resources
              </th>
              <th class="w-40 py-2 px-4 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Devices online
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={width <- if(@sites_loading?, do: ~w[w-40 w-28 w-36 w-24 w-32], else: [])} class="border-b border-hair animate-pulse">
              <td :for={_col <- 1..3} class="px-4 first:pl-6 py-3">
                <div class={["h-2 bg-hair max-w-full", width]}></div>
              </td>
            </tr>
            <tr
              :if={not @sites_loading? and not is_nil(@internet_site) and @site_search == ""}
              class={[
                "border-b border-hair cursor-pointer transition-colors hover:bg-hover",
                not is_nil(@selected_site) and @selected_site.id == @internet_site.id && "bg-hover"
              ]}
              phx-click="select_site"
              phx-value-id={@internet_site.id}
            >
              <td class="px-4 pl-6 py-3">
                <div class="flex items-center gap-2 font-medium text-fg">
                  <Core.icon name="ri-earth-line" class="w-4 h-4 text-muted shrink-0" /> Internet
                </div>
                <div class="text-xs text-muted mt-0.5">Managed by Firezone</div>
              </td>
              <td class="px-4 py-3 text-xs text-muted truncate">
                {if @internet_resource, do: "Internet", else: "None"}
              </td>
              <td class="px-4 py-3">
                <.devices_online counts={device_counts(@internet_site.id, assigns)} />
              </td>
            </tr>
            <tr
              :for={site <- if(@sites_loading?, do: [], else: @shown_sites)}
              id={"site-#{site.id}"}
              class={[
                "border-b border-hair cursor-pointer transition-colors hover:bg-hover",
                not is_nil(@selected_site) and @selected_site.id == site.id && "bg-hover"
              ]}
              phx-click="select_site"
              phx-value-id={site.id}
            >
              <td class="px-4 pl-6 py-3">
                <div class="flex items-center gap-2 font-medium text-fg">
                  <Core.icon name="ri-route-line" class="w-4 h-4 text-muted shrink-0" />
                  <span class="truncate">{site.name}</span>
                </div>
              </td>
              <td class="px-4 py-3 text-xs text-muted truncate">
                <% names = Map.get(@resource_names, site.id, []) %>
                {if names == [], do: "None", else: resource_names_label(names, Map.get(@resources_counts, site.id, 0))}
              </td>
              <td class="px-4 py-3">
                <.devices_online counts={device_counts(site.id, assigns)} />
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :if={not @sites_loading? and @sites == [] and is_nil(@internet_site)}
          class="flex flex-1 items-center justify-center p-8"
        >
          <div class="flex flex-col items-center gap-3 py-16">
            <Core.icon name="ri-route-line" class="w-6 h-6 text-faint" />
            <div class="text-center">
              <p class="text-sm font-medium text-fg">No sites yet</p>
              <p class="text-xs text-muted mt-0.5">
                Add a site, then attach devices and resources to it.
              </p>
            </div>
            <Form.button patch={LiveTable.live_table_path(assigns, ~p"/#{@account}/sites/new")} icon="ri-add-line" size="xs">
              Add a site
            </Form.button>
          </div>
        </div>
        <p
          :if={not @sites_loading? and @sites != [] and @shown_sites == []}
          class="px-6 py-8 text-sm text-muted"
        >
          No sites match.
        </p>

        <SiteComponents.attachment_grid
          :if={@unified_devices? and not @sites_loading?}
          account={@account}
          sites={@sites}
          attachments={@site_attachments}
          online_ids={@online_ids}
        />
      </div>

      <SiteComponents.site_panel
        site={@selected_site}
        account={@account}
        resources_counts={@resources_counts}
        policies_counts={@policies_counts}
        panel={@site_panel}
        deploy_state={@site_deploy}
        resource_form_state={@site_resource_form}
        edit_state={@site_edit}
        unified_devices?={@unified_devices?}
        devices_picker={@devices_picker}
      />

      <SiteComponents.new_site_panel state={@new_site} />
    </div>
    """
  end

  defp base_site_panel_state do
    %{
      tab: :gateways,
      gateways: [],
      total_gateway_count: 0,
      resources: [],
      gateway_tokens: [],
      legacy_token_connections: %{},
      device_tokens: %{},
      show_all_gateways: false,
      view: :gateways,
      confirm_delete_site: false,
      confirm_delete_gateway_id: nil,
      confirm_revoke_token_id: nil,
      confirm_revoke_all_tokens: false,
      confirm_rotate_gateway_id: nil,
      rename_gateway_id: nil,
      gateway_actions_open_id: nil,
      rotated_gateway_token: nil,
      expanded_gateway_id: nil,
      devices: [],
      confirm_remove_device_id: nil
    }
  end

  defp base_devices_picker_state do
    %{
      selected_devices: [],
      device_search: "",
      device_search_results: nil,
      device_search_online_only?: false,
      device_search_recently_seen?: false,
      device_search_loading?: false
    }
  end

  defp load_site_devices(_site_id, false, _subject), do: []

  defp load_site_devices(site_id, true, subject) do
    site_id
    |> Database.list_site_devices(subject)
    |> Presence.Devices.preload_presence()
  end

  defp load_device_tokens(site_id, subject) do
    site_id
    |> Portal.Devices.list_gateway_tokens_for_devices_in_site(subject)
    |> Enum.group_by(& &1.device_id)
  end

  # Channels join the PG group under their token id, so the member count is
  # the number of gateways currently connected with each legacy token
  defp legacy_token_connections(gateway_tokens) do
    Map.new(gateway_tokens, fn token -> {token.id, length(Portal.PG.members(token.id))} end)
  end

  # Single-owner gateways are always listed, even offline: their token maps to
  # exactly one gateway, so the row is meaningful (unlike legacy multi-owner
  # gateways, where one token can spawn many stale offline rows)
  defp load_panel_gateways(site_id, show_all?, device_tokens, subject) do
    all_gateways =
      site_id
      |> Database.list_gateways_for_site(subject)
      |> Presence.Devices.preload_presence()

    gateways =
      if show_all? do
        all_gateways
      else
        Enum.filter(all_gateways, &(&1.online? or Map.has_key?(device_tokens, &1.id)))
      end

    {gateways, length(all_gateways)}
  end

  defp base_site_deploy_state do
    %{
      env: nil,
      tab: "debian-instructions",
      connected?: false,
      token: nil
    }
  end

  defp base_site_resource_form_state do
    %{
      form: nil,
      name_changed?: false,
      filters_dropdown_open: false,
      active_protocols: []
    }
  end

  defp base_site_edit_state do
    %{form: nil}
  end

  defp base_new_site_state do
    %{open: false, form: nil}
  end

  defp put_state(socket, key, attrs) do
    assign(socket, key, attrs)
  end

  defp merge_state(socket, key, attrs) do
    update(socket, key, &Map.merge(&1, attrs))
  end

  # ---- Helpers ----

  attr :counts, :any, required: true

  defp devices_online(assigns) do
    ~H"""
    <span class={[
      "text-sm tabular-nums",
      (elem(@counts, 1) == 0 or elem(@counts, 0) < elem(@counts, 1)) && "text-attn",
      elem(@counts, 1) > 0 and elem(@counts, 0) == elem(@counts, 1) && "text-fg"
    ]}>
      {elem(@counts, 0)} of {elem(@counts, 1)}
    </span>
    """
  end

  # Gateways count when online or holding a single-owner token; other devices always count.
  defp device_counts(site_id, assigns) do
    online_gateways = Map.get(assigns.online_gateway_ids, site_id, MapSet.new())
    gateways = MapSet.union(online_gateways, Map.get(assigns.provisioned_gateway_ids, site_id, MapSet.new()))
    others = for {device, ^site_id} <- assigns.site_attachments, do: device.id
    online_others = Enum.count(others, &MapSet.member?(assigns.online_ids, &1))

    {MapSet.size(online_gateways) + online_others, MapSet.size(gateways) + length(others)}
  end

  defp filter_sites(sites, ""), do: sites

  defp filter_sites(sites, search) do
    search = String.downcase(search)
    Enum.filter(sites, &String.contains?(String.downcase(&1.name), search))
  end

  defp resource_names_label(names, count) when count > length(names),
    do: Enum.join(names, ", ") <> " +#{count - length(names)}"

  defp resource_names_label(names, _count), do: Enum.join(names, ", ")

  # Gateways holding a single-owner token are the ones the site expects online
  defp put_provisioned_gateway_ids(socket, site_id, device_tokens) do
    update(socket, :provisioned_gateway_ids, fn ids ->
      Map.put(ids, site_id, device_tokens |> Map.keys() |> MapSet.new())
    end)
  end

  # ---- Events ----

  def handle_event("search_sites", %{"site_search" => search}, socket) do
    {:noreply, assign(socket, site_search: String.trim(search))}
  end

  def handle_event("select_site", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{id}"))}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites"))}
  end

  def handle_event(
        "switch_panel_tab",
        %{"tab" => tab},
        %{assigns: %{selected_site: %Portal.Site{} = site}} = socket
      ) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{site}", tab: tab))}
  end

  def handle_event("switch_panel_tab", _params, %{assigns: %{selected_site: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :edit_site do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"))}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.new_site.open do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites"))}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :deploy do
    {:noreply, merge_state(socket, :site_panel, %{view: :gateways})}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :add_devices do
    {:noreply, close_add_devices(socket)}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :add_resource do
    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :gateways, tab: :resources})
     |> put_state(:site_resource_form, base_site_resource_form_state())}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_site) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites"))}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_site_panel", _params, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/new"))}
  end

  def handle_event("close_new_site_panel", _params, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites"))}
  end

  def handle_event("new_site_change", %{"site" => attrs}, socket) do
    changeset =
      Database.change_site(%Portal.Site{}, attrs)
      |> Map.put(:action, :validate)

    {:noreply, merge_state(socket, :new_site, %{form: to_form(changeset)})}
  end

  def handle_event("new_site_submit", %{"site" => attrs}, socket) do
    account = socket.assigns.account

    with true <- Portal.Billing.can_create_sites?(account),
         changeset = Database.new_site_changeset(account, attrs),
         {:ok, site} <- Database.create_site(changeset, socket.assigns.subject) do
      sites = Database.list_all_sites(socket.assigns.subject)

      {:noreply,
       socket
       |> put_flash(:success, "Site #{site.name} created successfully.")
       |> put_state(:new_site, base_new_site_state())
       |> assign(sites: sites)
       |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{account}/sites/#{site.id}"))}
    else
      false ->
        changeset =
          Database.change_site(%Portal.Site{}, attrs)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> put_flash(
           :error,
           "You have reached the maximum number of sites allowed by your subscription plan."
         )
         |> merge_state(:new_site, %{form: to_form(changeset)})}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :new_site, %{form: to_form(Map.put(changeset, :action, :validate))})}
    end
  end

  def handle_event("toggle_gateway_expand", %{"id" => id}, socket) do
    expanded =
      if socket.assigns.site_panel.expanded_gateway_id == id, do: nil, else: id

    # The rotated token is revealed once; collapsing or switching rows drops it
    {:noreply,
     merge_state(socket, :site_panel, %{
       expanded_gateway_id: expanded,
       confirm_rotate_gateway_id: nil,
       rename_gateway_id: nil,
       rotated_gateway_token: nil
     })}
  end

  def handle_event("toggle_gateway_actions", %{"id" => gateway_id}, socket) do
    open_id =
      if socket.assigns.site_panel.gateway_actions_open_id == gateway_id,
        do: nil,
        else: gateway_id

    {:noreply, merge_state(socket, :site_panel, %{gateway_actions_open_id: open_id})}
  end

  def handle_event("close_gateway_actions", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{gateway_actions_open_id: nil})}
  end

  # The confirm dialog renders in the expanded details, so expand the row
  def handle_event("rotate_gateway_token", %{"id" => gateway_id}, socket) do
    {:noreply,
     merge_state(socket, :site_panel, %{
       confirm_rotate_gateway_id: gateway_id,
       expanded_gateway_id: gateway_id,
       rename_gateway_id: nil,
       gateway_actions_open_id: nil
     })}
  end

  def handle_event("rename_gateway", %{"id" => gateway_id}, socket) do
    {:noreply,
     merge_state(socket, :site_panel, %{
       rename_gateway_id: gateway_id,
       expanded_gateway_id: gateway_id,
       confirm_rotate_gateway_id: nil,
       gateway_actions_open_id: nil
     })}
  end

  def handle_event("cancel_rename_gateway", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{rename_gateway_id: nil})}
  end

  def handle_event("save_gateway_name", %{"name" => name}, socket)
      when not is_nil(socket.assigns.site_panel.rename_gateway_id) do
    subject = socket.assigns.subject
    gateway_id = socket.assigns.site_panel.rename_gateway_id

    with {:ok, gateway} <-
           Portal.Devices.fetch_gateway(gateway_id, socket.assigns.selected_site, subject),
         {:ok, _gateway} <- Portal.Devices.rename_gateway(gateway, name, subject) do
      {gateways, total_gateway_count} =
        load_panel_gateways(
          socket.assigns.selected_site.id,
          socket.assigns.site_panel.show_all_gateways,
          socket.assigns.site_panel.device_tokens,
          subject
        )

      {:noreply,
       socket
       |> put_flash(:success, "Gateway renamed.")
       |> merge_state(:site_panel, %{
         rename_gateway_id: nil,
         gateways: gateways,
         total_gateway_count: total_gateway_count
       })}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to rename gateway.")
         |> merge_state(:site_panel, %{rename_gateway_id: nil})}
    end
  end

  def handle_event("save_gateway_name", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_rotate_gateway_token", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_rotate_gateway_id: nil})}
  end

  def handle_event("confirm_rotate_gateway_token", %{"id" => gateway_id}, socket) do
    subject = socket.assigns.subject

    with {:ok, gateway} <-
           Portal.Devices.fetch_gateway(gateway_id, socket.assigns.selected_site, subject),
         {:ok, _token, encoded_token} <- Portal.Devices.rotate_gateway_token(gateway, subject) do
      prior_tokens = Map.get(socket.assigns.site_panel.device_tokens, gateway_id, [])
      device_tokens = load_device_tokens(socket.assigns.selected_site.id, subject)

      replaced_unused? =
        SiteComponents.replaced_unused_token?(prior_tokens, Map.get(device_tokens, gateway_id, []))

      {:noreply,
       socket
       |> put_flash(:success, "Token rotated.")
       |> merge_state(:site_panel, %{
         confirm_rotate_gateway_id: nil,
         rotated_gateway_token: %{
           gateway_id: gateway_id,
           encoded: encoded_token,
           replaced_unused: replaced_unused?
         },
         device_tokens: device_tokens
       })}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to rotate token.")
         |> merge_state(:site_panel, %{confirm_rotate_gateway_id: nil})}
    end
  end

  def handle_event("dismiss_rotated_gateway_token", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{rotated_gateway_token: nil})}
  end

  def handle_event("delete_gateway", %{"id" => gateway_id}, socket) do
    {:noreply,
     merge_state(socket, :site_panel, %{
       confirm_delete_gateway_id: gateway_id,
       gateway_actions_open_id: nil
     })}
  end

  def handle_event("cancel_delete_gateway", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_delete_gateway_id: nil})}
  end

  def handle_event("confirm_delete_gateway", %{"id" => gateway_id}, socket) do
    case Portal.Devices.delete_gateway_by_id(
           gateway_id,
           socket.assigns.selected_site,
           socket.assigns.subject
         ) do
      {count, _} when count > 0 ->
        site_id = socket.assigns.selected_site.id

        # Deleting a gateway cascades to its single-owner tokens
        device_tokens = load_device_tokens(site_id, socket.assigns.subject)

        {gateways, total_gateway_count} =
          load_panel_gateways(
            site_id,
            socket.assigns.site_panel.show_all_gateways,
            device_tokens,
            socket.assigns.subject
          )

        {:noreply,
         socket
         |> put_flash(:success, "Gateway deleted.")
         |> put_provisioned_gateway_ids(site_id, device_tokens)
         |> merge_state(:site_panel, %{
           gateways: gateways,
           total_gateway_count: total_gateway_count,
           device_tokens: device_tokens,
           confirm_delete_gateway_id: nil,
           expanded_gateway_id: nil
         })}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete gateway.")
         |> merge_state(:site_panel, %{confirm_delete_gateway_id: nil})}
    end
  end

  def handle_event("show_all_gateways", _params, socket) do
    {gateways, _total} =
      load_panel_gateways(
        socket.assigns.selected_site.id,
        true,
        socket.assigns.site_panel.device_tokens,
        socket.assigns.subject
      )

    {:noreply, merge_state(socket, :site_panel, %{gateways: gateways, show_all_gateways: true})}
  end

  def handle_event("show_online_gateways", _params, socket) do
    {gateways, _total} =
      load_panel_gateways(
        socket.assigns.selected_site.id,
        false,
        socket.assigns.site_panel.device_tokens,
        socket.assigns.subject
      )

    {:noreply, merge_state(socket, :site_panel, %{gateways: gateways, show_all_gateways: false})}
  end

  def handle_event("deploy_gateway", _params, socket) do
    site = socket.assigns.selected_site
    subject = socket.assigns.subject

    # Pre-create the gateway and bind a single-owner token to it; the gateway
    # reports its FIREZONE_ID as a telemetry hint on first connect
    case Database.deploy_gateway(site, subject) do
      {:ok, _gateway, token, encoded_token} ->
        device_tokens = load_device_tokens(site.id, subject)

        {gateways, total_gateway_count} =
          load_panel_gateways(
            site.id,
            socket.assigns.site_panel.show_all_gateways,
            device_tokens,
            subject
          )

        env = SiteComponents.gateway_env(encoded_token)

        {:noreply,
         socket
         |> put_provisioned_gateway_ids(site.id, device_tokens)
         |> merge_state(:site_panel, %{
           view: :deploy,
           gateways: gateways,
           total_gateway_count: total_gateway_count,
           device_tokens: device_tokens
         })
         |> put_state(:site_deploy, %{
           env: env,
           tab: "debian-instructions",
           token: token,
           connected?: false
         })}

      {:error, {:rate_limit, _retry_after_ms}} ->
        {:noreply, put_flash(socket, :error, "Too many devices registered. Try again later.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create gateway.")}
    end
  end

  def handle_event("deploy_tab_selected", %{"tab" => tab}, socket) do
    {:noreply, merge_state(socket, :site_deploy, %{tab: tab})}
  end

  def handle_event("close_deploy", _params, socket) do
    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :gateways})
     |> put_state(:site_deploy, base_site_deploy_state())}
  end

  def handle_event(
        "add_resource",
        _params,
        %{assigns: %{selected_site: %{managed_by: :system}}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("add_resource", _params, socket) do
    changeset = Database.new_resource_changeset(socket.assigns.subject)

    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :add_resource})
     |> put_state(:site_resource_form, %{
       form: to_form(changeset),
       name_changed?: false,
       filters_dropdown_open: false,
       active_protocols: []
     })}
  end

  def handle_event("resource_change", %{"resource" => attrs} = payload, socket) do
    name_changed? =
      socket.assigns.site_resource_form.name_changed? ||
        payload["_target"] == ["resource", "name"]

    attrs =
      attrs
      |> then(fn a -> if name_changed?, do: a, else: Map.put(a, "name", a["address"]) end)
      |> ResourceComponents.map_filters_form_attrs()
      |> Map.put("site_id", socket.assigns.selected_site.id)

    changeset =
      Database.new_resource_changeset(socket.assigns.subject, attrs)
      |> Map.put(:action, :validate)

    {:noreply,
     merge_state(socket, :site_resource_form, %{
       form: to_form(changeset),
       name_changed?: name_changed?
     })}
  end

  def handle_event("resource_submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> then(fn a ->
        if socket.assigns.site_resource_form.name_changed?,
          do: a,
          else: Map.put(a, "name", a["address"])
      end)
      |> ResourceComponents.map_filters_form_attrs()
      |> Map.put("site_id", socket.assigns.selected_site.id)

    case Database.create_resource(attrs, socket.assigns.subject) do
      {:ok, resource} ->
        resources =
          Database.list_resources_for_site(
            socket.assigns.selected_site.id,
            socket.assigns.subject
          )

        resources_counts =
          Database.count_resources_by_site(
            Enum.map(socket.assigns.sites, & &1.id),
            socket.assigns.subject
          )

        {:noreply,
         socket
         |> put_flash(:success, "Resource #{resource.name} created successfully.")
         |> merge_state(:site_panel, %{view: :gateways, tab: :resources, resources: resources})
         |> put_state(:site_resource_form, base_site_resource_form_state())
         |> assign(resources_counts: resources_counts)}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :site_resource_form, %{
           form: to_form(Map.put(changeset, :action, :validate))
         })}
    end
  end

  def handle_event("close_add_resource", _params, socket) do
    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :gateways, tab: :resources})
     |> put_state(:site_resource_form, base_site_resource_form_state())}
  end

  def handle_event("confirm_delete_site", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_delete_site: true})}
  end

  def handle_event("cancel_delete_site", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_delete_site: false})}
  end

  def handle_event("delete_site", _params, socket) do
    case Database.delete_site(socket.assigns.selected_site, socket.assigns.subject) do
      {:ok, _site} ->
        sites = Database.list_all_sites(socket.assigns.subject)

        {:noreply,
         socket
         |> put_flash(:success, "Site #{socket.assigns.selected_site.name} deleted successfully.")
         |> assign(sites: sites)
         |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete site.")
         |> merge_state(:site_panel, %{confirm_delete_site: false})}
    end
  end

  def handle_event("open_site_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}/edit"))}
  end

  def handle_event("cancel_site_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"))}
  end

  def handle_event("change_site_edit_form", %{"site" => attrs}, socket) do
    changeset =
      Database.change_site(socket.assigns.selected_site, attrs)
      |> Map.put(:action, :validate)

    {:noreply, merge_state(socket, :site_edit, %{form: to_form(changeset)})}
  end

  def handle_event("submit_site_edit_form", %{"site" => attrs}, socket) do
    changeset = Database.change_site(socket.assigns.selected_site, attrs)

    case Database.update_site(changeset, socket.assigns.subject) do
      {:ok, updated_site} ->
        sites = Database.list_all_sites(socket.assigns.subject)
        site_ids = Enum.map(sites, & &1.id)
        resources_counts = Database.count_resources_by_site(site_ids, socket.assigns.subject)

        {:noreply,
         socket
         |> put_flash(:success, "Site updated successfully.")
         |> assign(
           sites: sites,
           resources_counts: resources_counts
         )
         |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/sites/#{updated_site.id}"))}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :site_edit, %{form: to_form(Map.put(changeset, :action, :validate))})}
    end
  end

  def handle_event("revoke_gateway_token", %{"id" => token_id}, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_revoke_token_id: token_id})}
  end

  def handle_event("cancel_revoke_gateway_token", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_revoke_token_id: nil})}
  end

  def handle_event("confirm_revoke_gateway_token", %{"id" => token_id}, socket) do
    case Database.delete_gateway_token_by_id(
           token_id,
           socket.assigns.selected_site,
           socket.assigns.subject
         ) do
      {count, _} when count > 0 ->
        tokens =
          Portal.Devices.list_gateway_tokens_for_site(
            socket.assigns.selected_site.id,
            socket.assigns.subject
          )

        {:noreply,
         socket
         |> put_flash(:success, "Token revoked.")
         |> merge_state(:site_panel, %{
           gateway_tokens: tokens,
           legacy_token_connections: legacy_token_connections(tokens),
           confirm_revoke_token_id: nil,
           tab: sanitize_panel_tab(socket.assigns.site_panel.tab, tokens)
         })}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to revoke token.")
         |> merge_state(:site_panel, %{confirm_revoke_token_id: nil})}
    end
  end

  def handle_event("confirm_revoke_all_tokens", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_revoke_all_tokens: true})}
  end

  def handle_event("cancel_revoke_all_tokens", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_revoke_all_tokens: false})}
  end

  def handle_event("revoke_all_gateway_tokens", _params, socket) do
    site = socket.assigns.selected_site

    {_count, _} = Database.delete_all_gateway_tokens(site, socket.assigns.subject)

    {:noreply,
     socket
     |> put_flash(:success, "All tokens revoked.")
     |> merge_state(:site_panel, %{
       gateway_tokens: [],
       legacy_token_connections: %{},
       confirm_revoke_all_tokens: false,
       tab: sanitize_panel_tab(socket.assigns.site_panel.tab, [])
     })}
  end

  def handle_event("toggle_resource_filters_dropdown", _params, socket) do
    {:noreply,
     update(
       socket,
       :site_resource_form,
       &Map.update!(&1, :filters_dropdown_open, fn open -> not open end)
     )}
  end

  def handle_event("close_resource_filters_dropdown", _params, socket) do
    {:noreply, merge_state(socket, :site_resource_form, %{filters_dropdown_open: false})}
  end

  def handle_event("add_resource_filter", %{"protocol" => protocol}, socket) do
    {:noreply,
     merge_state(socket, :site_resource_form, %{
       active_protocols:
         socket.assigns.site_resource_form.active_protocols ++ [String.to_existing_atom(protocol)],
       filters_dropdown_open: false
     })}
  end

  def handle_event("remove_resource_filter", %{"protocol" => protocol}, socket) do
    {:noreply,
     update(
       socket,
       :site_resource_form,
       &Map.update!(&1, :active_protocols, fn protocols ->
         List.delete(protocols, String.to_existing_atom(protocol))
       end)
     )}
  end

  def handle_event("open_add_devices", _params, socket) do
    {:noreply,
     socket
     |> merge_state(:site_panel, %{view: :add_devices, confirm_remove_device_id: nil})
     |> assign(devices_picker: base_devices_picker_state())}
  end

  def handle_event("close_add_devices", _params, socket) do
    {:noreply, close_add_devices(socket)}
  end

  def handle_event("focus_device_search", _params, socket) do
    {:noreply, run_device_search(socket, 1)}
  end

  def handle_event("blur_device_search", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:device_search)
     |> merge_state(:devices_picker, %{device_search_results: nil, device_search_loading?: false})}
  end

  def handle_event("search_device", %{"device_search" => search}, socket) do
    {:noreply,
     socket
     |> merge_state(:devices_picker, %{device_search: search})
     |> run_device_search(1)}
  end

  def handle_event("device_search_page", %{"page" => page}, socket) do
    case Integer.parse(page) do
      {page, ""} -> {:noreply, run_device_search(socket, page)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_device_search_filter", %{"filter" => "online_only"}, socket) do
    {:noreply, toggle_device_search_filter(socket, :device_search_online_only?)}
  end

  def handle_event("toggle_device_search_filter", %{"filter" => "recently_seen"}, socket) do
    {:noreply, toggle_device_search_filter(socket, :device_search_recently_seen?)}
  end

  def handle_event("toggle_device_search_filter", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_device", %{"device_id" => device_id}, socket) do
    with {:ok, device_id} <- Ecto.UUID.cast(device_id),
         %Portal.Device{} = device <- Database.get_selectable_device(device_id, socket.assigns.subject) do
      picker = socket.assigns.devices_picker
      selected = Enum.uniq_by(picker.selected_devices ++ [device], & &1.id)

      {:noreply,
       socket
       |> merge_state(:devices_picker, %{selected_devices: selected})
       |> run_device_search(current_device_search_page(picker))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_device", %{"device_id" => device_id}, socket) do
    picker = socket.assigns.devices_picker
    selected = Enum.reject(picker.selected_devices, &(&1.id == device_id))

    {:noreply,
     socket
     |> merge_state(:devices_picker, %{selected_devices: selected})
     |> run_device_search(current_device_search_page(picker))}
  end

  def handle_event("add_devices_submit", _params, socket) do
    site = socket.assigns.selected_site
    device_ids = Enum.map(socket.assigns.devices_picker.selected_devices, & &1.id)

    case Database.add_devices_to_site(site, device_ids, socket.assigns.subject) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:success, added_devices_message(count))
         |> merge_state(:site_panel, %{
           devices: load_site_devices(site.id, true, socket.assigns.subject)
         })
         |> close_add_devices()}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not add the devices. Some of them can no longer route for this site."
         )}
    end
  end

  def handle_event("remove_site_device", %{"id" => device_id}, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_remove_device_id: device_id})}
  end

  def handle_event("cancel_remove_site_device", _params, socket) do
    {:noreply, merge_state(socket, :site_panel, %{confirm_remove_device_id: nil})}
  end

  def handle_event("confirm_remove_site_device", %{"id" => device_id}, socket) do
    site = socket.assigns.selected_site

    with {:ok, device_id} <- Ecto.UUID.cast(device_id),
         {:ok, _device} <- Database.remove_device_from_site(site, device_id, socket.assigns.subject) do
      {:noreply,
       socket
       |> put_flash(:success, "Device removed from the site.")
       |> merge_state(:site_panel, %{
         devices: load_site_devices(site.id, true, socket.assigns.subject),
         confirm_remove_device_id: nil
       })}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not remove the device from the site.")
         |> merge_state(:site_panel, %{confirm_remove_device_id: nil})}
    end
  end

  # ---- Presence updates ----

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "presences:account_devices:" <> _account_id,
          payload: %{joins: joins}
        },
        socket
      ) do
    socket =
      case site_deploy_connection_status(socket.assigns.site_deploy, joins) do
        :noop -> socket
        connected? -> merge_state(socket, :site_deploy, %{connected?: connected?})
      end

    socket = load_sites_index_data(socket)

    {device_tokens, panel_gateways, total_gateway_count} =
      if socket.assigns.selected_site do
        # Connects can confirm rotations (deleting the expiring token), so the
        # per-gateway token state is refreshed along with the gateway list
        device_tokens =
          load_device_tokens(socket.assigns.selected_site.id, socket.assigns.subject)

        {panel_gateways, total_gateway_count} =
          load_panel_gateways(
            socket.assigns.selected_site.id,
            socket.assigns.site_panel.show_all_gateways,
            device_tokens,
            socket.assigns.subject
          )

        {device_tokens, panel_gateways, total_gateway_count}
      else
        {socket.assigns.site_panel.device_tokens, socket.assigns.site_panel.gateways,
         socket.assigns.site_panel.total_gateway_count}
      end

    site_devices =
      if socket.assigns.selected_site do
        load_site_devices(socket.assigns.selected_site.id, socket.assigns.unified_devices?, socket.assigns.subject)
      else
        socket.assigns.site_panel.devices
      end

    socket =
      merge_state(socket, :site_panel, %{
        devices: site_devices,
        device_tokens: device_tokens,
        gateways: panel_gateways,
        total_gateway_count: total_gateway_count,
        legacy_token_connections:
          legacy_token_connections(socket.assigns.site_panel.gateway_tokens)
      })

    {:noreply, socket}
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  def handle_async(:device_search, {:ok, results}, %{assigns: %{devices_picker: %{} = picker}} = socket) do
    selected_ids = MapSet.new(picker.selected_devices, & &1.id)

    results = %{results | devices: Enum.reject(results.devices, &MapSet.member?(selected_ids, &1.id))}

    {:noreply,
     merge_state(socket, :devices_picker, %{device_search_results: results, device_search_loading?: false})}
  end

  def handle_async(:device_search, {:ok, _results}, socket), do: {:noreply, socket}

  def handle_async(:device_search, {:exit, _reason}, %{assigns: %{devices_picker: %{}}} = socket),
    do: {:noreply, merge_state(socket, :devices_picker, %{device_search_loading?: false})}

  def handle_async(:device_search, {:exit, _reason}, socket), do: {:noreply, socket}

  defp close_add_devices(socket) do
    socket
    |> cancel_async(:device_search)
    |> merge_state(:site_panel, %{view: :gateways, tab: :gateways})
    |> assign(devices_picker: nil)
  end

  defp toggle_device_search_filter(socket, key) do
    socket
    |> merge_state(:devices_picker, %{key => not Map.fetch!(socket.assigns.devices_picker, key)})
    |> run_device_search(1)
  end

  defp current_device_search_page(%{device_search_results: %{page: page}}), do: page
  defp current_device_search_page(_picker), do: 1

  # Searches scan every device in the account, so they run off the LiveView process and a
  # newer search drops the one still running.
  defp run_device_search(socket, page) do
    picker = socket.assigns.devices_picker

    if picker.device_search in [nil, ""] and not picker.device_search_online_only? and
         not picker.device_search_recently_seen? do
      socket
      |> cancel_async(:device_search)
      |> merge_state(:devices_picker, %{device_search_results: nil, device_search_loading?: false})
    else
      site = socket.assigns.selected_site
      subject = socket.assigns.subject
      selected_ids = Enum.map(picker.selected_devices, & &1.id)

      opts = [
        page: page,
        page_size: @device_search_page_size,
        online_only: picker.device_search_online_only?,
        recently_seen: picker.device_search_recently_seen?
      ]

      socket
      |> cancel_async(:device_search)
      |> merge_state(:devices_picker, %{device_search_loading?: true})
      |> start_async(:device_search, fn ->
        Database.search_devices_for_site(site, picker.device_search, selected_ids, subject, opts)
      end)
    end
  end

  defp added_devices_message(1), do: "1 device added to the site."
  defp added_devices_message(count), do: "#{count} devices added to the site."

  defp selected_site_matches?(socket, id) do
    match?(%{id: ^id}, socket.assigns.selected_site)
  end

  defp parse_site_tab("resources"), do: :resources
  defp parse_site_tab("gateways"), do: :gateways
  defp parse_site_tab("tokens"), do: :tokens
  defp parse_site_tab(_), do: :gateways

  defp parse_panel_tab(params, gateway_tokens) do
    params
    |> Map.get("tab", "gateways")
    |> parse_site_tab()
    |> sanitize_panel_tab(gateway_tokens)
  end

  # The Legacy tokens tab is hidden when a site has no legacy tokens.
  defp sanitize_panel_tab(:tokens, []), do: :gateways
  defp sanitize_panel_tab(tab, _gateway_tokens), do: tab

  defp site_deploy_connection_status(%{connected?: true}, _joins), do: :noop

  defp site_deploy_connection_status(%{token: nil}, _joins), do: :noop

  defp site_deploy_connection_status(%{token: %{id: token_id}}, joins) do
    deploy_token_connected?(joins, token_id)
  end

  defp deploy_token_connected?(joins, token_id) do
    Enum.any?(joins, fn {_gateway_id, %{metas: metas}} ->
      Enum.any?(metas, fn meta -> Map.get(meta, :token_id) == token_id end)
    end)
  end

  defp load_sites_index_data(socket) do
    internet_resource =
      if Portal.Account.internet_resource_enabled?(socket.assigns.account) do
        Database.get_internet_resource(socket.assigns.subject)
      end

    sites = Database.list_all_sites(socket.assigns.subject)
    site_ids = Enum.map(sites, & &1.id)

    internet_site = internet_resource && internet_resource.site

    all_site_ids =
      if internet_site,
        do: [internet_site.id | site_ids],
        else: site_ids

    resources_counts = Database.count_resources_by_site(site_ids, socket.assigns.subject)
    resource_names = Database.list_resource_names_by_site(site_ids, socket.assigns.subject)
    policies_counts = Database.count_policies_by_site(all_site_ids, socket.assigns.subject)
    gateway_counts = Database.count_gateways_by_site(all_site_ids, socket.assigns.subject)

    provisioned_gateway_ids =
      Database.list_provisioned_gateway_ids_by_site(all_site_ids, socket.assigns.subject)

    socket
    |> assign(sites_loading?: false)
    |> assign(sites: sites)
    |> assign(resources_counts: resources_counts)
    |> assign(resource_names: resource_names)
    |> assign(site_attachments: Database.list_site_attachments(all_site_ids, socket.assigns.subject))
    |> assign(online_ids: MapSet.new(Presence.Devices.online_ids(socket.assigns.account.id)))
    |> assign(policies_counts: policies_counts)
    |> assign(gateway_counts: gateway_counts)
    |> assign(online_gateway_ids: Presence.Devices.online_gateway_ids_by_site(socket.assigns.account.id))
    |> assign(provisioned_gateway_ids: provisioned_gateway_ids)
    |> assign(internet_resource: internet_resource)
    |> assign(internet_site: internet_site)
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Safe, Site, SiteDevice, Resource, Device, DeviceToken}

    @spec list_all_sites(Portal.Authentication.Subject.t()) :: [Site.t()]
    def list_all_sites(subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.managed_by == :account)
      |> order_by([sites: s], asc: s.name)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def list_sites(subject, opts \\ []) do
      from(g in Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    @spec get_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: Site.t() | nil
    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    @spec list_gateways_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            Device.t()
          ]
    def list_gateways_for_site(site_id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :gateway)
      |> join(:inner, [devices: d], sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.site_id == ^site_id)
      |> order_by([devices: d], asc: d.name)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    @spec list_site_devices(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [Device.t()]
    def list_site_devices(site_id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client or is_nil(d.type))
      |> join(:inner, [devices: d], sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.site_id == ^site_id)
      |> order_by([devices: d], asc: d.name, asc: d.id)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        devices -> devices
      end
    end

    @type device_search_page :: %{
            devices: [Device.t()],
            unavailable: %{Ecto.UUID.t() => {:site, String.t()} | :outdated},
            page: pos_integer(),
            page_size: pos_integer(),
            total: non_neg_integer()
          }

    @doc """
    A page of the devices an admin can look through to add to `site`: every device of the
    account outside `site` and not yet picked. The ones that cannot be added are in
    `unavailable` with the reason, and come after the ones that can.
    """
    @spec search_devices_for_site(
            Site.t(),
            String.t() | nil,
            [Ecto.UUID.t()],
            Portal.Authentication.Subject.t(),
            Keyword.t()
          ) :: device_search_page()
    def search_devices_for_site(site, search_term, selected_ids, subject, opts) do
      online_ids = Presence.Devices.online_ids(subject.account.id)

      query =
        from(d in Device, as: :devices)
        |> where([devices: d], d.account_id == ^subject.account.id)
        |> where([devices: d], d.id not in ^selected_ids)
        |> join(:left, [devices: d], sd in SiteDevice,
          on: sd.account_id == d.account_id and sd.device_id == d.id,
          as: :site_device
        )
        |> where([site_device: sd], is_nil(sd.site_id) or sd.site_id != ^site.id)
        |> filter_device_search(search_term)
        |> filter_online_only(Keyword.get(opts, :online_only, false), online_ids)
        |> filter_recently_seen(Keyword.get(opts, :recently_seen, false), online_ids)

      fetch_device_search_page(query, subject, max(Keyword.fetch!(opts, :page), 1), Keyword.fetch!(opts, :page_size), online_ids)
    end

    @spec get_selectable_device(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: Device.t() | nil
    def get_selectable_device(device_id, subject) do
      [device_id]
      |> selectable_devices_query()
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Device{} = device -> device |> List.wrap() |> Portal.Devices.put_latest_actor(subject) |> hd()
        _ -> nil
      end
    end

    @doc """
    Puts every device in `device_ids` in `site`, or none of them: each must still be one that
    can serve a site and that serves no site yet.
    """
    @spec add_devices_to_site(Site.t(), [Ecto.UUID.t()], Portal.Authentication.Subject.t()) ::
            {:ok, pos_integer()} | {:error, term()}
    def add_devices_to_site(_site, [], _subject), do: {:error, :no_devices}

    def add_devices_to_site(site, device_ids, subject) do
      device_ids = Enum.uniq(device_ids)

      Safe.transact(fn ->
        with {:ok, site} <- lock_site(site, subject),
             {:ok, devices} <- fetch_selectable_devices(device_ids, subject),
             {:ok, count} <- insert_site_devices(site, devices, subject) do
          {:ok, count}
        end
      end)
    end

    @spec remove_device_from_site(Site.t(), Ecto.UUID.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, term()}
    def remove_device_from_site(site, device_id, subject) do
      Safe.transact(fn ->
        from(d in Device, as: :devices)
        |> where([devices: d], d.id == ^device_id and (d.type == :client or is_nil(d.type)))
        |> join(:inner, [devices: d], sd in SiteDevice,
          on: sd.account_id == d.account_id and sd.device_id == d.id,
          as: :site_device
        )
        |> where([site_device: sd], sd.site_id == ^site.id)
        |> lock("FOR UPDATE")
        |> Safe.scoped(subject)
        |> Safe.one()
        |> case do
          %Device{} = device -> Portal.Devices.remove_from_site(device, subject)
          nil -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end

    @spec list_resources_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            Resource.t()
          ]
    def list_resources_for_site(site_id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id == ^site_id)
      |> order_by([resources: r], asc: r.name)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def count_resources_by_site(site_ids, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count(r.id)})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    @doc "Up to 3 resource names per site, by name."
    def list_resource_names_by_site(site_ids, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id in ^site_ids)
      |> order_by([resources: r], asc: r.site_id, asc: r.name)
      |> select([resources: r], {r.site_id, r.name})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} ->
          %{}

        rows ->
          rows
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Map.new(fn {site_id, names} -> {site_id, Enum.take(names, 3)} end)
      end
    end

    @doc "The devices other than gateways that route for one of `site_ids`, with that site."
    def list_site_attachments(site_ids, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client or is_nil(d.type))
      |> join(:inner, [devices: d], sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.site_id in ^site_ids)
      |> order_by([devices: d], asc: d.name, asc: d.id)
      |> select([devices: d, site_device: sd], {d, sd.site_id})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        rows -> rows
      end
    end

    def count_policies_by_site(site_ids, subject) do
      from(p in Portal.Policy, as: :policies)
      |> join(:inner, [policies: p], r in Resource,
        on: r.id == p.resource_id and r.account_id == p.account_id,
        as: :resources
      )
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count()})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    def count_gateways_by_site(site_ids, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :gateway)
      |> join(:inner, [devices: d], sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.site_id in ^site_ids)
      |> group_by([site_device: sd], sd.site_id)
      |> select([devices: d, site_device: sd], {sd.site_id, count(d.id)})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    @spec new_resource_changeset(Portal.Authentication.Subject.t(), map()) :: Ecto.Changeset.t()
    def new_resource_changeset(subject, attrs \\ %{}) do
      %Resource{}
      |> cast(attrs, [:name, :address, :address_description, :type, :ip_stack, :site_id])
      |> validate_required([:name, :address])
      |> put_change(:account_id, subject.account.id)
      |> Resource.changeset()
      |> Resource.validate_site_matches_type(subject)
    end

    @spec create_resource(map(), Portal.Authentication.Subject.t()) ::
            {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
    def create_resource(attrs, subject) do
      new_resource_changeset(subject, attrs)
      |> validate_required([:site_id])
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    @spec deploy_gateway(Site.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t(), DeviceToken.t(), binary()} | {:error, term()}
    def deploy_gateway(site, subject) do
      Portal.Devices.provision_gateway(site, nil, subject)
    end

    @spec list_provisioned_gateway_ids_by_site(
            [Ecto.UUID.t()],
            Portal.Authentication.Subject.t()
          ) :: %{Ecto.UUID.t() => MapSet.t(Ecto.UUID.t())}
    def list_provisioned_gateway_ids_by_site(site_ids, subject) do
      from(t in DeviceToken, as: :gateway_tokens)
      |> join(:inner, [gateway_tokens: t], d in Device,
        on: d.account_id == t.account_id and d.id == t.device_id,
        as: :devices
      )
      |> where([devices: d], d.type == :gateway)
      |> join(:inner, [devices: d], sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.site_id in ^site_ids)
      |> distinct(true)
      |> select([devices: d, site_device: sd], {sd.site_id, d.id})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {site_id, ids} -> {site_id, MapSet.new(ids)} end)
    end

    @spec delete_gateway(Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
    def delete_gateway(gateway, subject) do
      Safe.scoped(gateway, subject)
      |> Safe.delete()
    end

    @spec delete_gateway_token_by_id(Ecto.UUID.t(), Site.t(), Portal.Authentication.Subject.t()) ::
            {non_neg_integer(), nil} | {:error, :unauthorized}
    def delete_gateway_token_by_id(token_id, site, subject) do
      from(t in DeviceToken, where: t.id == ^token_id and t.site_id == ^site.id)
      |> Portal.Authentication.delete_gateway_tokens(subject)
    end

    @spec delete_all_gateway_tokens(Site.t(), Portal.Authentication.Subject.t()) ::
            {non_neg_integer(), nil} | {:error, :unauthorized}
    def delete_all_gateway_tokens(site, subject) do
      from(t in DeviceToken, where: t.site_id == ^site.id)
      |> Portal.Authentication.delete_gateway_tokens(subject)
    end

    # credo:disable-for-next-line Credo.Check.Warning.SpecWithStruct
    @spec change_site(%Site{}, term()) :: Ecto.Changeset.t()
    def change_site(site, attrs \\ %{})

    # System-managed sites have no editable fields
    def change_site(%Site{managed_by: :system} = site, _attrs) do
      site
      |> change()
      |> Site.changeset()
    end

    def change_site(site, attrs) do
      site
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> Site.changeset()
    end

    @spec new_site_changeset(Portal.Account.t(), map()) :: Ecto.Changeset.t()
    def new_site_changeset(account, attrs) do
      %Site{account_id: account.id}
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> Site.changeset()
    end

    @spec create_site(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def create_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    @spec update_site(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def update_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end

    @spec delete_site(Site.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Site.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :not_found}
    def delete_site(%Site{managed_by: :system}, _subject), do: {:error, :unauthorized}

    # A gateway serves one site for now, so it goes with it. The site is locked
    # first so a gateway registering into it is either seen here or refused.
    def delete_site(site, subject) do
      Safe.transact(fn ->
        with {:ok, site} <- lock_site(site, subject),
             {count, _} when is_integer(count) <- delete_site_gateways(site, subject) do
          site |> Safe.scoped(subject) |> Safe.delete()
        end
      end)
    end

    def get_internet_resource(subject) do
      resource =
        from(r in Resource, as: :resources)
        |> where([resources: r], r.type == :internet)
        |> preload(site: [gateways: ^from(d in Portal.Device, where: d.type == :gateway)])
        |> Safe.scoped(subject)
        |> Safe.one()

      case resource do
        nil ->
          nil

        resource ->
          gateways = Presence.Devices.preload_presence(resource.site.gateways)
          put_in(resource.site.gateways, gateways)
      end
    end

    def cursor_fields,
      do: [
        {:sites, :asc, :inserted_at},
        {:sites, :asc, :id}
      ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :managed_by,
          type: :string,
          fun: &filter_managed_by/2
        }
      ]
    end

    def filter_managed_by(queryable, value) do
      {queryable, dynamic([sites: sites], sites.managed_by == ^value)}
    end

    defp lock_site(site, subject) do
      from(s in Site, as: :sites, where: s.id == ^site.id, lock: "FOR UPDATE")
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        site -> {:ok, site}
      end
    end

    # Only a device from a 1.7 or later binary, which has no type, can serve a site, and it
    # serves one at most.
    defp selectable_devices_query(device_ids) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.id in ^device_ids and is_nil(d.type))
      |> where(
        [devices: d],
        not exists(
          from(sd in SiteDevice,
            where: sd.account_id == parent_as(:devices).account_id and sd.device_id == parent_as(:devices).id
          )
        )
      )
    end

    defp fetch_selectable_devices(device_ids, subject) do
      case device_ids |> selectable_devices_query() |> lock("FOR UPDATE") |> Safe.scoped(subject) |> Safe.all() do
        {:error, reason} -> {:error, reason}
        devices when length(devices) == length(device_ids) -> {:ok, devices}
        _devices -> {:error, :not_selectable}
      end
    end

    defp insert_site_devices(site, devices, subject) do
      now = DateTime.utc_now()
      entries = Enum.map(devices, &%{site_id: site.id, device_id: &1.id, inserted_at: now})

      case Safe.scoped(subject) |> Safe.insert_all(SiteDevice, entries, on_conflict: :nothing) do
        {count, _} when count == length(entries) -> {:ok, count}
        {:error, reason} -> {:error, reason}
        {_count, _} -> {:error, :not_selectable}
      end
    end

    # Runs over ids and sort keys only, then joins the full rows for the page, so broad
    # searches on large accounts don't carry whole rows through the window.
    defp fetch_device_search_page(query, subject, page, page_size, online_ids) do
      page_query =
        query
        |> order_by([devices: d, site_device: sd],
          desc: is_nil(d.type) and is_nil(sd.site_id),
          desc: d.id in ^online_ids,
          desc_nulls_last: d.last_seen_at,
          asc: d.id
        )
        |> limit(^page_size)
        |> offset(^((page - 1) * page_size))
        |> select([devices: d, site_device: sd], %{
          id: d.id,
          account_id: d.account_id,
          selectable: is_nil(d.type) and is_nil(sd.site_id),
          online: d.id in ^online_ids,
          last_seen_at: d.last_seen_at,
          total: over(count(d.id))
        })

      rows =
        from(d in Device, as: :devices)
        |> join(:inner, [devices: d], p in subquery(page_query),
          on: p.id == d.id and p.account_id == d.account_id,
          as: :page
        )
        |> join(:left, [devices: d], sd in SiteDevice,
          on: sd.account_id == d.account_id and sd.device_id == d.id,
          as: :site_device
        )
        |> join(:left, [site_device: sd], s in Site,
          on: s.account_id == sd.account_id and s.id == sd.site_id,
          as: :site
        )
        |> order_by([page: p], desc: p.selectable, desc: p.online, desc_nulls_last: p.last_seen_at, asc: p.id)
        |> select([devices: d, page: p, site: s], {d, p.total, s.name})
        |> Safe.scoped(subject)
        |> Safe.all()

      case rows do
        [] when page > 1 ->
          fetch_device_search_page(query, subject, page - 1, page_size, online_ids)

        {:error, _} ->
          %{devices: [], unavailable: %{}, page: page, page_size: page_size, total: 0}

        rows ->
          devices =
            rows
            |> Enum.map(fn {device, _total, _site_name} -> %{device | online?: device.id in online_ids} end)
            |> Portal.Devices.put_latest_actor(subject)

          unavailable =
            for {device, _total, site_name} <- rows,
                reason = unavailable_reason(device, site_name),
                into: %{},
                do: {device.id, reason}

          total = rows |> List.first({nil, 0, nil}) |> elem(1)
          %{devices: devices, unavailable: unavailable, page: page, page_size: page_size, total: total}
      end
    end

    defp unavailable_reason(_device, site_name) when is_binary(site_name), do: {:site, site_name}
    defp unavailable_reason(%Device{type: nil}, nil), do: nil
    defp unavailable_reason(_device, nil), do: :outdated

    defp filter_device_search(query, search_term) when search_term in [nil, ""], do: query

    defp filter_device_search(query, search_term) do
      pattern = "%#{search_term}%"

      where(
        query,
        [devices: d],
        ilike(d.name, ^pattern) or
          ilike(coalesce(d.slug, ""), ^pattern) or
          ilike(coalesce(d.hostname, ""), ^pattern) or
          ilike(type(d.id, :string), ^pattern) or
          ilike(type(d.ipv4, :string), ^pattern) or
          ilike(type(d.ipv6, :string), ^pattern) or
          exists(
            from(da in Portal.DeviceActor,
              join: a in Portal.Actor,
              on: a.account_id == da.account_id and a.id == da.actor_id,
              where:
                da.account_id == parent_as(:devices).account_id and
                  da.device_id == parent_as(:devices).id and
                  (ilike(a.name, ^pattern) or ilike(coalesce(a.email, ""), ^pattern))
            )
          )
      )
    end

    defp filter_online_only(query, false, _online_ids), do: query
    defp filter_online_only(query, true, online_ids), do: where(query, [devices: d], d.id in ^online_ids)

    defp filter_recently_seen(query, false, _online_ids), do: query

    defp filter_recently_seen(query, true, online_ids) do
      where(query, [devices: d], d.id in ^online_ids or d.last_seen_at > ago(30, "day"))
    end

    defp delete_site_gateways(site, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :gateway)
      |> join(:inner, [devices: d], sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.site_id == ^site.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end
  end
end
