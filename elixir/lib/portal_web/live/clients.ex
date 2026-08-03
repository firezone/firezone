defmodule PortalWeb.Clients do
  use PortalWeb, :live_view
  import PortalWeb.Clients.Components
  alias Portal.Presence.Clients
  alias Portal.Changes.Change
  alias Portal.{Device, DeviceInventory}
  alias Portal.PubSub
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    if connected?(socket) do
      :ok = Clients.Account.subscribe(subject.account.id)
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id, :devices)
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id, :device_inventory)
    end

    socket =
      socket
      |> assign(page_title: "Devices")
      |> assign(selected_client: nil)
      |> assign(selected_inventory: nil)
      |> assign(stale: false)
      |> assign_async(:clients_count, fn -> {:ok, %{clients_count: Database.count_clients(subject)}} end)
      |> assign(
        policy_authorizations: [],
        policy_authorizations_page: 1,
        policy_authorizations_has_next: false,
        policy_authorizations_expanded_id: nil
      )
      |> assign(base_client_assigns())
      |> assign_live_table("clients",
        query_module: Database,
        sortable_fields: [
          {:device_inventory, :name},
          {:device_inventory, :last_seen_at},
          {:device_inventory, :intune_last_sync_at},
          {:device_inventory, :inserted_at},
          {:device_inventory, :intune_compliance_state}
        ],
        callback: &handle_clients_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_inventory_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_devices_index(socket, "Device does not exist.")

      {inventory, client} ->
        page = parse_page(params)
        tab = parse_client_tab(Map.get(params, "tab", "overview"))

        {policy_authorizations, has_next} =
          if client do
            Database.list_policy_authorizations_for_client(client, socket.assigns.subject, page)
          else
            {[], false}
          end

        {:noreply,
         socket
         |> assign(selected_client: client)
         |> assign(selected_inventory: inventory)
         |> assign(show_client_assigns(tab))
         |> assign(
           policy_authorizations: policy_authorizations,
           policy_authorizations_page: page,
           policy_authorizations_has_next: has_next,
           policy_authorizations_expanded_id: nil
         )}
    end
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_inventory_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_devices_index(socket, "Device does not exist.")

      {_inventory, nil} ->
        redirect_to_devices_index(socket, "This device has not connected to Firezone yet.")

      {inventory, client} ->
        changeset = Database.change_client(client)

        {:noreply,
         socket
         |> assign(selected_client: client)
         |> assign(selected_inventory: inventory)
         |> assign(edit_client_assigns(to_form(changeset)))}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(selected_client: nil)
     |> assign(selected_inventory: nil)
     |> assign(base_client_assigns())}
  end

  def handle_clients_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :online?])

    with {:ok, clients, metadata} <- Database.list_clients(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         clients: clients,
         clients_metadata: metadata
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
          Inventory from connected clients and device management integrations.
        </:description>
        <:action>
          <.docs_action path="/deploy/clients" />
        </:action>
        <:stats>
          <.async_result :let={count} assign={@clients_count}>
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
          id="clients"
          rows={@clients}
          row_id={&"client-#{&1.id}"}
          row_click={fn device -> ~p"/#{@account}/devices/#{device.id}?#{@query_params}" end}
          row_selected={
            fn device -> not is_nil(@selected_inventory) and device.id == @selected_inventory.id end
          }
          filters={@filters_by_table_id["clients"]}
          filter={@filter_form_by_table_id["clients"]}
          ordered_by={@order_by_table_id["clients"]}
          metadata={@clients_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={device} field={{:device_inventory, :name}} label="Device" class="w-72">
            <div class="flex items-center gap-2">
              <span class="mr-2">
                <.inventory_os_icon inventory={device} />
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
            <.actor_name_and_role
              :if={device.actor}
              account={@account}
              actor={device.actor}
              class="text-sm"
              return_to={@return_to}
            />
            <div :if={is_nil(device.actor)}>
              <p class="text-sm text-heading">
                {device.intune_user_display_name || device.intune_user_principal_name || "—"}
              </p>
              <p :if={device.intune_user_display_name && device.intune_user_principal_name} class="text-[10px] text-subtle">
                {device.intune_user_principal_name}
              </p>
            </div>
          </:col>
          <:col :let={device} label="Sources" class="w-32">
            <.inventory_source_badges inventory={device} />
          </:col>
          <:col
            :let={device}
            field={{:device_inventory, :intune_compliance_state}}
            label="Compliance"
            class="w-28"
          >
            <.inventory_compliance_badge inventory={device} />
            <span
              :if={device.connected && not is_nil(device.verified_at)}
              class="ml-1 inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-success bg-success-light"
            >
              <.icon name="ri-shield-check-line" class="w-2.5 h-2.5" /> Verified
            </span>
            <span
              :if={device.connected && is_nil(device.verified_at) && is_nil(device.intune_compliance_state)}
              class="ml-1 inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-muted bg-raised"
            >
              Unverified
            </span>
          </:col>
          <:col :let={device} label="Connection" class="w-28">
            <.inventory_connection_badge inventory={device} />
          </:col>
          <:col :let={device} label="Tunnel Addresses" class="hidden xl:table-cell w-48">
            <div :if={device.connected} class="space-y-0.5 font-mono text-[10px] text-body">
              <p>{device.ipv4}</p>
              <p class="truncate">{device.ipv6}</p>
            </div>
            <span :if={not device.connected} class="text-xs text-muted">Allocated on connect</span>
          </:col>
          <:col
            :let={device}
            field={{:device_inventory, :last_seen_at}}
            label="Last Activity"
            class="hidden lg:table-cell"
          >
            <span :if={inventory_last_activity(device)} class="text-xs text-subtle">
              <.relative_datetime datetime={inventory_last_activity(device)} />
            </span>
            <span :if={is_nil(inventory_last_activity(device))} class="text-xs text-muted">—</span>
          </:col>
          <:col
            :let={device}
            field={{:device_inventory, :inserted_at}}
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
                  Connect a device inventory integration or sign in from a Firezone client.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.client_panel
        account={@account}
        client={@selected_client}
        inventory={@selected_inventory}
        panel={client_panel_state(assigns)}
        confirm_state={client_confirm_state(assigns)}
        query_params={@query_params}
        policy_authorizations={@policy_authorizations}
        policy_authorizations_page={@policy_authorizations_page}
        policy_authorizations_has_next={@policy_authorizations_has_next}
        policy_authorizations_expanded_id={@policy_authorizations_expanded_id}
      />
      <.inventory_device_panel
        :if={@selected_inventory && is_nil(@selected_client)}
        account={@account}
        inventory={@selected_inventory}
      />
    </div>
    """
  end

  defp client_panel_state(assigns) do
    %{
      panel_view: assigns.client_panel.view,
      panel_tab: assigns.client_panel.tab,
      client_edit_form: assigns.client_panel.edit_form
    }
  end

  defp client_confirm_state(assigns) do
    %{
      confirm_delete_client: assigns.client_confirm.delete?,
      confirm_unverify_client: assigns.client_confirm.unverify?
    }
  end

  defp inventory_last_activity(%{last_seen_at: nil, intune_last_sync_at: intune_last_sync_at}),
    do: intune_last_sync_at

  defp inventory_last_activity(%{last_seen_at: last_seen_at, intune_last_sync_at: nil}),
    do: last_seen_at

  defp inventory_last_activity(%{last_seen_at: last_seen_at, intune_last_sync_at: intune_last_sync_at}) do
    if DateTime.compare(last_seen_at, intune_last_sync_at) == :lt,
      do: intune_last_sync_at,
      else: last_seen_at
  end

  defp base_client_assigns do
    [
      client_panel: %{
        view: :details,
        tab: :overview,
        edit_form: nil
      },
      client_confirm: %{
        delete?: false,
        unverify?: false
      }
    ]
  end

  defp show_client_assigns(tab) do
    assigns = base_client_assigns()
    Keyword.update!(assigns, :client_panel, &Map.put(&1, :tab, tab))
  end

  defp edit_client_assigns(form) do
    [
      client_panel: %{
        view: :edit_client,
        tab: :overview,
        edit_form: form
      },
      client_confirm: %{
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
        "switch_client_tab",
        %{"tab" => tab},
        %{assigns: %{selected_client: %Device{} = client}} = socket
      ) do
    params =
      socket.assigns.query_params
      |> Map.put("tab", tab)
      |> Map.delete("page")

    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{client}?#{params}"
     )}
  end

  def handle_event("switch_client_tab", _params, %{assigns: %{selected_client: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("change_policy_authorizations_page", %{"page" => page}, socket) do
    params = Map.put(socket.assigns.query_params, "page", page)

    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_inventory.id}?#{params}"
     )}
  end

  def handle_event("toggle_policy_authorization_row", %{"id" => id}, socket) do
    expanded =
      if socket.assigns.policy_authorizations_expanded_id == id, do: nil, else: id

    {:noreply, assign(socket, policy_authorizations_expanded_id: expanded)}
  end

  def handle_event("open_client_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_inventory.id}/edit"
     )}
  end

  def handle_event("cancel_client_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_inventory.id}"
     )}
  end

  def handle_event("change_client_edit_form", %{"device" => attrs}, socket) do
    changeset =
      Database.change_client(socket.assigns.selected_client, attrs)
      |> Map.put(:action, :validate)

    {:noreply, merge_state(socket, :client_panel, edit_form: to_form(changeset))}
  end

  def handle_event("submit_client_edit_form", %{"device" => attrs}, socket) do
    changeset = Database.change_client(socket.assigns.selected_client, attrs)

    case Database.update_client(changeset, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device updated successfully.")
         |> reload_live_table!("clients")
         |> push_patch(to: ~p"/#{socket.assigns.account}/devices/#{updated_client.id}")}

      {:error, changeset} ->
        {:noreply,
         merge_state(socket, :client_panel,
           edit_form: to_form(Map.put(changeset, :action, :validate))
         )}
    end
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.client_panel.view == :edit_client do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/devices/#{socket.assigns.selected_inventory.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_inventory) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/devices?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_delete_client", _params, socket) do
    {:noreply, merge_state(socket, :client_confirm, delete?: true)}
  end

  def handle_event("cancel_delete_client", _params, socket) do
    {:noreply, merge_state(socket, :client_confirm, delete?: false)}
  end

  def handle_event("verify_client", _params, socket) do
    client = socket.assigns.selected_client

    case Database.verify_client(client, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{client.name}\" was verified.")
         |> assign_updated_selected_client(updated_client)
         |> merge_state(:client_confirm, unverify?: false)
         |> reload_live_table!("clients")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to verify device.")}
    end
  end

  def handle_event("confirm_unverify_client", _params, socket) do
    {:noreply, merge_state(socket, :client_confirm, unverify?: true)}
  end

  def handle_event("cancel_unverify_client", _params, socket) do
    {:noreply, merge_state(socket, :client_confirm, unverify?: false)}
  end

  def handle_event("unverify_client", _params, socket) do
    client = socket.assigns.selected_client

    case Database.remove_client_verification(client, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{client.name}\" was unverified.")
         |> assign_updated_selected_client(updated_client)
         |> merge_state(:client_confirm, unverify?: false)
         |> reload_live_table!("clients")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to unverify device.")
         |> merge_state(:client_confirm, unverify?: false)}
    end
  end

  def handle_event("delete_client", _params, socket) do
    client = socket.assigns.selected_client

    case Database.delete_client(client, socket.assigns.subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Device \"#{client.name}\" was deleted.")
         |> merge_state(:client_confirm, delete?: false)
         |> reload_live_table!("clients")
         |> push_patch(to: ~p"/#{socket.assigns.account}/devices")}

      {:error, _} ->
        {:noreply, merge_state(socket, :client_confirm, delete?: false)}
    end
  end

  defp assign_updated_selected_client(socket, updated_client) do
    selected_client = %{
      socket.assigns.selected_client
      | verified_at: updated_client.verified_at,
        updated_at: updated_client.updated_at
    }

    assign(socket, :selected_client, selected_client)
  end

  defp parse_client_tab("authorizations"), do: :authorizations
  defp parse_client_tab("overview"), do: :overview
  defp parse_client_tab(_), do: :overview

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

  def handle_info(%Change{op: :insert, struct: %Device{type: :client}} = change, socket) do
    _ = change
    {:noreply, refresh_device_inventory(socket)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Device{type: :client}} = change, socket) do
    _ = change
    {:noreply, refresh_device_inventory(socket)}
  end

  def handle_info(%Change{struct: %Device{type: :client}} = change, socket) do
    _ = change
    {:noreply, refresh_device_inventory(socket)}
  end

  def handle_info(%Change{struct: %Device{type: :gateway}}, socket), do: {:noreply, socket}
  def handle_info(%Change{old_struct: %Device{type: :gateway}}, socket), do: {:noreply, socket}

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _account_id} = event,
        socket
      ) do
    rendered_client_ids = Enum.map(socket.assigns.clients, & &1.device_id) |> Enum.reject(&is_nil/1)

    if presence_updates_any_id?(event, rendered_client_ids) do
      socket = reload_live_table!(socket, "clients")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:device_inventory_changed, socket) do
    {:noreply, refresh_device_inventory(socket)}
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  defp refresh_device_inventory(socket) do
    subject = socket.assigns.subject

    socket
    |> assign(stale: false)
    |> assign_async(:clients_count, fn ->
      {:ok, %{clients_count: Database.count_clients(subject)}}
    end)
    |> reload_live_table!("clients")
  end

  defmodule Database do
    import Ecto.Changeset
    import Ecto.Query
    import Portal.Changeset
    import Portal.Repo.Query
    alias Portal.{Presence.Clients, Safe}
    alias Portal.{Device, DeviceInventory}
    alias Portal.Policy
    alias Portal.PolicyAuthorization
    alias Portal.Group
    alias Portal.Resource
    alias Portal.Repo.Filter
    alias Portal.Repo.OffsetPaginator

    def count_clients(subject) do
      from(d in DeviceInventory, as: :device_inventory)
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    def list_clients(subject, opts \\ []) do
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
           client_ids <- list_client_ids(filtered_query, paginator_opts, subject),
           {client_ids, metadata} <- OffsetPaginator.metadata(client_ids, paginator_opts) do
        clients = fetch_clients_page(client_ids, preload, subject)
        {:ok, clients, %{metadata | count: count}}
      else
        {:error, :unauthorized} = error -> error
        {:error, _reason} = error -> error
      end
    end

    defp page_query(_subject) do
      from(d in DeviceInventory, as: :device_inventory)
    end

    defp maybe_filter_by_presence(base_query, presence, subject) do
      case presence do
        "online" ->
          ids = Clients.online_client_ids(subject.account.id)
          where(base_query, [device_inventory: d], d.device_id in ^ids)

        "offline" ->
          ids = Clients.online_client_ids(subject.account.id)
          where(
            base_query,
            [device_inventory: d],
            d.connected == true and d.device_id not in ^ids
          )

        "not_connected" ->
          where(base_query, [device_inventory: d], d.connected == false)

        _ ->
          base_query
      end
    end

    defp list_client_ids(filtered_query, paginator_opts, subject) do
      filtered_query
      |> select([device_inventory: d], d.id)
      |> OffsetPaginator.query(paginator_opts)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp fetch_clients_page([], _preload, _subject), do: []

    defp fetch_clients_page(client_ids, preload, subject) do
      clients =
        page_query(subject)
        |> where([device_inventory: d], d.id in ^client_ids)
        |> Safe.scoped(subject)
        |> Safe.all()
        |> maybe_preload_clients(preload, subject)

      clients_by_id = Map.new(clients, &{&1.id, &1})

      client_ids
      |> Enum.map(&Map.get(clients_by_id, &1))
      |> Enum.reject(&is_nil/1)
    end

    defp maybe_preload_clients(clients, preload, _subject) do
      Enum.reduce(preload, clients, fn
        :actor, clients ->
          Safe.preload(clients, :actor)

        :online?, clients ->
          preload_inventory_presence(clients)

        _other, clients ->
          clients
      end)
    end

    def preload_inventory_presence(inventory) do
      account_id = inventory |> List.first() |> then(&(&1 && &1.account_id))
      online_ids = if account_id, do: Clients.online_client_ids(account_id), else: []
      Enum.map(inventory, &%{&1 | online?: &1.device_id in online_ids})
    end

    @spec change_client(Portal.Device.t(), map()) :: Ecto.Changeset.t()
    def change_client(client, attrs \\ %{}) do
      import Ecto.Changeset

      client
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> Portal.Device.changeset()
    end

    @spec update_client(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t()}
    def update_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec verify_client(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t()}
    def verify_client(client, subject) do
      client
      |> change()
      |> put_default_value(:verified_at, DateTime.utc_now())
      |> update_client(subject)
    end

    @spec remove_client_verification(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, Ecto.Changeset.t()}
    def remove_client_verification(client, subject) do
      client
      |> change()
      |> put_change(:verified_at, nil)
      |> update_client(subject)
    end

    @spec delete_client(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Device.t()} | {:error, term()}
    def delete_client(client, subject) do
      case Safe.scoped(client, subject) |> Safe.delete() do
        {:ok, deleted_client} ->
          {:ok, Clients.preload_clients_presence([deleted_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec get_inventory_for_panel(binary(), Portal.Authentication.Subject.t()) ::
            {Portal.DeviceInventory.t(), Portal.Device.t() | nil} | nil
    def get_inventory_for_panel(id, subject) do
      inventory =
        from(d in DeviceInventory, as: :device_inventory)
        |> where([device_inventory: d], d.id == ^id)
        |> preload([:actor])
        |> Safe.scoped(subject)
        |> Safe.one()
        |> case do
          %DeviceInventory{} = inventory ->
            preload_inventory_presence([inventory]) |> List.first()

          _ ->
            nil
        end

      case inventory do
        nil ->
          nil

        %DeviceInventory{device_id: nil} ->
          {inventory, nil}

        %DeviceInventory{device_id: device_id} ->
          client =
            from(c in Device, as: :devices)
            |> where([devices: d], d.type == :client and d.id == ^device_id)
            |> preload([:actor])
            |> Safe.scoped(subject)
            |> Safe.one()

          client =
            case client do
              %Device{} -> Clients.preload_clients_presence([client]) |> List.first()
              _ -> nil
            end

          {inventory, client}
      end
    end

    def cursor_fields do
      [
        {:device_inventory, :desc, :last_seen_at},
        {:device_inventory, :asc, :id}
      ]
    end

    def preloads do
      [
        :actor,
        online?: &preload_inventory_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "Device or Owner",
          type: {:string, :websearch},
          fun: &filter_by_search_fts/2
        },
        %Portal.Repo.Filter{
          name: :verification,
          title: "Verification Status",
          type: :string,
          values: [
            {"Verified", "verified"},
            {"Not Verified", "not_verified"}
          ],
          fun: &filter_by_verification/2
        },
        %Portal.Repo.Filter{
          name: :presence,
          title: "Presence",
          type: :string,
          values: [
            {"Online", "online"},
            {"Offline", "offline"},
            {"Not Connected", "not_connected"}
          ],
          fun: &filter_by_presence/2
        }
      ]
    end

    def filter_by_search_fts(queryable, search_term) do
      queryable =
        if has_named_binding?(queryable, :actors) do
          queryable
        else
          join(queryable, :left, [device_inventory: d], a in assoc(d, :actor),
            on: a.account_id == d.account_id,
            as: :actors
          )
        end

      {queryable,
       dynamic(
         [device_inventory: devices, actors: actors],
         fulltext_search(actors.name, ^search_term) or
           fulltext_search(devices.name, ^search_term) or
           fulltext_search(actors.email, ^search_term) or
           fulltext_search(devices.intune_serial_number, ^search_term) or
           fulltext_search(devices.intune_id, ^search_term) or
           fulltext_search(devices.intune_user_principal_name, ^search_term) or
           fulltext_search(devices.intune_operating_system, ^search_term)
       )}
    end

    def filter_by_verification(queryable, "verified") do
      {queryable,
       dynamic(
         [device_inventory: devices],
         not is_nil(devices.verified_at) or devices.intune_compliance_state == "compliant"
       )}
    end

    def filter_by_verification(queryable, "not_verified") do
      {queryable,
       dynamic(
         [device_inventory: devices],
         is_nil(devices.verified_at) and
           (is_nil(devices.intune_compliance_state) or
              devices.intune_compliance_state != "compliant")
       )}
    end

    def filter_by_presence(queryable, _presence) do
      # This is handled as a prefilter in list_clients
      # Return the queryable unchanged since actual filtering happens above
      {queryable, true}
    end

    @page_size 25

    @spec list_policy_authorizations_for_client(
            Portal.Device.t(),
            Portal.Authentication.Subject.t(),
            non_neg_integer()
          ) :: {[map()], boolean()}
    def list_policy_authorizations_for_client(client, subject, page \\ 1) do
      offset = (page - 1) * @page_size

      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where(
        [policy_authorizations: pa],
        pa.initiating_device_id == ^client.id or pa.receiving_device_id == ^client.id
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
  end
end
