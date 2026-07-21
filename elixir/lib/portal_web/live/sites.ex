defmodule PortalWeb.Sites do
  use PortalWeb, :live_view
  import PortalWeb.Sites.Components
  import PortalWeb.Resources.Components, only: [map_filters_form_attrs: 2]
  alias Portal.Presence
  alias Portal.PubSub
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Presence.Gateways.Account.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Sites")
      |> assign(sites_loading?: true)
      |> assign(sites: [])
      |> assign(resources_counts: %{})
      |> assign(policies_counts: %{})
      |> assign(gateway_counts: %{})
      |> assign(internet_resource: nil)
      |> assign(internet_site: nil)
      |> assign(site_state_reset_assigns())

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
       |> unsubscribe_deploy_site_presence()
       |> merge_state(:site_panel, %{
         tab: parse_panel_tab(params, socket.assigns.site_panel.gateway_tokens),
         view: :gateways,
         confirm_delete_site: false,
         expanded_gateway_id: nil
       })
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
           |> unsubscribe_deploy_site_presence()
           |> assign(site_panel_assigns(site, params, socket))}
      end
    end
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :edit}} = socket) do
    if selected_site_matches?(socket, id) do
      changeset = Database.change_site(socket.assigns.selected_site)

      {:noreply,
       socket
       |> unsubscribe_deploy_site_presence()
       |> merge_state(:site_panel, %{
         tab: parse_panel_tab(params, socket.assigns.site_panel.gateway_tokens),
         view: :edit_site,
         confirm_delete_site: false
       })
       |> put_state(:site_deploy, base_site_deploy_state())
       |> put_state(:site_resource_form, base_site_resource_form_state())
       |> put_state(:site_edit, %{form: to_form(changeset)})}
    else
      case Database.get_site(id, socket.assigns.subject) do
        nil ->
          redirect_to_sites_index(socket, "Site does not exist.")

        site ->
          changeset = Database.change_site(site)
          site_assigns = site_panel_assigns(site, params, socket)

          {:noreply,
           socket
           |> unsubscribe_deploy_site_presence()
           |> assign(
             Keyword.merge(site_assigns,
               site_panel: Map.put(Keyword.fetch!(site_assigns, :site_panel), :view, :edit_site),
               site_edit: %{form: to_form(changeset)}
             )
           )}
      end
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = Database.change_site(%Portal.Site{})

    {:noreply,
     socket
     |> unsubscribe_deploy_site_presence()
     |> assign(site_state_reset_assigns())
     |> put_state(:new_site, %{open: true, form: to_form(changeset)})}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> unsubscribe_deploy_site_presence() |> assign(site_state_reset_assigns())}
  end

  defp redirect_to_sites_index(socket, message) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> push_patch(to: ~p"/#{socket.assigns.account}/sites?#{socket.assigns.query_params}")}
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

    gateway_tokens = Database.list_gateway_tokens_for_site(site.id, socket.assigns.subject)

    [
      selected_site: site,
      site_panel:
        Map.merge(base_site_panel_state(), %{
          tab: parse_panel_tab(params, gateway_tokens),
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
      new_site: base_new_site_state()
    ]
  end

  defp site_state_reset_assigns do
    [
      selected_site: nil,
      site_panel: base_site_panel_state(),
      site_deploy: base_site_deploy_state(),
      site_resource_form: base_site_resource_form_state(),
      site_edit: base_site_edit_state(),
      new_site: base_new_site_state()
    ]
  end

  def render(assigns) do
    ~H"""
    <div
      class="relative flex flex-col h-full overflow-hidden"
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <.page_header>
        <:icon>
          <.icon name="ri-map-pin-line" class="w-16 h-16 text-brand" />
        </:icon>
        <:title>Sites</:title>
        <:description>
          Logical groupings of gateways - typically mapped to a network location or cloud region.
        </:description>
        <:action>
          <.docs_action path="/deploy/sites" />
          <.button style="primary" icon="ri-add-line" phx-click="open_new_site_panel">
            New Site
          </.button>
        </:action>
        <:stats :if={not @sites_loading?}>
          <.dual_badge type="primary">
            <:left>{length(@sites) + if @internet_site, do: 1, else: 0}</:left>
            <:right>Total</:right>
          </.dual_badge>
        </:stats>
      </.page_header>

      <div class="flex-1 overflow-auto overflow-x-auto">
        <table class="w-full text-sm border-collapse">
          <thead class="sticky top-0 z-10 bg-raised">
            <tr class="border-b border-border-strong">
              <th class="py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
                Site
              </th>
              <th class="w-36 py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
                Gateways
              </th>
              <th class="w-28 py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
                Resources
              </th>
              <th class="w-28 py-2.5 px-4 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
                Status
              </th>
            </tr>
          </thead>
          <tbody>
            <%= if @sites_loading? do %>
              <tr class="border-b border-border border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-border-strong w-36"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-border"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-16"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-10"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-border-strong"></div>
                    <div class="h-2.5 rounded bg-border-strong w-20"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-border border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-border-strong w-48"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-border"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-12"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-8"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-border-strong"></div>
                    <div class="h-2.5 rounded bg-border-strong w-16"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-border border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-border-strong w-40"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-border"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-20"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-12"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-border-strong"></div>
                    <div class="h-2.5 rounded bg-border-strong w-24"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-border border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-border-strong w-32"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-border"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-14"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-10"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-border-strong"></div>
                    <div class="h-2.5 rounded bg-border-strong w-20"></div>
                  </div>
                </td>
              </tr>
              <tr class="border-b border-border border-l-4 border-l-transparent animate-pulse">
                <td class="px-4 py-3">
                  <div class="h-3 rounded bg-border-strong w-44"></div>
                  <div class="mt-1.5 h-2 w-24 rounded bg-border"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-16"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="h-2.5 rounded bg-border-strong w-8"></div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex items-center gap-2">
                    <div class="w-2 h-2 rounded-full bg-border-strong"></div>
                    <div class="h-2.5 rounded bg-border-strong w-20"></div>
                  </div>
                </td>
              </tr>
            <% end %>
            <tr
              :if={not @sites_loading? and @internet_site}
              class={[
                "border-b border-border cursor-pointer transition-colors group border-l-4",
                if(not is_nil(@selected_site) and @selected_site.id == @internet_site.id,
                  do: "bg-brand-muted border-l-brand",
                  else:
                    "hover:bg-raised border-l-transparent bg-violet-50/60 dark:bg-violet-950/20"
                )
              ]}
              phx-click="select_site"
              phx-value-id={@internet_site.id}
            >
              <td class="px-4 py-3">
                <div class="flex items-center gap-2">
                  <.icon name="ri-global-line" class="w-5 h-5 text-violet-500" />
                  <div class={[
                    "font-medium transition-colors",
                    if(not is_nil(@selected_site) and @selected_site.id == @internet_site.id,
                      do: "text-brand",
                      else: "text-heading group-hover:text-brand"
                    )
                  ]}>
                    Internet
                  </div>
                  <.badge type="accent" size="xs">system</.badge>
                </div>
                <div class="font-mono text-[10px] text-subtle mt-0.5">
                  {@internet_site.id}
                </div>
              </td>
              <td class="px-4 py-3">
                <% online = gateway_online_count(@internet_site.id) %>
                <span class="text-sm text-body tabular-nums">
                  {online}<span class="ml-1.5 text-[10px] text-subtle">online</span>
                </span>
              </td>
              <td class="px-4 py-3">
                <span class="tabular-nums text-body">
                  {Map.get(@policies_counts, @internet_site.id, 0)}
                </span>
              </td>
              <td class="px-4 py-3">
                <.site_status_badge status={
                  compute_site_status(@internet_site.id, @internet_site.health_threshold)
                } />
              </td>
            </tr>
            <tr
              :for={site <- if(@sites_loading?, do: [], else: @sites)}
              class={[
                "border-b border-border cursor-pointer transition-colors group border-l-4",
                if(not is_nil(@selected_site) and @selected_site.id == site.id,
                  do: "bg-brand-muted border-l-brand",
                  else: "hover:bg-raised border-l-transparent"
                )
              ]}
              phx-click="select_site"
              phx-value-id={site.id}
            >
              <td class="px-4 py-3">
                <div class={[
                  "font-medium transition-colors",
                  if(not is_nil(@selected_site) and @selected_site.id == site.id,
                    do: "text-brand",
                    else: "text-heading group-hover:text-brand"
                  )
                ]}>
                  {site.name}
                </div>
                <div class="font-mono text-[10px] text-subtle mt-0.5">
                  {site.id}
                </div>
              </td>
              <td class="px-4 py-3">
                <% online = gateway_online_count(site.id) %>
                <span class="text-sm text-body tabular-nums">
                  {online}<span class="ml-1.5 text-[10px] text-subtle">online</span>
                </span>
              </td>
              <td class="px-4 py-3">
                <span class="tabular-nums text-body">
                  {Map.get(@resources_counts, site.id, 0)}
                </span>
              </td>
              <td class="px-4 py-3">
                <.site_status_badge status={compute_site_status(site.id, site.health_threshold)} />
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :if={not @sites_loading? and @sites == [] and is_nil(@internet_site)}
          class="flex flex-1 items-center justify-center p-8"
        >
          <div class="flex flex-col items-center gap-3 py-16">
            <div class="w-9 h-9 rounded-lg border border-border bg-raised flex items-center justify-center">
              <.icon name="ri-map-pin-line" class="w-5 h-5 text-subtle" />
            </div>
            <div class="text-center">
              <p class="text-sm font-medium text-heading">No sites yet</p>
              <p class="text-xs text-subtle mt-0.5">
                Create a Site in order to deploy Gateways and attach Resources.
              </p>
            </div>
            <.button patch={~p"/#{@account}/sites/new"} icon="ri-add-line" size="xs">Add a Site</.button>
          </div>
        </div>
      </div>

      <%!-- Right-hand detail panel --%>
      <.site_panel
        site={@selected_site}
        account={@account}
        resources_counts={@resources_counts}
        policies_counts={@policies_counts}
        panel={@site_panel}
        deploy_state={@site_deploy}
        resource_form_state={@site_resource_form}
        edit_state={@site_edit}
      />

      <.new_site_panel state={@new_site} />
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
      expanded_gateway_id: nil
    }
  end

  defp load_device_tokens(site_id, subject) do
    site_id
    |> Database.list_gateway_tokens_for_devices_in_site(subject)
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
      |> Presence.Gateways.preload_gateways_presence()

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
      token: nil,
      subscribed_site_id: nil
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

  defp gateway_online_count(site_id) do
    Presence.Gateways.Site.list(site_id) |> map_size()
  end

  defp compute_site_status(site_id, threshold) do
    online = gateway_online_count(site_id)

    cond do
      online == 0 -> :offline
      online < threshold -> :degraded
      true -> :healthy
    end
  end

  # ---- Events ----

  def handle_event("select_site", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/#{id}")}
  end

  def handle_event("close_panel", _params, socket) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites?#{params}")}
  end

  def handle_event(
        "switch_panel_tab",
        %{"tab" => tab},
        %{assigns: %{selected_site: %Portal.Site{} = site}} = socket
      ) do
    params = Map.put(socket.assigns.query_params, "tab", tab)

    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/#{site.id}?#{params}")}
  end

  def handle_event("switch_panel_tab", _params, %{assigns: %{selected_site: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :edit_site do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.new_site.open do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.site_panel.view == :deploy do
    {:noreply, merge_state(socket, :site_panel, %{view: :gateways})}
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
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_site_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites/new")}
  end

  def handle_event("close_new_site_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/sites")}
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
      sites = Database.list_all_sites(socket.assigns.subject, :primary)

      {:noreply,
       socket
       |> put_flash(:success, "Site #{site.name} created successfully.")
       |> put_state(:new_site, base_new_site_state())
       |> assign(sites: sites)
       |> push_patch(to: ~p"/#{account}/sites/#{site.id}")}
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

    with {:ok, gateway} <- Database.fetch_gateway(gateway_id, subject),
         {:ok, _gateway} <- Database.rename_gateway(gateway, name, subject) do
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

    with {:ok, gateway} <- Database.fetch_gateway(gateway_id, subject),
         {:ok, _token, encoded_token} <- Database.rotate_gateway_token(gateway, subject) do
      prior_tokens = Map.get(socket.assigns.site_panel.device_tokens, gateway_id, [])
      device_tokens = load_device_tokens(socket.assigns.selected_site.id, subject)

      # An active token existed before but no rotated sibling remains: the
      # never-used token was replaced outright rather than put in grace
      replaced_unused? =
        Enum.any?(prior_tokens, &is_nil(&1.rotated_at)) and
          not Enum.any?(Map.get(device_tokens, gateway_id, []), & &1.rotated_at)

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
    case Database.delete_gateway_by_id(gateway_id, socket.assigns.subject) do
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

        socket =
          socket
          |> unsubscribe_deploy_site_presence()
          |> subscribe_deploy_site_presence(site.id)

        env = [
          {"FIREZONE_ID", Ecto.UUID.generate()},
          {"FIREZONE_TOKEN", encoded_token}
          | if(url = Portal.Config.get_env(:portal, :api_url_override),
              do: [{"FIREZONE_API_URL", url}],
              else: []
            )
        ]

        {:noreply,
         socket
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
           connected?: false,
           subscribed_site_id: site.id
         })}

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
     |> unsubscribe_deploy_site_presence()
     |> merge_state(:site_panel, %{view: :gateways})
     |> put_state(:site_deploy, base_site_deploy_state())}
  end

  def handle_event("add_resource", _params, socket) do
    changeset = Database.new_resource_changeset(socket.assigns.account)

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
      |> map_filters_form_attrs(socket.assigns.account)
      |> Map.put("site_id", socket.assigns.selected_site.id)

    changeset =
      Database.new_resource_changeset(socket.assigns.account, attrs)
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
      |> map_filters_form_attrs(socket.assigns.account)
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
         |> push_patch(to: ~p"/#{socket.assigns.account}/sites")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete site.")
         |> merge_state(:site_panel, %{confirm_delete_site: false})}
    end
  end

  def handle_event("open_site_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}/edit"
     )}
  end

  def handle_event("cancel_site_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.selected_site.id}"
     )}
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
        sites = Database.list_all_sites(socket.assigns.subject, :primary)
        site_ids = Enum.map(sites, & &1.id)
        resources_counts = Database.count_resources_by_site(site_ids, socket.assigns.subject)

        {:noreply,
         socket
         |> put_flash(:success, "Site updated successfully.")
         |> assign(
           sites: sites,
           resources_counts: resources_counts
         )
         |> push_patch(to: ~p"/#{socket.assigns.account}/sites/#{updated_site.id}")}

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
    case Database.delete_gateway_token_by_id(token_id, socket.assigns.subject) do
      {count, _} when count > 0 ->
        tokens =
          Database.list_gateway_tokens_for_site(
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

  # ---- Presence updates ----

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:sites:" <> _site_id,
          payload: %{joins: joins}
        },
        socket
      ) do
    case site_deploy_connection_status(socket.assigns.site_deploy, joins) do
      :noop ->
        {:noreply, socket}

      connected? ->
        {:noreply, merge_state(socket, :site_deploy, %{connected?: connected?})}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _account_id},
        socket
      ) do
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

    socket =
      merge_state(socket, :site_panel, %{
        device_tokens: device_tokens,
        gateways: panel_gateways,
        total_gateway_count: total_gateway_count,
        legacy_token_connections:
          legacy_token_connections(socket.assigns.site_panel.gateway_tokens)
      })

    {:noreply, socket}
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  defp selected_site_matches?(socket, id) do
    match?(%{id: ^id}, socket.assigns.selected_site)
  end

  defp subscribe_deploy_site_presence(socket, site_id) do
    if connected?(socket) and socket.assigns.site_deploy.subscribed_site_id != site_id do
      :ok = Presence.Gateways.Site.subscribe(site_id)
      merge_state(socket, :site_deploy, %{subscribed_site_id: site_id})
    else
      socket
    end
  end

  defp unsubscribe_deploy_site_presence(socket) do
    if connected?(socket) do
      site_id = socket.assigns.site_deploy.subscribed_site_id
        :ok = PubSub.unsubscribe("presences:sites:#{site_id}")
        merge_state(socket, :site_deploy, %{subscribed_site_id: nil})
    else
        socket
    end
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
    policies_counts = Database.count_policies_by_site(all_site_ids, socket.assigns.subject)
    gateway_counts = Database.count_gateways_by_site(all_site_ids, socket.assigns.subject)

    socket
    |> assign(sites_loading?: false)
    |> assign(sites: sites)
    |> assign(resources_counts: resources_counts)
    |> assign(policies_counts: policies_counts)
    |> assign(gateway_counts: gateway_counts)
    |> assign(internet_resource: internet_resource)
    |> assign(internet_site: internet_site)
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Safe, Site, Resource, Device, GatewayToken}

    @spec list_all_sites(Portal.Authentication.Subject.t()) :: [Site.t()]
    def list_all_sites(subject, repo \\ :replica) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.managed_by == :account)
      |> order_by([sites: s], asc: s.name)
      |> Safe.scoped(subject, repo)
      |> Safe.all()
    end

    def list_sites(subject, opts \\ []) do
      from(g in Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    @spec get_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: Site.t() | nil
    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    @spec list_gateways_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            Device.t()
          ]
    def list_gateways_for_site(site_id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :gateway)
      |> where([devices: d], d.site_id == ^site_id)
      |> order_by([devices: d], asc: d.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    @spec list_resources_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            Resource.t()
          ]
    def list_resources_for_site(site_id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id == ^site_id)
      |> order_by([resources: r], asc: r.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def count_resources_by_site(site_ids, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count(r.id)})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
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
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
    end

    def count_gateways_by_site(site_ids, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :gateway)
      |> where([devices: d], d.site_id in ^site_ids)
      |> group_by([devices: d], d.site_id)
      |> select([devices: d], {d.site_id, count(d.id)})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
    end

    @spec new_resource_changeset(Portal.Account.t(), map()) :: Ecto.Changeset.t()
    def new_resource_changeset(account, attrs \\ %{}) do
      %Resource{}
      |> cast(attrs, [:name, :address, :address_description, :type, :ip_stack, :site_id])
      |> validate_required([:name, :address])
      |> put_change(:account_id, account.id)
      |> Resource.changeset()
    end

    @spec create_resource(map(), Portal.Authentication.Subject.t()) ::
            {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
    def create_resource(attrs, subject) do
      new_resource_changeset(subject.account, attrs)
      |> validate_required([:site_id])
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    @spec deploy_gateway(Site.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t(), GatewayToken.t(), binary()} | {:error, term()}
    def deploy_gateway(site, subject) do
      gateway = %Device{
        account_id: site.account_id,
        site_id: site.id,
        type: :gateway,
        name: Portal.Crypto.random_token(5, encoder: :user_friendly)
      }

      with {:ok, gateway} <- gateway |> Safe.scoped(subject) |> Safe.insert(),
           {:ok, token} <- Portal.Authentication.create_gateway_token(gateway, subject) do
        {:ok, gateway, %{token | secret_fragment: nil},
         Portal.Authentication.encode_fragment!(token)}
      end
    end

    @spec rename_gateway(Device.t(), String.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
    def rename_gateway(gateway, name, subject) do
      # Device.changeset/1 requires firezone_id, which deploy-created
      # gateways don't have until first connect — validate only the name
      gateway
      |> Ecto.Changeset.cast(%{name: name}, [:name])
      |> Portal.Changeset.trim_change([:name])
      |> Ecto.Changeset.validate_required([:name])
      |> Ecto.Changeset.validate_length(:name, min: 1, max: 255)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    @spec fetch_gateway(Ecto.UUID.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, :not_found} | {:error, :unauthorized}
    def fetch_gateway(id, subject) do
      result =
        from(d in Device, as: :devices)
        |> where([devices: d], d.id == ^id and d.type == :gateway)
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    end

    @spec rotate_gateway_token(Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, GatewayToken.t(), binary()} | {:error, term()}
    def rotate_gateway_token(gateway, subject) do
      with {:ok, token} <- Portal.Authentication.rotate_gateway_token(gateway, subject) do
        {:ok, %{token | secret_fragment: nil}, Portal.Authentication.encode_fragment!(token)}
      end
    end

    @spec list_gateway_tokens_for_devices_in_site(
            Ecto.UUID.t(),
            Portal.Authentication.Subject.t()
          ) :: [GatewayToken.t()]
    def list_gateway_tokens_for_devices_in_site(site_id, subject) do
      from(t in GatewayToken, as: :gateway_tokens)
      |> join(:inner, [gateway_tokens: t], d in Device,
        on: d.account_id == t.account_id and d.id == t.device_id,
        as: :devices
      )
      |> where([devices: d], d.site_id == ^site_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    @spec delete_gateway(Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
    def delete_gateway(gateway, subject) do
      Safe.scoped(gateway, subject)
      |> Safe.delete()
    end

    @spec delete_gateway_by_id(Ecto.UUID.t(), Portal.Authentication.Subject.t()) ::
            {non_neg_integer(), nil} | {:error, :unauthorized}
    def delete_gateway_by_id(id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.id == ^id and d.type == :gateway)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end

    @spec list_gateway_tokens_for_site(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: [
            GatewayToken.t()
          ]
    def list_gateway_tokens_for_site(site_id, subject) do
      from(t in GatewayToken, as: :gateway_tokens)
      |> where([gateway_tokens: t], t.site_id == ^site_id)
      |> order_by([gateway_tokens: t], desc: t.inserted_at)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    @spec delete_gateway_token_by_id(Ecto.UUID.t(), Portal.Authentication.Subject.t()) ::
            {non_neg_integer(), nil} | {:error, :unauthorized}
    def delete_gateway_token_by_id(token_id, subject) do
      from(t in GatewayToken, as: :gateway_tokens)
      |> where([gateway_tokens: t], t.id == ^token_id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end

    @spec delete_all_gateway_tokens(Site.t(), Portal.Authentication.Subject.t()) ::
            {non_neg_integer(), nil} | {:error, :unauthorized}
    def delete_all_gateway_tokens(site, subject) do
      from(t in GatewayToken, where: t.site_id == ^site.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end

    # credo:disable-for-next-line Credo.Check.Warning.SpecWithStruct
    @spec change_site(%Site{}, term()) :: Ecto.Changeset.t()
    def change_site(site, attrs \\ %{})

    def change_site(%Site{managed_by: :system} = site, attrs) do
      site
      |> cast(attrs, [:health_threshold])
      |> Site.changeset()
    end

    def change_site(site, attrs) do
      site
      |> cast(attrs, [:name, :health_threshold])
      |> validate_required([:name])
      |> Site.changeset()
    end

    @spec new_site_changeset(Portal.Account.t(), map()) :: Ecto.Changeset.t()
    def new_site_changeset(account, attrs) do
      %Site{account_id: account.id}
      |> cast(attrs, [:name, :health_threshold])
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
            {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
    def delete_site(site, subject) do
      Safe.scoped(site, subject)
      |> Safe.delete()
    end

    def get_internet_resource(subject) do
      resource =
        from(r in Resource, as: :resources)
        |> where([resources: r], r.type == :internet)
        |> preload(site: :gateways)
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case resource do
        nil ->
          nil

        resource ->
          gateways = Presence.Gateways.preload_gateways_presence(resource.site.gateways)
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
  end
end
