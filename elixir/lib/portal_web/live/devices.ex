defmodule PortalWeb.Devices do
  use PortalWeb, :live_view
  import PortalWeb.Devices.Components
  alias Portal.Presence
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PubSub
  alias Phoenix.LiveView.AsyncResult
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    if connected?(socket) do
      :ok = Presence.Clients.Account.subscribe(subject.account.id)
      :ok = Presence.Gateways.Account.subscribe(subject.account.id)
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id, :devices)
    end

    socket =
      socket
      |> assign(page_title: "Devices")
      |> assign(selected_device: nil)
      |> assign(stale: false)
      |> assign_async(:devices_count, fn -> {:ok, %{devices_count: Database.count_devices(subject)}} end)
      |> assign(
        device_pools: [],
        device_posture: [],
        device_certificate: nil,
        posture_providers_connected?: false,
        serials_by_device: %{},
        policy_authorizations: [],
        policy_authorizations_page: 1,
        policy_authorizations_has_next: false,
        policy_authorizations_expanded_id: nil
      )
      |> assign(base_device_assigns())
      |> assign_live_table("devices",
        query_module: Database,
        sortable_fields: [
          {:devices, :name},
          {:devices, :last_seen_version},
          {:devices, :last_seen_at},
          {:devices, :inserted_at},
          {:devices, :last_seen_user_agent}
        ],
        callback: &handle_devices_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_device_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_devices_index(socket, "Device does not exist.")

      device ->
        page = parse_page(params)
        tab = parse_device_tab(Map.get(params, "tab", "overview"))

        {policy_authorizations, has_next} =
          Database.list_policy_authorizations_for_device(device, socket.assigns.subject, page)

        {:noreply,
         socket
         |> assign(selected_device: device)
         |> assign(show_device_assigns(tab))
         |> assign(
           device_pools: Database.list_device_pools(device, socket.assigns.subject),
           device_posture: Database.list_posture_for_device(device, socket.assigns.subject),
           device_certificate: Database.certificate_status(device, socket.assigns.subject),
           posture_providers_connected?:
             Database.posture_providers_connected?(socket.assigns.subject),
           policy_authorizations: policy_authorizations,
           policy_authorizations_page: page,
           policy_authorizations_has_next: has_next,
           policy_authorizations_expanded_id: nil
         )}
    end
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_device_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_devices_index(socket, "Device does not exist.")

      %Device{type: :gateway} = device ->
        {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/devices/#{device.id}")}

      device ->
        changeset = Database.change_device(device)

        {:noreply,
         socket
         |> assign(selected_device: device)
         |> assign(edit_device_assigns(to_form(changeset)))}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(selected_device: nil, device_pools: [], device_posture: [], device_certificate: nil)
     |> assign(base_device_assigns())}
  end

  def handle_devices_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :site, :online?])

    with {:ok, devices, metadata} <- Database.list_devices(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         devices: devices,
         devices_metadata: metadata,
         serials_by_device: Database.serial_index(devices, socket.assigns.subject)
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="ri-computer-line" class="w-16 h-16 text-brand" />
        </:icon>
        <:title>Devices</:title>
        <:description>
          Machines in your organization running a Firezone client or gateway.
        </:description>
        <:action>
          <.docs_action path="/deploy/clients" />
        </:action>
        <:stats>
          <.async_result :let={count} assign={@devices_count}>
            <:loading><.badge type="primary">Loading...</.badge></:loading>
            <.dual_badge type="primary">
              <:left>{count}</:left>
              <:right>Total</:right>
            </.dual_badge>
          </.async_result>
        </:stats>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          stale={@stale}
          id="devices"
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
          <:col :let={device} field={{:devices, :name}} label="Device" class="w-80">
            <div class="flex items-center gap-2">
              <span class="mr-2">
                <.device_os_icon device={device} />
              </span>
              <div>
                <div class="font-medium text-heading group-hover:text-brand transition-colors">
                  {device.name}
                </div>
                <div class="font-mono text-[10px] text-subtle mt-0.5">
                  {device.id}
                </div>
              </div>
            </div>
          </:col>
          <:col :let={device} label="Owner">
            <.device_owner_cell account={@account} device={device} return_to={@return_to} />
          </:col>
          <:col :let={device} label="Serial" class="w-44">
            <.serial_cell serial={Map.get(@serials_by_device, device.id)} />
          </:col>
          <:col :let={device} field={{:devices, :last_seen_version}} label="Version" class="w-32">
            <.version current={device.last_seen_version} latest={latest_version(device)} />
          </:col>
          <:col :let={device} label="Status" class="w-28">
            <.device_status_badge online?={device.online?} />
          </:col>
          <:col
            :let={device}
            field={{:devices, :last_seen_at}}
            label="Last Started"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-subtle">
              <.relative_datetime datetime={device.last_seen_at} />
            </span>
          </:col>
          <:col
            :let={device}
            field={{:devices, :inserted_at}}
            label="Created"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-subtle">
              <.relative_datetime datetime={device.inserted_at} />
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-border bg-raised flex items-center justify-center">
                <.icon name="ri-computer-line" class="w-5 h-5 text-subtle" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-heading">No devices yet</p>
                <p class="text-xs text-subtle mt-0.5">
                  No devices have connected yet.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.device_panel
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
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/devices?#{params}")}
  end

  def handle_event(
        "switch_device_tab",
        %{"tab" => tab},
        %{assigns: %{selected_device: %Device{} = device}} = socket
      ) do
    params =
      socket.assigns.query_params
      |> Map.put("tab", tab)
      |> Map.delete("page")

    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{device}?#{params}"
     )}
  end

  def handle_event("switch_device_tab", _params, %{assigns: %{selected_device: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("change_policy_authorizations_page", %{"page" => page}, socket) do
    params = Map.put(socket.assigns.query_params, "page", page)

    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}?#{params}"
     )}
  end

  def handle_event("toggle_policy_authorization_row", %{"id" => id}, socket) do
    expanded =
      if socket.assigns.policy_authorizations_expanded_id == id, do: nil, else: id

    {:noreply, assign(socket, policy_authorizations_expanded_id: expanded)}
  end

  def handle_event(event, _params, %{assigns: %{selected_device: %Device{type: :gateway}}} = socket)
      when event in [
             "open_device_edit_form",
             "submit_device_edit_form",
             "verify_device",
             "unverify_device",
             "delete_device"
           ] do
    {:noreply, socket}
  end

  def handle_event("open_device_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}/edit"
     )}
  end

  def handle_event("cancel_device_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}"
     )}
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
      {:ok, updated_device} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device updated successfully.")
         |> reload_live_table!("devices")
         |> push_patch(to: ~p"/#{socket.assigns.account}/devices/#{updated_device.id}")}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :device_panel,
           edit_form: to_form(Map.put(changeset, :action, :validate))
         )}
    end
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.device_panel.view == :edit_device do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_device.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_device) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/devices?#{params}")}
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
      {:ok, updated_device} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{device.name}\" was verified.")
         |> assign_updated_selected_device(updated_device)
         |> merge_state(:device_confirm, unverify?: false)
         |> reload_live_table!("devices")}

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
      {:ok, updated_device} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{device.name}\" was unverified.")
         |> assign_updated_selected_device(updated_device)
         |> merge_state(:device_confirm, unverify?: false)
         |> reload_live_table!("devices")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to unverify device.")
         |> merge_state(:device_confirm, unverify?: false)}
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
         |> reload_live_table!("devices")
         |> push_patch(to: ~p"/#{socket.assigns.account}/devices")}

      {:error, _} ->
        {:noreply, merge_state(socket, :device_confirm, delete?: false)}
    end
  end

  defp assign_updated_selected_device(socket, updated_device) do
    selected_device = %{
      socket.assigns.selected_device
      | verified_at: updated_device.verified_at,
        updated_at: updated_device.updated_at
    }

    assign(socket, :selected_device, selected_device)
  end

  defp parse_device_tab("authorizations"), do: :authorizations
  defp parse_device_tab("posture"), do: :posture
  defp parse_device_tab("overview"), do: :overview
  defp parse_device_tab(_), do: :overview

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
     |> push_patch(to: ~p"/#{socket.assigns.account}/devices?#{socket.assigns.query_params}")}
  end

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

  def handle_info(%Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _rest} = event, socket) do
    handle_presence_event(event, socket)
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _rest} = event, socket) do
    handle_presence_event(event, socket)
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  defp handle_presence_event(event, socket) do
    rendered_ids = Enum.map(socket.assigns.devices, & &1.id)

    if presence_updates_any_id?(event, rendered_ids) do
      socket = reload_live_table!(socket, "devices")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp mark_stale_if_unreflected(socket, change) do
    if PortalWeb.LiveTable.view_reflects_change?(socket.assigns.devices, change) do
      socket
    else
      assign(socket, stale: true)
    end
  end

  defmodule Database do
    import Ecto.Changeset
    import Ecto.Query
    import Portal.Changeset
    import Portal.Repo.Query
    alias Portal.{Presence.Clients, Presence.Gateways, Safe}
    alias Portal.Device
    alias Portal.Policy
    alias Portal.PolicyAuthorization
    alias Portal.Group
    alias Portal.Resource
    alias Portal.StaticDevicePoolMember
    alias Portal.Repo.Filter
    alias Portal.Repo.OffsetPaginator
    alias Portal.PostureProvider
    alias Portal.{Defender, Intune, Iru, Santa, SentinelOne}

    def count_devices(subject) do
      from(d in Device, as: :devices)
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    def list_devices(subject, opts \\ []) do
      {preload, opts} = Keyword.pop(opts, :preload, [])
      {filter, opts} = Keyword.pop(opts, :filter, [])
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

    defp page_query(_subject) do
      from(d in Device, as: :devices)
    end

    defp maybe_filter_by_presence(base_query, presence, subject) do
      case presence do
        "online" ->
          ids = online_device_ids(subject.account.id)
          where(base_query, [devices: d], d.id in ^ids)

        "offline" ->
          ids = online_device_ids(subject.account.id)
          where(base_query, [devices: d], d.id not in ^ids)

        _ ->
          base_query
      end
    end

    defp online_device_ids(account_id) do
      Clients.online_client_ids(account_id) ++ Map.keys(Gateways.Account.list(account_id))
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

    defp maybe_preload_devices(devices, preload, _subject) do
      Enum.reduce(preload, devices, fn
        :actor, devices ->
          Safe.preload(devices, :actor)

        :site, devices ->
          Safe.preload(devices, :site)

        :online?, devices ->
          preload_presence(devices)

        _other, devices ->
          devices
      end)
    end

    @spec change_device(Portal.Device.t(), map()) :: Ecto.Changeset.t()
    def change_device(device, attrs \\ %{}) do
      import Ecto.Changeset

      device
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> Portal.Device.changeset()
    end

    @spec update_device(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t()}
    def update_device(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_device} ->
          {:ok, List.first(preload_presence([updated_device]))}

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
        {:ok, deleted_device} ->
          {:ok, List.first(preload_presence([deleted_device]))}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Each type has its own presence, so ask both and keep the input order.
    def preload_presence(devices) do
      {gateways, clients} = Enum.split_with(devices, &(&1.type == :gateway))

      by_id =
        (Clients.preload_clients_presence(clients) ++
           Gateways.preload_gateways_presence(gateways))
        |> Map.new(&{&1.id, &1})

      Enum.map(devices, &Map.fetch!(by_id, &1.id))
    end

    @spec get_device_for_panel(binary(), Portal.Authentication.Subject.t()) ::
            Portal.Device.t() | nil
    def get_device_for_panel(id, subject) do
      device =
        from(d in Device, as: :devices)
        |> where([devices: d], d.id == ^id)
        |> preload([:actor, :site])
        |> Safe.scoped(subject)
        |> Safe.one()

      case device do
        %Device{} -> List.first(preload_presence([device]))
        _refused_or_missing -> nil
      end
    end

    @spec list_device_pools(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            [Resource.t()]
    def list_device_pools(%Device{} = device, subject) do
      from(r in Resource, as: :resources)
      |> join(:inner, [resources: r], m in StaticDevicePoolMember,
        on: m.resource_id == r.id and m.account_id == r.account_id,
        as: :members
      )
      |> where([members: m], m.device_id == ^device.id)
      # The REST API can retype a pool without clearing its members, so filter on
      # the resource rather than trusting the membership rows alone.
      |> where([resources: r], r.type == :static_device_pool)
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
        :site,
        online?: &preload_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "Device, Actor or Site",
          type: {:string, :websearch},
          fun: &filter_by_search_fts/2
        },
        %Portal.Repo.Filter{
          name: :type,
          title: "Type",
          type: :string,
          values: [
            {"Client", "client"},
            {"Gateway", "gateway"}
          ],
          icons: %{"client" => "ri-computer-line", "gateway" => "ri-server-line"},
          fun: &filter_by_type/2
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
        }
      ]
    end

    # Left joins: an inner join on actor or site drops the other type from every search.
    def filter_by_search_fts(queryable, search_term) do
      queryable =
        if has_named_binding?(queryable, :actors) do
          queryable
        else
          join(queryable, :left, [devices: d], a in assoc(d, :actor),
            on: a.account_id == d.account_id,
            as: :actors
          )
        end

      queryable =
        if has_named_binding?(queryable, :sites) do
          queryable
        else
          join(queryable, :left, [devices: d], s in assoc(d, :site),
            on: s.account_id == d.account_id,
            as: :sites
          )
        end

      {queryable,
       dynamic(
         [devices: devices, actors: actors, sites: sites],
         fulltext_search(actors.name, ^search_term) or
           fulltext_search(devices.name, ^search_term) or
           fulltext_search(actors.email, ^search_term) or
           fulltext_search(sites.name, ^search_term)
       )}
    end

    # A device that attested is badged "Attested" rather than "Verified" however
    # its verified_at reads, so the two options have to be exclusive here too or
    # the filter would disagree with the panel.
    def filter_by_type(queryable, "client") do
      {queryable, dynamic([devices: devices], devices.type == :client)}
    end

    def filter_by_type(queryable, "gateway") do
      {queryable, dynamic([devices: devices], devices.type == :gateway)}
    end

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
         devices.type == :client and is_nil(devices.verified_at) and
           is_nil(devices.last_attested_at)
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
    def list_posture_for_device(%Device{} = device, subject) do
      keys = match_keys(device)
      providers = list_posture_providers(subject)

      if keys == [] or providers == [] do
        []
      else
        types = providers |> Enum.map(& &1.type) |> Enum.uniq()
        matched = Enum.flat_map(types, &match_posture(&1, keys, subject))
        providers_by_id = Map.new(providers, &{&1.id, &1})

        (matched ++ link_defender_posture(types, matched, subject))
        |> Enum.flat_map(&posture_entry(&1, providers_by_id))
        |> Enum.group_by(& &1.provider.id)
        |> Enum.map(fn {_provider_id, entries} -> best_posture_entry(entries) end)
        |> Enum.sort_by(&{provider_type_rank(&1.type), String.downcase(&1.provider.name)})
      end
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

    defp best_posture_entry(entries), do: Enum.min_by(entries, &rung_rank(&1.matched_on))

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
      [field_name] = rung_fields(type, :mdm_device_id)

      from(d in posture_schema(type),
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

    # Ordered strongest first: the head of this list is what a matched row is
    # credited to.
    defp match_keys(%Device{} = device) do
      Enum.reject(
        [
          mdm_device_id: device.last_attested_mdm_device_id,
          attested_serial: device.last_attested_device_serial,
          device_serial: device.device_serial
        ],
        fn {_rung, value} -> is_nil(value) end
      )
    end

    defp list_posture_providers(subject) do
      from(p in PostureProvider, order_by: [asc: p.name])
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        providers when is_list(providers) -> providers
        _refused -> []
      end
    end

    defp match_posture(type, keys, subject) do
      case rung_conditions(type, keys) do
        [] ->
          []

        conditions ->
          from(d in posture_schema(type), where: ^Enum.reduce(conditions, &dynamic(^&1 or ^&2)))
          |> Safe.scoped(subject)
          |> Safe.all()
          |> case do
            rows when is_list(rows) ->
              Enum.map(rows, &{type, &1, matched_rung(type, keys, &1), nil})

            _refused ->
              []
          end
      end
    end

    defp link_defender_posture(types, matched, subject) do
      if :defender in types do
        matched
        |> Enum.flat_map(fn
          {:intune, %{entra_device_id: entra_id}, rung, _via} when is_binary(entra_id) ->
            [{entra_id, rung}]

          _other ->
            []
        end)
        |> Enum.sort_by(fn {_entra_id, rung} -> rung_rank(rung) end)
        |> Enum.uniq_by(fn {entra_id, _rung} -> entra_id end)
        |> match_defender_by_entra_id(subject)
      else
        []
      end
    end

    defp match_defender_by_entra_id([], _subject), do: []

    defp match_defender_by_entra_id(entra_ids, subject) do
      rung_by_entra_id = Map.new(entra_ids)

      from(d in Defender.Device, where: d.entra_device_id in ^Map.keys(rung_by_entra_id))
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        rows when is_list(rows) ->
          for row <- rows, rung = Map.get(rung_by_entra_id, row.entra_device_id) do
            {:defender, row, rung, :intune}
          end

        _refused ->
          []
      end
    end

    defp rung_conditions(type, keys) do
      for {rung, value} <- keys,
          field_name <- rung_fields(type, rung),
          do: dynamic([d], field(d, ^field_name) == ^value)
    end

    defp matched_rung(type, keys, row) do
      Enum.find_value(keys, fn {rung, value} ->
        if Enum.any?(rung_fields(type, rung), &(Map.fetch!(row, &1) == value)), do: rung
      end)
    end

    defp posture_schema(:intune), do: Intune.Device
    defp posture_schema(:iru), do: Iru.Device
    defp posture_schema(:defender), do: Defender.Device
    defp posture_schema(:santa), do: Santa.Device
    defp posture_schema(:sentinelone), do: SentinelOne.Device

    # Which columns of a provider's posture row each rung is compared
    # against. Both the query and the credit given to a row it returns are
    # built from this, so they can never disagree.
    #
    # Only an MDM issues a device id a certificate attests, so neither EDR
    # answers that rung. Defender answers none of them: its machine entity
    # carries no hardware serial either, which is why it is reached through
    # Intune instead.
    defp rung_fields(:intune, :mdm_device_id), do: [:intune_id]
    defp rung_fields(:intune, _serial_rung), do: [:serial_number]
    defp rung_fields(:iru, :mdm_device_id), do: [:iru_id]
    defp rung_fields(:iru, _serial_rung), do: [:serial_number]
    defp rung_fields(:defender, _rung), do: []
    defp rung_fields(:santa, :mdm_device_id), do: []
    defp rung_fields(:santa, _serial_rung), do: [:serial_number]
    defp rung_fields(:sentinelone, :mdm_device_id), do: []
    defp rung_fields(:sentinelone, _serial_rung), do: [:serial_number]

    defp rung_rank(:mdm_device_id), do: 0
    defp rung_rank(:attested_serial), do: 1
    defp rung_rank(:device_serial), do: 2

    defp provider_type_rank(:intune), do: 0
    defp provider_type_rank(:iru), do: 1
    defp provider_type_rank(:defender), do: 2
    defp provider_type_rank(:santa), do: 3
    defp provider_type_rank(:sentinelone), do: 4

  end
end
