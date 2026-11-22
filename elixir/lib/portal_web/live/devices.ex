defmodule PortalWeb.Devices do
  use PortalWeb, :live_view
  alias PortalWeb.Devices.Components, as: DeviceComponents
  alias Portal.Presence.Devices
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PubSub
  alias PortalWeb.Sites
  alias Phoenix.LiveView.AsyncResult
  alias __MODULE__.Database

  @edit_form_events ~w[change_device_edit_form submit_device_edit_form cancel_device_edit_form]

  @dns_form_events ~w[change_device_dns submit_device_dns]

  @gateway_events ~w[
    rename_gateway cancel_rename_gateway save_gateway_name rotate_gateway_token
    cancel_rotate_gateway_token confirm_rotate_gateway_token dismiss_rotated_gateway_token
  ]

  @client_only_events ~w[
    verify_device unverify_device confirm_unverify_device open_device_edit_form
    change_device_edit_form submit_device_edit_form put_device_in_site remove_device_from_site
  ]

  @selected_device_events ~w[
    change_policy_authorizations_page open_device_edit_form verify_device unverify_device delete_device
    put_device_in_site remove_device_from_site
  ] ++ @gateway_events ++ @dns_form_events

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject
    unified_devices? = Portal.Account.unified_devices?(subject.account)

    if connected?(socket) do
      :ok = Devices.Account.subscribe(subject.account.id)
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id, :devices)
    end

    socket =
      socket
      |> assign(page_title: "Devices")
      |> assign(selected_device: nil)
      |> assign(unified_devices?: unified_devices?)
      |> assign(device_site: nil, sites: [], gateway_panel: base_gateway_panel())
      |> assign(dns_form: nil)
      |> assign(stale: false)
      |> assign_async(:devices_count, fn -> {:ok, %{devices_count: Database.count_devices(subject)}} end)
      |> assign(
        device_pools: [],
        policy_authorizations: [],
        policy_authorizations_page: 1,
        policy_authorizations_has_next: false,
        policy_authorizations_expanded_id: nil,
        device_posture: [],
        device_certificate: nil,
        posture_providers_connected?: false,
        serials_by_device: %{},
        sites_by_device: %{},
        devices: [],
        devices_metadata: %Portal.Repo.OffsetPaginator.Metadata{}
      )
      |> assign(base_device_assigns())
      |> LiveTable.assign_live_table("devices",
        query_module: Database,
        sortable_fields: [
          {:devices, :slug},
          {:devices, :last_seen_version},
          {:devices, :last_seen_at},
          {:devices, :inserted_at},
          {:devices, :last_seen_user_agent}
        ],
        hide_filters: if(unified_devices?, do: [], else: [:site_id, :has_users]),
        loader: &load_devices/2
      )
      |> PortalWeb.Live.Helpers.drop_stale_events(&stale_event?/2)

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = LiveTable.handle_live_tables_params(socket, params, uri)

    case Database.get_device_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_devices_index(socket, "Device does not exist.")

      device ->
        page = parse_page(params)
        tab = device_tab(device, parse_device_tab(Map.get(params, "tab", "overview")))

        {policy_authorizations, has_next} =
          Database.list_policy_authorizations_for_device(device, socket.assigns.subject, page)

        {:noreply,
         socket
         |> assign(selected_device: device)
         |> assign(show_device_assigns(tab))
         |> assign(
           device_pools: Database.list_device_pools(device, socket.assigns.subject),
           policy_authorizations: policy_authorizations,
           policy_authorizations_page: page,
           policy_authorizations_has_next: has_next,
           policy_authorizations_expanded_id: nil,
           device_posture: Database.list_posture_for_device(device, socket.assigns.subject),
           device_certificate: Database.certificate_status(device, socket.assigns.subject),
           posture_providers_connected?:
             Database.posture_providers_connected?(socket.assigns.subject)
         )
         |> assign_site_assignment(device)
         |> assign_gateway_panel(device)
         |> assign_dns_form(device)}
    end
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = LiveTable.handle_live_tables_params(socket, params, uri)

    case Database.get_device_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_devices_index(socket, "Device does not exist.")

      %Device{type: :gateway} = gateway ->
        {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{gateway.id}"))}

      device ->
        changeset = Database.change_device(device)

        {:noreply,
         socket
         |> assign(selected_device: device)
         |> assign(edit_device_assigns(to_form(changeset)))}
    end
  end

  def handle_params(params, uri, socket) do
    socket = LiveTable.handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(
       selected_device: nil,
       device_pools: [],
       device_posture: [],
       device_certificate: nil,
       dns_form: nil
     )
     |> assign(base_device_assigns())}
  end

  defp assign_site_assignment(%{assigns: %{unified_devices?: true}} = socket, device) do
    subject = socket.assigns.subject

    assign(socket,
      device_site: Database.get_device_site(device, subject),
      sites: Database.list_sites(subject)
    )
  end

  defp assign_site_assignment(socket, _device), do: socket

  defp assign_gateway_panel(%{assigns: %{device_site: %Portal.Site{} = site}} = socket, %Device{type: :gateway} = gateway) do
    subject = socket.assigns.subject
    legacy_tokens = Portal.Devices.list_gateway_tokens_for_site(site.id, subject)

    assign(socket,
      gateway_panel: %{
        base_gateway_panel()
        | device_tokens: load_gateway_tokens(gateway, site, subject),
          legacy_token_ids: MapSet.new(legacy_tokens, & &1.id)
      }
    )
  end

  defp assign_gateway_panel(socket, _device), do: assign(socket, gateway_panel: base_gateway_panel())

  # Only a device last seen on /device/v1 reads its own upstream DNS.
  defp assign_dns_form(%{assigns: %{unified_devices?: true}} = socket, %Device{last_seen_device_v1: true} = device),
    do: assign(socket, dns_form: to_form(Database.change_upstream_dns(device)))

  defp assign_dns_form(socket, _device), do: assign(socket, dns_form: nil)

  defp load_gateway_tokens(gateway, site, subject) do
    site.id
    |> Portal.Devices.list_gateway_tokens_for_devices_in_site(subject)
    |> Enum.filter(&(&1.device_id == gateway.id))
    |> Enum.group_by(& &1.device_id)
  end

  defp load_devices(subject, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :online?])

    with {:ok, devices, metadata} <- Database.list_devices(subject, list_opts) do
      assigns = %{
        devices: devices,
        devices_metadata: metadata,
        serials_by_device: Database.serial_index(devices, subject)
      }

      if Portal.Account.unified_devices?(subject.account) do
        {:ok, Map.put(assigns, :sites_by_device, Database.sites_by_device(devices, subject))}
      else
        {:ok, assigns}
      end
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <Page.page_header>
        <:icon>
          <Core.icon name="ri-computer-line" class="w-16 h-16 text-brand" />
        </:icon>
        <:title>Devices</:title>
        <:description>
          End-user devices and servers that access your protected Resources.
        </:description>
        <:action>
          <Navigation.docs_action show_label size="md" path="/deploy/clients" />
        </:action>
        <:stats>
          <.async_result :let={count} assign={@devices_count}>
            <:loading><Core.badge type="primary">Loading...</Core.badge></:loading>
            <Core.dual_badge type="primary">
              <:left>{count}</:left>
              <:right>Total</:right>
            </Core.dual_badge>
          </.async_result>
        </:stats>
      </Page.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <LiveTable.live_table
          stale={@stale}
          id="devices"
          loading={@loading_by_table_id["devices"]}
          query_error={@query_error_by_table_id["devices"]}
          rows={@devices}
          row_id={&"device-#{&1.id}"}
          row_click={fn device -> ~p"/#{@account}/devices/#{device.id}?#{@query_params}" end}
          row_selected={
            fn device -> not is_nil(@selected_device) and device.id == @selected_device.id end
          }
          filters={@filters_by_table_id["devices"]}
          filter={@filter_form_by_table_id["devices"]}
          ordered_by={@order_by_table_id["devices"]}
          metadata={@devices_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={device} field={{:devices, :slug}} label="Device" class="w-80">
            <div class="flex items-center gap-2">
              <span class="mr-2">
                <DeviceComponents.device_os_icon device={device} />
              </span>
              <div>
                <div class="font-medium text-heading group-hover:text-brand transition-colors">
                  {device.slug}
                </div>
                <div class="font-mono text-[10px] text-subtle mt-0.5">
                  {device.id}
                </div>
              </div>
              <Core.badge :if={@unified_devices? and device.type == :gateway} type="neutral" size="xs">
                Gateway
              </Core.badge>
            </div>
          </:col>
          <:col :let={device} :if={@unified_devices?} label="Routes for" class="w-40">
            <DeviceComponents.site_chip account={@account} site={Map.get(@sites_by_device, device.id)} />
          </:col>
          <:col :let={device} label="Owner">
            <DeviceComponents.actor_name_and_role
              account={@account}
              actor={device.actor}
              class="text-sm"
              return_to={@return_to}
            />
          </:col>
          <:col :let={device} label="Serial" class="w-44">
            <DeviceComponents.serial_cell serial={Map.get(@serials_by_device, device.id)} />
          </:col>
          <:col :let={device} field={{:devices, :last_seen_version}} label="Version" class="w-32">
            <DeviceComponents.version
              current={device.last_seen_version}
              latest={DeviceComponents.latest_version(device)}
            />
          </:col>
          <:col :let={device} label="Status" class="w-28">
            <DeviceComponents.device_status_badge device={device} />
          </:col>
          <:col
            :let={device}
            field={{:devices, :last_seen_at}}
            label="Last Started"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-subtle">
              <Core.relative_datetime datetime={device.last_seen_at} />
            </span>
          </:col>
          <:col
            :let={device}
            field={{:devices, :inserted_at}}
            label="Created"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-subtle">
              <Core.relative_datetime datetime={device.inserted_at} />
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-border bg-raised flex items-center justify-center">
                <Core.icon name="ri-computer-line" class="w-5 h-5 text-subtle" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-heading">No devices yet</p>
                <p class="text-xs text-subtle mt-0.5">
                  No devices have connected yet.
                </p>
              </div>
            </div>
          </:empty>
        </LiveTable.live_table>
      </div>

      <DeviceComponents.device_panel
        account={@account}
        device={@selected_device}
        panel={device_panel_state(assigns)}
        confirm_state={device_confirm_state(assigns)}
        query_params={@query_params}
        device_pools={@device_pools}
        posture={@device_posture}
        posture_providers_connected?={@posture_providers_connected?}
        certificate={@device_certificate}
        policy_authorizations={@policy_authorizations}
        policy_authorizations_page={@policy_authorizations_page}
        policy_authorizations_has_next={@policy_authorizations_has_next}
        policy_authorizations_expanded_id={@policy_authorizations_expanded_id}
        site_assignment={
          if @unified_devices?, do: %{site: @device_site, sites: @sites}, else: nil
        }
        gateway_panel={@gateway_panel}
        dns_form={@dns_form}
      />
    </div>
    """
  end

  defp device_panel_state(assigns) do
    %{
      panel_view: assigns.device_panel.view,
      panel_tab: assigns.device_panel.tab,
      device_edit_form: assigns.device_panel.edit_form
    }
  end

  defp device_confirm_state(assigns) do
    %{
      confirm_delete_device: assigns.device_confirm.delete?,
      confirm_unverify_device: assigns.device_confirm.unverify?
    }
  end

  defp stale_event?(event, %{device_panel: %{edit_form: nil}}) when event in @edit_form_events, do: true
  defp stale_event?(event, %{selected_device: nil}) when event in @selected_device_events, do: true
  defp stale_event?(event, %{dns_form: nil}) when event in @dns_form_events, do: true
  defp stale_event?(_event, _assigns), do: false

  defp base_gateway_panel do
    %{
      device_tokens: %{},
      legacy_token_ids: MapSet.new(),
      rename_gateway_id: nil,
      confirm_rotate_gateway_id: nil,
      rotated_gateway_token: nil
    }
  end

  defp base_device_assigns do
    [
      device_panel: %{
        view: :details,
        tab: :overview,
        edit_form: nil
      },
      device_confirm: %{
        delete?: false,
        unverify?: false
      }
    ]
  end

  defp show_device_assigns(tab) do
    assigns = base_device_assigns()
    Keyword.update!(assigns, :device_panel, &Map.put(&1, :tab, tab))
  end

  defp edit_device_assigns(form) do
    [
      device_panel: %{
        view: :edit_device,
        tab: :overview,
        edit_form: form
      },
      device_confirm: %{
        delete?: false,
        unverify?: false
      }
    ]
  end

  defp merge_state(socket, key, attrs) do
    update(socket, key, &Map.merge(&1, Map.new(attrs)))
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "reload", "table_row_click", "change_limit"],
      do: LiveTable.handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices"))}
  end

  def handle_event(
        "switch_device_tab",
        %{"tab" => tab},
        %{assigns: %{selected_device: %Device{} = device}} = socket
      ) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{device}", tab: tab))}
  end

  def handle_event("switch_device_tab", _params, %{assigns: %{selected_device: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("change_policy_authorizations_page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket,
       to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}", tab: "authorizations", page: page)
     )}
  end

  def handle_event("toggle_policy_authorization_row", %{"id" => id}, socket) do
    expanded =
      if socket.assigns.policy_authorizations_expanded_id == id, do: nil, else: id

    {:noreply, assign(socket, policy_authorizations_expanded_id: expanded)}
  end

  def handle_event(event, _params, %{assigns: %{selected_device: %Device{type: :gateway}}} = socket)
      when event in @client_only_events do
    {:noreply, socket}
  end

  def handle_event(
        "put_device_in_site",
        %{"site_device" => %{"site_id" => site_id}},
        %{assigns: %{unified_devices?: true}} = socket
      )
      when site_id != "" do
    device = socket.assigns.selected_device

    case Database.put_device_in_site(device, site_id, socket.assigns.subject) do
      {:ok, _site_device} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device added to the site.")
         |> assign_site_assignment(device)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not add the device to the site.")}
    end
  end

  def handle_event("put_device_in_site", _params, socket), do: {:noreply, socket}

  def handle_event("remove_device_from_site", _params, %{assigns: %{unified_devices?: true}} = socket) do
    device = socket.assigns.selected_device

    case Database.remove_device_from_site(device, socket.assigns.subject) do
      {:ok, _device} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device removed from the site.")
         |> assign_site_assignment(device)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove the device from the site.")}
    end
  end

  def handle_event("remove_device_from_site", _params, socket), do: {:noreply, socket}

  def handle_event("open_device_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}/edit"))}
  end

  def handle_event("cancel_device_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}"))}
  end

  def handle_event("change_device_edit_form", %{"device" => attrs}, socket) do
    changeset =
      Database.change_device(socket.assigns.selected_device, attrs)
      |> Map.put(:action, :validate)

    {:noreply, merge_state(socket, :device_panel, edit_form: to_form(changeset))}
  end

  def handle_event("submit_device_edit_form", %{"device" => attrs}, socket) do
    changeset = Database.change_device(socket.assigns.selected_device, attrs)

    case Database.update_device(changeset, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device updated successfully.")
         |> LiveTable.reload_live_table!("devices")
         |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{updated_client.id}"))}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :device_panel,
           edit_form: to_form(Map.put(changeset, :action, :validate))
         )}
    end
  end

  def handle_event("change_device_dns", %{"device" => attrs}, socket) do
    form =
      socket.assigns.selected_device
      |> Database.change_upstream_dns(attrs)
      |> to_form(action: :validate)

    {:noreply, assign(socket, dns_form: form)}
  end

  def handle_event("submit_device_dns", %{"device" => attrs}, socket) do
    device = socket.assigns.selected_device
    changeset = Database.change_upstream_dns(device, attrs)

    case Database.update_device(changeset, socket.assigns.subject) do
      {:ok, updated} ->
        device = %{device | upstream_dns: updated.upstream_dns, updated_at: updated.updated_at}

        {:noreply,
         socket
         |> put_flash(:success, "DNS settings saved.")
         |> assign(selected_device: device)
         |> assign_dns_form(device)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, dns_form: to_form(changeset, action: :validate))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save the DNS settings.")}
    end
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.device_panel.view == :edit_device do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}"))}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_device) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices"))}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_delete_device", _params, socket) do
    {:noreply, merge_state(socket, :device_confirm, delete?: true)}
  end

  def handle_event("cancel_delete_device", _params, socket) do
    {:noreply, merge_state(socket, :device_confirm, delete?: false)}
  end

  def handle_event("verify_device", _params, socket) do
    device = socket.assigns.selected_device

    case Database.verify_device(device, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{device.name}\" was verified.")
         |> assign_updated_selected_device(updated_client)
         |> merge_state(:device_confirm, unverify?: false)
         |> LiveTable.reload_live_table!("devices")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to verify device.")}
    end
  end

  def handle_event("confirm_unverify_device", _params, socket) do
    {:noreply, merge_state(socket, :device_confirm, unverify?: true)}
  end

  def handle_event("cancel_unverify_device", _params, socket) do
    {:noreply, merge_state(socket, :device_confirm, unverify?: false)}
  end

  def handle_event("unverify_device", _params, socket) do
    device = socket.assigns.selected_device

    case Database.remove_device_verification(device, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{device.name}\" was unverified.")
         |> assign_updated_selected_device(updated_client)
         |> merge_state(:device_confirm, unverify?: false)
         |> LiveTable.reload_live_table!("devices")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to unverify device.")
         |> merge_state(:device_confirm, unverify?: false)}
    end
  end

  def handle_event("delete_device", _params, %{assigns: %{selected_device: %Device{type: :gateway}}} = socket) do
    case delete_gateway(socket.assigns) do
      {count, _} when is_integer(count) and count > 0 ->
        {:noreply,
         socket
         |> put_flash(:success, "Gateway deleted.")
         |> merge_state(:device_confirm, delete?: false)
         |> LiveTable.reload_live_table!("devices")
         |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices"))}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete gateway.")
         |> merge_state(:device_confirm, delete?: false)}
    end
  end

  def handle_event("delete_device", _params, socket) do
    device = socket.assigns.selected_device

    case Database.delete_device(device, socket.assigns.subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{device.name}\" was deleted.")
         |> merge_state(:device_confirm, delete?: false)
         |> LiveTable.reload_live_table!("devices")
         |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices"))}

      {:error, _} ->
        {:noreply, merge_state(socket, :device_confirm, delete?: false)}
    end
  end

  def handle_event(event, params, %{assigns: %{selected_device: %Device{type: :gateway}, device_site: %Portal.Site{}}} = socket)
      when event in @gateway_events do
    handle_gateway_event(event, params, socket)
  end

  def handle_event(event, _params, socket) when event in @gateway_events, do: {:noreply, socket}

  defp handle_gateway_event("rename_gateway", _params, socket) do
    {:noreply,
     merge_state(socket, :gateway_panel,
       rename_gateway_id: socket.assigns.selected_device.id,
       confirm_rotate_gateway_id: nil
     )}
  end

  defp handle_gateway_event("cancel_rename_gateway", _params, socket) do
    {:noreply, merge_state(socket, :gateway_panel, rename_gateway_id: nil)}
  end

  defp handle_gateway_event("save_gateway_name", %{"name" => name}, socket)
       when not is_nil(socket.assigns.gateway_panel.rename_gateway_id) do
    %{selected_device: device, device_site: site, subject: subject} = socket.assigns

    with {:ok, gateway} <- Portal.Devices.fetch_gateway(device.id, site, subject),
         {:ok, renamed} <- Portal.Devices.rename_gateway(gateway, name, subject) do
      {:noreply,
       socket
       |> put_flash(:success, "Gateway renamed.")
       |> assign(selected_device: %{device | name: renamed.name, updated_at: renamed.updated_at})
       |> merge_state(:gateway_panel, rename_gateway_id: nil)
       |> LiveTable.reload_live_table!("devices")}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to rename gateway.")
         |> merge_state(:gateway_panel, rename_gateway_id: nil)}
    end
  end

  defp handle_gateway_event("save_gateway_name", _params, socket), do: {:noreply, socket}

  defp handle_gateway_event("rotate_gateway_token", _params, socket) do
    {:noreply,
     merge_state(socket, :gateway_panel,
       confirm_rotate_gateway_id: socket.assigns.selected_device.id,
       rename_gateway_id: nil
     )}
  end

  defp handle_gateway_event("cancel_rotate_gateway_token", _params, socket) do
    {:noreply, merge_state(socket, :gateway_panel, confirm_rotate_gateway_id: nil)}
  end

  defp handle_gateway_event("confirm_rotate_gateway_token", _params, socket) do
    %{selected_device: device, device_site: site, subject: subject} = socket.assigns

    with {:ok, gateway} <- Portal.Devices.fetch_gateway(device.id, site, subject),
         {:ok, _token, encoded_token} <- Portal.Devices.rotate_gateway_token(gateway, subject) do
      prior_tokens = Map.get(socket.assigns.gateway_panel.device_tokens, gateway.id, [])
      device_tokens = load_gateway_tokens(gateway, site, subject)

      replaced_unused? =
        Sites.Components.replaced_unused_token?(prior_tokens, Map.get(device_tokens, gateway.id, []))

      {:noreply,
       socket
       |> put_flash(:success, "Token rotated.")
       |> merge_state(:gateway_panel,
         confirm_rotate_gateway_id: nil,
         rotated_gateway_token: %{
           gateway_id: gateway.id,
           encoded: encoded_token,
           replaced_unused: replaced_unused?
         },
         device_tokens: device_tokens
       )}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to rotate token.")
         |> merge_state(:gateway_panel, confirm_rotate_gateway_id: nil)}
    end
  end

  defp handle_gateway_event("dismiss_rotated_gateway_token", _params, socket) do
    {:noreply, merge_state(socket, :gateway_panel, rotated_gateway_token: nil)}
  end

  defp delete_gateway(%{device_site: %Portal.Site{} = site} = assigns) do
    Portal.Devices.delete_gateway_by_id(assigns.selected_device.id, site, assigns.subject)
  end

  defp delete_gateway(_assigns), do: {:error, :no_site}

  defp assign_updated_selected_device(socket, updated_client) do
    selected_device = %{
      socket.assigns.selected_device
      | verified_at: updated_client.verified_at,
        updated_at: updated_client.updated_at
    }

    assign(socket, :selected_device, selected_device)
  end

  defp parse_device_tab("authorizations"), do: :authorizations
  defp parse_device_tab("posture"), do: :posture
  defp parse_device_tab("overview"), do: :overview
  defp parse_device_tab(_), do: :overview

  defp device_tab(%Device{type: :gateway}, :posture), do: :overview
  defp device_tab(_device, tab), do: tab

  defp parse_page(params) do
    case Integer.parse(Map.get(params, "page", "1")) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp redirect_to_devices_index(socket, message) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/devices"))}
  end

  def handle_info(%Change{struct: %Device{type: :gateway}}, %{assigns: %{unified_devices?: false}} = socket),
    do: {:noreply, socket}

  def handle_info(%Change{old_struct: %Device{type: :gateway}}, %{assigns: %{unified_devices?: false}} = socket),
    do: {:noreply, socket}

  def handle_info(%Change{op: :insert, struct: %Device{}} = change, socket) do
    {:noreply,
     socket
     |> update(:devices_count, fn
       %AsyncResult{ok?: true} = ar -> AsyncResult.ok(ar, ar.result + 1)
       ar -> ar
     end)
     |> mark_stale_if_unreflected(change)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Device{}} = change, socket) do
    {:noreply,
     socket
     |> update(:devices_count, fn
       %AsyncResult{ok?: true} = ar -> AsyncResult.ok(ar, max(ar.result - 1, 0))
       ar -> ar
     end)
     |> mark_stale_if_unreflected(change)}
  end

  def handle_info(%Change{struct: %Device{}} = change, socket) do
    {:noreply, mark_stale_if_unreflected(socket, change)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_devices:" <> _account_id} = event,
        socket
      ) do
    rendered_client_ids = Enum.map(socket.assigns.devices, & &1.id)

    if LiveTable.presence_updates_any_id?(event, rendered_client_ids) do
      socket = LiveTable.reload_live_table!(socket, "devices")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  defp mark_stale_if_unreflected(socket, change) do
    LiveTable.mark_stale_unless_reflected(socket, "devices", socket.assigns.devices, change)
  end

  defmodule Database do
    import Ecto.Changeset
    import Ecto.Query
    import Portal.Changeset
    import Portal.Repo.Query
    alias Portal.{Presence.Devices, Safe}
    alias Portal.Device
    alias Portal.Policy
    alias Portal.PolicyAuthorization
    alias Portal.Group
    alias Portal.Resource
    alias Portal.Repo.Filter
    alias Portal.Repo.OffsetPaginator
    alias Portal.PostureProvider
    alias Portal.Site
    alias Portal.SiteDevice

    def count_devices(subject) do
      subject
      |> page_query()
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    def list_devices(subject, opts \\ []) do
      {preload, opts} = Keyword.pop(opts, :preload, [])
      {filter, opts} = Keyword.pop(opts, :filter, [])
      filter = drop_unified_filters(filter, subject)
      {order_by, opts} = Keyword.pop(opts, :order_by, [])
      {page_opts, _opts} = Keyword.pop(opts, :page, [])

      # Check if we need to prefilter by presence
      base_query =
        subject
        |> page_query()
        |> maybe_filter_by_presence(Keyword.get(filter, :presence), subject)

      with {:ok, paginator_opts} <- OffsetPaginator.init(__MODULE__, order_by, page_opts),
           {:ok, filtered_query} <- Filter.filter(base_query, __MODULE__, filter),
           count when is_integer(count) <-
             Safe.aggregate(Safe.scoped(filtered_query, subject), :count),
           client_ids <- list_device_ids(filtered_query, paginator_opts, subject),
           {client_ids, metadata} <- OffsetPaginator.metadata(client_ids, paginator_opts) do
        devices = fetch_devices_page(client_ids, preload, subject)
        {:ok, devices, %{metadata | count: count}}
      else
        {:error, :unauthorized} = error -> error
        {:error, _reason} = error -> error
      end
    end

    defp page_query(subject) do
      if Portal.Account.unified_devices?(subject.account) do
        from(d in Device, as: :devices)
      else
        from(d in Device, as: :devices)
        |> where([devices: d], d.type == :client)
      end
    end

    defp drop_unified_filters(filter, subject) do
      if Portal.Account.unified_devices?(subject.account) do
        filter
      else
        Keyword.drop(filter, [:site_id, :has_users])
      end
    end

    defp listed_online_ids(subject) do
      if Portal.Account.unified_devices?(subject.account) do
        Devices.online_ids(subject.account.id)
      else
        Devices.online_ids(subject.account.id, :client)
      end
    end

    defp maybe_filter_by_presence(base_query, presence, subject) do
      case presence do
        "online" ->
          ids = listed_online_ids(subject)
          where(base_query, [devices: d], d.id in ^ids)

        "offline" ->
          ids = listed_online_ids(subject)
          where(base_query, [devices: d], d.id not in ^ids)

        _ ->
          base_query
      end
    end

    defp list_device_ids(filtered_query, paginator_opts, subject) do
      filtered_query
      |> select([devices: d], d.id)
      |> OffsetPaginator.query(paginator_opts)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp fetch_devices_page([], _preload, _subject), do: []

    defp fetch_devices_page(client_ids, preload, subject) do
      devices =
        page_query(subject)
        |> where([devices: d], d.id in ^client_ids)
        |> Safe.scoped(subject)
        |> Safe.all()
        |> maybe_preload_devices(preload, subject)

      clients_by_id = Map.new(devices, &{&1.id, &1})

      client_ids
      |> Enum.map(&Map.get(clients_by_id, &1))
      |> Enum.reject(&is_nil/1)
    end

    defp maybe_preload_devices(devices, preload, subject) do
      Enum.reduce(preload, devices, fn
        :actor, devices ->
          Portal.Devices.put_latest_actor(devices, subject)

        :online?, devices ->
          Devices.preload_presence(devices)

        _other, devices ->
          devices
      end)
    end

    @spec change_device(Portal.Device.t(), map()) :: Ecto.Changeset.t()
    def change_device(device, attrs \\ %{}) do
      import Ecto.Changeset

      device
      |> cast(attrs, [:name, :slug])
      |> validate_required([:name, :slug])
      |> Portal.Device.changeset()
    end

    @spec change_upstream_dns(Portal.Device.t(), map()) :: Ecto.Changeset.t()
    def change_upstream_dns(device, attrs \\ %{}) do
      # "default" clears the override, so the device follows the account.
      attrs =
        case attrs do
          %{"upstream_dns" => %{"type" => "default"}} -> Map.put(attrs, "upstream_dns", nil)
          attrs -> attrs
        end

      device
      |> cast(attrs, [])
      |> cast_embed(:upstream_dns, with: &Portal.UpstreamDNS.changeset/2)
      |> Portal.Device.changeset()
    end

    @spec update_device(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
    def update_device(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Devices.preload_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec verify_device(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t()}
    def verify_device(device, subject) do
      device
      |> change()
      |> put_default_value(:verified_at, DateTime.utc_now())
      |> update_device(subject)
    end

    @spec remove_device_verification(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t()}
    def remove_device_verification(device, subject) do
      device
      |> change()
      |> put_change(:verified_at, nil)
      |> update_device(subject)
    end

    @spec delete_device(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, term()}
    def delete_device(device, subject) do
      case Safe.scoped(device, subject) |> Safe.delete() do
        {:ok, deleted_client} ->
          {:ok, Devices.preload_presence([deleted_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec get_device_for_panel(binary(), Portal.Authentication.Subject.t()) ::
            Portal.Device.t() | nil
    def get_device_for_panel(id, subject) do
      device =
        subject
        |> page_query()
        |> where([devices: d], d.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case device do
        %Device{} ->
          [device] |> Portal.Devices.put_latest_actor(subject) |> Devices.preload_presence() |> List.first()

        _ ->
          nil
      end
    end

    @spec get_device_site(Device.t(), Portal.Authentication.Subject.t()) :: Site.t() | nil
    def get_device_site(%Device{} = device, subject) do
      from(s in Site, as: :sites)
      |> join(:inner, [sites: s], sd in SiteDevice,
        on: sd.account_id == s.account_id and sd.site_id == s.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.device_id == ^device.id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        {:error, _} -> nil
        site -> site
      end
    end

    @spec sites_by_device([Device.t()], Portal.Authentication.Subject.t()) :: %{
            Ecto.UUID.t() => Site.t()
          }
    def sites_by_device(devices, subject) do
      device_ids = Enum.map(devices, & &1.id)

      from(s in Site, as: :sites)
      |> join(:inner, [sites: s], sd in SiteDevice,
        on: sd.account_id == s.account_id and sd.site_id == s.id,
        as: :site_device
      )
      |> where([site_device: sd], sd.device_id in ^device_ids)
      |> select([sites: s, site_device: sd], {sd.device_id, s})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> %{}
        rows -> Map.new(rows)
      end
    end

    @spec list_sites(Portal.Authentication.Subject.t()) :: [Site.t()]
    def list_sites(subject) do
      from(s in Site, as: :sites)
      |> order_by([sites: s], asc: s.name)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        sites -> sites
      end
    end

    @spec put_device_in_site(Device.t(), String.t(), Portal.Authentication.Subject.t()) ::
            {:ok, SiteDevice.t()} | {:error, term()}
    def put_device_in_site(%Device{} = device, site_id, subject) do
      Safe.transact(fn ->
        with {:ok, device} <- fetch_device_v1(device, subject),
             {:ok, site} <- fetch_site(site_id, subject) do
          %SiteDevice{account_id: device.account_id, site_id: site.id, device_id: device.id}
          |> change()
          |> SiteDevice.changeset()
          |> Safe.scoped(subject)
          |> Safe.insert()
        end
      end)
    end

    @spec remove_device_from_site(Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Device.t()} | {:error, term()}
    def remove_device_from_site(%Device{} = device, subject) do
      Portal.Devices.remove_from_site(device, subject)
    end

    @spec list_device_pools(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            [Resource.t()]
    def list_device_pools(%Device{} = device, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.type == :device_pool)
      |> where(
        [resources: r],
        fragment("jsonb_exists(? #> '{device,value}', ?)", r.device_membership_criteria, ^device.id)
      )
      |> order_by([resources: r], asc: r.name)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        resources -> resources
      end
    end

    def cursor_fields do
      [
        {:devices, :desc, :last_seen_at},
        {:devices, :asc, :id}
      ]
    end

    def preloads do
      [
        :actor,
        online?: &Devices.preload_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "Device or Actor",
          type: {:string, :websearch},
          fun: &filter_by_search_fts/2
        },
        %Portal.Repo.Filter{
          name: :attestation,
          title: "Trust level",
          type: {:string, :select},
          values: [
            {"Verified", "verified"},
            {"Attested", "attested"},
            {"None", "none"}
          ],
          fun: &filter_by_attestation/2
        },
        %Portal.Repo.Filter{
          name: :presence,
          title: "Presence",
          type: :string,
          values: [
            {"Online", "online"},
            {"Offline", "offline"}
          ],
          fun: &filter_by_presence/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :select},
          values: &list_sites/1,
          fun: &filter_by_site/2
        },
        %Portal.Repo.Filter{
          name: :has_users,
          title: "Has users",
          type: :boolean,
          fun: &filter_by_has_users/2
        }
      ]
    end

    def filter_by_site(queryable, site_id) do
      case Ecto.UUID.cast(site_id) do
        {:ok, site_id} ->
          {queryable,
           dynamic(
             [devices: devices],
             exists(
               from(sd in SiteDevice,
                 where:
                   sd.account_id == parent_as(:devices).account_id and
                     sd.device_id == parent_as(:devices).id and sd.site_id == ^site_id
               )
             )
           )}

        :error ->
          {queryable, dynamic(false)}
      end
    end

    def filter_by_has_users(queryable, true) do
      {queryable,
       dynamic(
         [devices: devices],
         exists(
           from(da in Portal.DeviceActor,
             where:
               da.account_id == parent_as(:devices).account_id and
                 da.device_id == parent_as(:devices).id
           )
         )
       )}
    end

    def filter_by_has_users(queryable, false), do: {queryable, nil}

    def filter_by_search_fts(queryable, search_term) do
      {queryable,
       dynamic(
         [devices: devices],
         fulltext_search(devices.name, ^search_term) or
           fulltext_search(devices.slug, ^search_term) or
           exists(
             from(da in Portal.DeviceActor,
               join: a in Portal.Actor,
               on: a.account_id == da.account_id and a.id == da.actor_id,
               where:
                 da.account_id == parent_as(:devices).account_id and
                   da.device_id == parent_as(:devices).id and
                   (fulltext_search(a.name, ^search_term) or fulltext_search(a.email, ^search_term))
             )
           )
       )}
    end

    # A device that attested is badged "Attested" rather than "Verified" however
    # its verified_at reads, so the two options have to be exclusive here too or
    # the filter would disagree with the panel.
    def filter_by_attestation(queryable, "verified") do
      {queryable,
       dynamic(
         [devices: devices],
         not is_nil(devices.verified_at) and is_nil(devices.last_attested_at)
       )}
    end

    def filter_by_attestation(queryable, "attested") do
      {queryable, dynamic([devices: devices], not is_nil(devices.last_attested_at))}
    end

    def filter_by_attestation(queryable, "none") do
      {queryable,
       dynamic(
         [devices: devices],
         is_nil(devices.verified_at) and is_nil(devices.last_attested_at)
       )}
    end

    def filter_by_presence(queryable, _presence) do
      # This is handled as a prefilter in list_devices
      # Return the queryable unchanged since actual filtering happens above
      {queryable, true}
    end

    @page_size 25

    @spec list_policy_authorizations_for_device(
            Portal.Device.t(),
            Portal.Authentication.Subject.t(),
            non_neg_integer()
          ) :: {[map()], boolean()}
    def list_policy_authorizations_for_device(device, subject, page \\ 1) do
      offset = (page - 1) * @page_size

      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where(
        [policy_authorizations: pa],
        pa.initiating_device_id == ^device.id or pa.receiving_device_id == ^device.id
      )
      |> join(:inner, [policy_authorizations: pa], p in Policy,
        on: p.id == pa.policy_id and p.account_id == pa.account_id,
        as: :policies
      )
      |> join(:left, [policies: p], g in Group,
        on: g.id == p.group_id and g.account_id == p.account_id,
        as: :groups
      )
      |> join(:inner, [policies: p], r in Resource,
        on: r.id == p.resource_id and r.account_id == p.account_id,
        as: :resources
      )
      |> join(:left, [policy_authorizations: pa], id in Device,
        on: id.id == pa.initiating_device_id and id.account_id == pa.account_id,
        as: :initiating_devices
      )
      |> join(:left, [policy_authorizations: pa], rd in Device,
        on: rd.id == pa.receiving_device_id and rd.account_id == pa.account_id,
        as: :receiving_devices
      )
      |> select(
        [
          policy_authorizations: pa,
          groups: g,
          resources: r,
          initiating_devices: id,
          receiving_devices: rd
        ],
        %{
          authorization: pa,
          group: g,
          resource: r,
          initiating_device: id,
          receiving_device: rd
        }
      )
      |> order_by([policy_authorizations: pa], desc: pa.inserted_at, desc: pa.id)
      |> limit(^(@page_size + 1))
      |> offset(^offset)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} ->
          {[], false}

        rows ->
          has_next = length(rows) > @page_size
          {Enum.take(rows, @page_size), has_next}
      end
    end

    @doc """
    Records from the account's posture providers that describe this device.

    A row is matched on the strongest identifier it shares with the Client:

      1. the MDM device id the Client's certificate attested,
      2. the hardware serial that certificate attested,
      3. the self-reported hardware serial.

    Only the first two prove anything. The third is only as trustworthy as the
    actor and the device running the Client, so the panel labels rows matched
    that way.

    Defender for Endpoint issues no device id of its own for a certificate to
    attest and its machines report no hardware serial, so a Defender row is
    reached through the Intune row already matched to this device: both carry
    the same Entra device id. A row reached that way is only as well matched as
    the Intune row that led to it.

    One row per configured provider rather than per provider type, so an
    account running two Intune tenants sees the device in both.
    """
    @spec list_posture_for_device(Device.t(), Portal.Authentication.Subject.t()) :: [
            %{
              type: atom(),
              provider: PostureProvider.t(),
              device: struct(),
              matched_on: :mdm_device_id | :attested_serial | :device_serial,
              via: :intune | nil
            }
          ]
    def list_posture_for_device(%Device{type: :client} = device, subject) do
      providers_by_id = subject |> list_posture_providers() |> Map.new(&{&1.id, &1})

      device
      |> Portal.Devices.Posture.match()
      |> Enum.flat_map(&posture_entry(&1, providers_by_id))
      |> Enum.group_by(& &1.provider.id)
      |> Enum.map(fn {_provider_id, entries} -> best_posture_entry(entries) end)
      |> Enum.sort_by(&{provider_type_rank(&1.type), String.downcase(&1.provider.name)})
    end

    def list_posture_for_device(_device, _subject), do: []

    defp posture_entry({type, device, matched_on, via}, providers_by_id) do
      case Map.fetch(providers_by_id, device.posture_provider_id) do
        {:ok, provider} ->
          [%{type: type, provider: provider, device: device, matched_on: matched_on, via: via}]

        :error ->
          []
      end
    end

    defp best_posture_entry(entries),
      do: Enum.min_by(entries, &Portal.Devices.Posture.rung_rank(&1.matched_on))

    @doc """
    Whether the account has connected a posture provider at all.

    The panel offers its Posture tab to every Device, so it has to tell a
    device no provider holds a record for apart from an account that has no
    provider to hold one.
    """
    @spec posture_providers_connected?(Portal.Authentication.Subject.t()) :: boolean()
    def posture_providers_connected?(subject) do
      from(p in PostureProvider)
      |> Safe.scoped(subject)
      |> Safe.exists?()
      |> case do
        connected? when is_boolean(connected?) -> connected?
        _refused -> false
      end
    end

    @doc """
    The serial number the Devices list shows for each row, and where it came from.

    A Device that attested a serial shows that one. Failing that, the serial the
    account's MDM holds for the device id the Device did attest, which is as
    well proven as that id. Failing both, the self-reported serial, which
    nothing vouches for.

    One query per MDM the account has connected, for the whole page.
    """
    @spec serial_index([Device.t()], Portal.Authentication.Subject.t()) ::
            %{
              Ecto.UUID.t() => %{
                value: String.t(),
                source: :attested | :mdm | :reported,
                provider: atom() | nil
              }
            }
    def serial_index(devices, subject) do
      mdm_device_ids =
        for device <- devices,
            is_nil(device.last_attested_device_serial),
            is_binary(device.last_attested_mdm_device_id),
            uniq: true,
            do: device.last_attested_mdm_device_id

      by_mdm_device_id = mdm_serials(mdm_device_ids, subject)

      for device <- devices, into: %{} do
        {device.id,
         serial_badge(device, Map.get(by_mdm_device_id, device.last_attested_mdm_device_id))}
      end
    end

    defp mdm_serials([], _subject), do: %{}

    defp mdm_serials(mdm_device_ids, subject) do
      connected = subject |> list_posture_providers() |> Enum.map(& &1.type) |> Enum.uniq()

      # Reversed so that the first type to answer for a device id is the one
      # left in the map, since a later merge keeps what is already there.
      for type <- [:iru, :intune], type in connected, reduce: %{} do
        acc -> Map.merge(acc, mdm_serial_rows(type, mdm_device_ids, subject))
      end
    end

    defp mdm_serial_rows(type, mdm_device_ids, subject) do
      [field_name] = Portal.Devices.Posture.rung_fields(type, :mdm_device_id)

      from(d in Portal.Devices.Posture.schema(type),
        where: field(d, ^field_name) in ^mdm_device_ids and not is_nil(d.serial_number),
        select: {field(d, ^field_name), d.serial_number}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        rows when is_list(rows) -> Map.new(rows, fn {id, serial} -> {id, {type, serial}} end)
        _refused -> %{}
      end
    end

    defp serial_badge(%Device{last_attested_device_serial: serial}, _mdm)
         when is_binary(serial) do
      %{value: serial, source: :attested, provider: nil}
    end

    defp serial_badge(%Device{last_attested_mdm_device_id: mdm_id}, {type, serial})
         when is_binary(mdm_id) and is_binary(serial) do
      %{value: serial, source: :mdm, provider: type}
    end

    defp serial_badge(%Device{device_serial: serial}, _mdm) when is_binary(serial) do
      %{value: serial, source: :reported, provider: nil}
    end

    defp serial_badge(_device, _mdm), do: nil

    @doc """
    What the account knows about the certificate this Client last attested with.

    Both mechanisms are read in one round trip because they answer the same
    question and an admin looking at the panel wants whichever of them has an
    answer. A published list beats a responder: a serial on a CRL is revoked
    whatever a stale responder still says about it.

    Returns `nil` when the Client has never attested a certificate.
    """
    @spec certificate_status(Device.t(), Portal.Authentication.Subject.t()) ::
            %{
              state: :revoked | :good | :unknown,
              source: :crl | :ocsp | nil,
              revoked_at: DateTime.t() | nil,
              reason: String.t() | nil,
              next_update: DateTime.t() | nil
            }
            | nil
    def certificate_status(%Device{} = device, subject)
        when is_binary(device.last_attested_cert_issuer) and
               is_binary(device.last_attested_cert_serial) do
      issuer = device.last_attested_cert_issuer
      serial = device.last_attested_cert_serial

      from(a in Portal.Account,
        left_join: r in Portal.CrlRevocation,
        on: r.account_id == a.id and r.issuer == ^issuer and r.serial == ^serial,
        left_join: s in Portal.OcspStatus,
        on: s.account_id == a.id and s.issuer == ^issuer and s.serial == ^serial,
        # A CA that partitions its list holds the same serial in more than one
        # partition, and any one of them revokes it.
        order_by: [asc: r.revoked_at],
        limit: 1,
        select: %{
          crl_revoked_at: r.revoked_at,
          crl_reason: r.reason,
          ocsp_status: s.status,
          ocsp_revoked_at: s.revoked_at,
          ocsp_reason: s.reason,
          ocsp_next_update: s.next_update
        }
      )
      |> Safe.scoped(subject)
      |> Safe.one()
      |> normalize_certificate_status()
    end

    def certificate_status(_device, _subject), do: nil

    defp normalize_certificate_status(%{crl_revoked_at: revoked_at} = row)
         when not is_nil(revoked_at) do
      %{
        state: :revoked,
        source: :crl,
        revoked_at: revoked_at,
        reason: row.crl_reason,
        next_update: row.ocsp_next_update
      }
    end

    defp normalize_certificate_status(%{ocsp_status: "revoked"} = row) do
      %{
        state: :revoked,
        source: :ocsp,
        revoked_at: row.ocsp_revoked_at,
        reason: row.ocsp_reason,
        next_update: row.ocsp_next_update
      }
    end

    defp normalize_certificate_status(%{ocsp_status: "good"} = row) do
      %{
        state: :good,
        source: :ocsp,
        revoked_at: nil,
        reason: nil,
        next_update: row.ocsp_next_update
      }
    end

    defp normalize_certificate_status(%{}) do
      %{state: :unknown, source: nil, revoked_at: nil, reason: nil, next_update: nil}
    end

    # Anything else means the read was refused, which leaves the panel with no
    # facts rather than with false ones.
    defp normalize_certificate_status(_other), do: nil

    defp list_posture_providers(subject) do
      from(p in PostureProvider, order_by: [asc: p.name])
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        providers when is_list(providers) -> providers
        _refused -> []
      end
    end

    defp provider_type_rank(:intune), do: 0
    defp provider_type_rank(:iru), do: 1
    defp provider_type_rank(:defender), do: 2
    defp provider_type_rank(:santa), do: 3
    defp provider_type_rank(:sentinelone), do: 4
    defp provider_type_rank(:sophos), do: 5

    # Only a device last seen on /device/v1 can serve a site.
    defp fetch_device_v1(device, subject) do
      from(d in Device, as: :devices, where: d.id == ^device.id and d.last_seen_device_v1, lock: "FOR UPDATE")
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Device{} = device -> {:ok, device}
        nil -> {:error, :not_device_v1}
        {:error, reason} -> {:error, reason}
      end
    end

    defp fetch_site(site_id, subject) do
      from(s in Site, as: :sites, where: s.id == ^site_id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Site{} = site -> {:ok, site}
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
