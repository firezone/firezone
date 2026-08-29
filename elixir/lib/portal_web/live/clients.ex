defmodule PortalWeb.Clients do
  use PortalWeb, :live_view
  import PortalWeb.Clients.Components
  alias Portal.{Presence.Clients, ComponentVersions}
  alias Portal.Changes.Change
  alias Portal.Device
  alias Portal.PubSub
  alias Phoenix.LiveView.AsyncResult
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    if connected?(socket) do
      :ok = Clients.Account.subscribe(subject.account.id)
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id, :devices)
    end

    socket =
      socket
      |> assign(page_title: "Clients")
      |> assign(selected_client: nil)
      |> assign(stale: false)
      |> assign_async(:clients_count, fn -> {:ok, %{clients_count: Database.count_clients(subject)}} end)
      |> assign(
        client_device_pools: [],
        policy_authorizations: [],
        policy_authorizations_page: 1,
        policy_authorizations_has_next: false,
        policy_authorizations_expanded_id: nil,
        client_posture: [],
        client_certificate: nil,
        posture_types_by_client: %{}
      )
      |> assign(base_client_assigns())
      |> assign_live_table("clients",
        query_module: Database,
        sortable_fields: [
          {:devices, :name},
          {:devices, :last_seen_version},
          {:devices, :last_seen_at},
          {:devices, :inserted_at},
          {:devices, :last_seen_user_agent}
        ],
        callback: &handle_clients_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_client_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_clients_index(socket, "Client does not exist.")

      client ->
        page = parse_page(params)
        tab = parse_client_tab(Map.get(params, "tab", "overview"))

        {policy_authorizations, has_next} =
          Database.list_policy_authorizations_for_client(client, socket.assigns.subject, page)

        {:noreply,
         socket
         |> assign(selected_client: client)
         |> assign(show_client_assigns(tab))
         |> assign(
           client_device_pools: Database.list_device_pools_for_client(client, socket.assigns.subject),
           policy_authorizations: policy_authorizations,
           policy_authorizations_page: page,
           policy_authorizations_has_next: has_next,
           policy_authorizations_expanded_id: nil,
           client_posture: Database.list_posture_for_client(client, socket.assigns.subject),
           client_certificate: Database.certificate_status(client, socket.assigns.subject)
         )}
    end
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_client_for_panel(id, socket.assigns.subject) do
      nil ->
        redirect_to_clients_index(socket, "Client does not exist.")

      client ->
        changeset = Database.change_client(client)

        {:noreply,
         socket
         |> assign(selected_client: client)
         |> assign(edit_client_assigns(to_form(changeset)))}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(
       selected_client: nil,
       client_device_pools: [],
       client_posture: [],
       client_certificate: nil
     )
     |> assign(base_client_assigns())}
  end

  def handle_clients_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :online?])

    with {:ok, clients, metadata} <- Database.list_clients(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         clients: clients,
         clients_metadata: metadata,
         posture_types_by_client: Database.posture_types_by_client(clients, socket.assigns.subject)
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
        <:title>Clients</:title>
        <:description>
          End-user devices and servers that access your protected Resources.
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
          row_click={fn client -> ~p"/#{@account}/clients/#{client.id}?#{@query_params}" end}
          row_selected={
            fn client -> not is_nil(@selected_client) and client.id == @selected_client.id end
          }
          filters={@filters_by_table_id["clients"]}
          filter={@filter_form_by_table_id["clients"]}
          ordered_by={@order_by_table_id["clients"]}
          metadata={@clients_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={client} field={{:devices, :name}} label="Client" class="w-80">
            <div class="flex items-center gap-2">
              <span class="mr-2">
                <.client_os_icon client={client} />
              </span>
              <div>
                <div class="font-medium text-heading group-hover:text-brand transition-colors">
                  {client.name}
                </div>
                <div class="font-mono text-[10px] text-subtle mt-0.5">
                  {client.id}
                </div>
              </div>
            </div>
          </:col>
          <:col :let={client} label="Owner">
            <.actor_name_and_role
              account={@account}
              actor={client.actor}
              class="text-sm"
              return_to={@return_to}
            />
          </:col>
          <:col :let={client} field={{:devices, :last_seen_version}} label="Version" class="w-32">
            <.version
              current={client.last_seen_version}
              latest={ComponentVersions.client_version(client)}
            />
          </:col>
          <:col :let={client} label="Trust" class="w-28">
            <.client_verified_status client={client} />
          </:col>
          <:col :let={client} label="Posture" class="w-28">
            <.client_posture_icons types={Map.get(@posture_types_by_client, client.id, [])} />
          </:col>
          <:col :let={client} label="Status" class="w-28">
            <.client_status_badge online?={client.online?} />
          </:col>
          <:col
            :let={client}
            field={{:devices, :last_seen_at}}
            label="Last Started"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-subtle">
              <.relative_datetime datetime={client.last_seen_at} />
            </span>
          </:col>
          <:col
            :let={client}
            field={{:devices, :inserted_at}}
            label="Created"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-subtle">
              <.relative_datetime datetime={client.inserted_at} />
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-border bg-raised flex items-center justify-center">
                <.icon name="ri-computer-line" class="w-5 h-5 text-subtle" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-heading">No clients yet</p>
                <p class="text-xs text-subtle mt-0.5">
                  No clients have connected yet.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.client_panel
        account={@account}
        client={@selected_client}
        panel={client_panel_state(assigns)}
        confirm_state={client_confirm_state(assigns)}
        query_params={@query_params}
        device_pools={@client_device_pools}
        posture={@client_posture}
        certificate={@client_certificate}
        policy_authorizations={@policy_authorizations}
        policy_authorizations_page={@policy_authorizations_page}
        policy_authorizations_has_next={@policy_authorizations_has_next}
        policy_authorizations_expanded_id={@policy_authorizations_expanded_id}
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
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients?#{params}")}
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
       to: ~p"/#{socket.assigns.account}/clients/#{client}?#{params}"
     )}
  end

  def handle_event("switch_client_tab", _params, %{assigns: %{selected_client: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("change_policy_authorizations_page", %{"page" => page}, socket) do
    params = Map.put(socket.assigns.query_params, "page", page)

    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}?#{params}"
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
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}/edit"
     )}
  end

  def handle_event("cancel_client_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}"
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
         |> put_flash(:success, "Client updated successfully.")
         |> reload_live_table!("clients")
         |> push_patch(to: ~p"/#{socket.assigns.account}/clients/#{updated_client.id}")}

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
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_client) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients?#{params}")}
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
         |> put_flash(:success, "Client \"#{client.name}\" was verified.")
         |> assign_updated_selected_client(updated_client)
         |> merge_state(:client_confirm, unverify?: false)
         |> reload_live_table!("clients")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to verify client.")}
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
         |> put_flash(:success, "Client \"#{client.name}\" was unverified.")
         |> assign_updated_selected_client(updated_client)
         |> merge_state(:client_confirm, unverify?: false)
         |> reload_live_table!("clients")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to unverify client.")
         |> merge_state(:client_confirm, unverify?: false)}
    end
  end

  def handle_event("delete_client", _params, socket) do
    client = socket.assigns.selected_client

    case Database.delete_client(client, socket.assigns.subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Client \"#{client.name}\" was deleted.")
         |> merge_state(:client_confirm, delete?: false)
         |> reload_live_table!("clients")
         |> push_patch(to: ~p"/#{socket.assigns.account}/clients")}

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
  defp parse_client_tab("posture"), do: :posture
  defp parse_client_tab("overview"), do: :overview
  defp parse_client_tab(_), do: :overview

  defp parse_page(params) do
    case Integer.parse(Map.get(params, "page", "1")) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp redirect_to_clients_index(socket, message) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> push_patch(to: ~p"/#{socket.assigns.account}/clients?#{socket.assigns.query_params}")}
  end

  def handle_info(%Change{op: :insert, struct: %Device{type: :client}} = change, socket) do
    {:noreply,
     socket
     |> update(:clients_count, fn
       %AsyncResult{ok?: true} = ar -> AsyncResult.ok(ar, ar.result + 1)
       ar -> ar
     end)
     |> mark_stale_if_unreflected(change)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Device{type: :client}} = change, socket) do
    {:noreply,
     socket
     |> update(:clients_count, fn
       %AsyncResult{ok?: true} = ar -> AsyncResult.ok(ar, max(ar.result - 1, 0))
       ar -> ar
     end)
     |> mark_stale_if_unreflected(change)}
  end

  def handle_info(%Change{struct: %Device{type: :client}} = change, socket) do
    {:noreply, mark_stale_if_unreflected(socket, change)}
  end

  def handle_info(%Change{struct: %Device{type: :gateway}}, socket), do: {:noreply, socket}
  def handle_info(%Change{old_struct: %Device{type: :gateway}}, socket), do: {:noreply, socket}

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _account_id} = event,
        socket
      ) do
    rendered_client_ids = Enum.map(socket.assigns.clients, & &1.id)

    if presence_updates_any_id?(event, rendered_client_ids) do
      socket = reload_live_table!(socket, "clients")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  defp mark_stale_if_unreflected(socket, change) do
    if PortalWeb.LiveTable.view_reflects_change?(socket.assigns.clients, change) do
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
    alias Portal.{Presence.Clients, Safe}
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

    def count_clients(subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
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
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
    end

    defp maybe_filter_by_presence(base_query, presence, subject) do
      case presence do
        "online" ->
          ids = Clients.online_client_ids(subject.account.id)
          where(base_query, [devices: d], d.id in ^ids)

        "offline" ->
          ids = Clients.online_client_ids(subject.account.id)
          where(base_query, [devices: d], d.id not in ^ids)

        _ ->
          base_query
      end
    end

    defp list_client_ids(filtered_query, paginator_opts, subject) do
      filtered_query
      |> select([devices: d], d.id)
      |> OffsetPaginator.query(paginator_opts)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp fetch_clients_page([], _preload, _subject), do: []

    defp fetch_clients_page(client_ids, preload, subject) do
      clients =
        page_query(subject)
        |> where([devices: d], d.id in ^client_ids)
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
          Clients.preload_clients_presence(clients)

        _other, clients ->
          clients
      end)
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

    @spec get_client_for_panel(binary(), Portal.Authentication.Subject.t()) ::
            Portal.Device.t() | nil
    def get_client_for_panel(id, subject) do
      client =
        from(c in Device, as: :devices)
        |> where([devices: d], d.type == :client)
        |> where([devices: d], d.id == ^id)
        |> preload([:actor])
        |> Safe.scoped(subject)
        |> Safe.one()

      case client do
        %Device{type: :client} ->
          Clients.preload_clients_presence([client]) |> List.first()

        _ ->
          nil
      end
    end

    @spec list_device_pools_for_client(Portal.Device.t(), Portal.Authentication.Subject.t()) ::
            [Resource.t()]
    def list_device_pools_for_client(%Device{} = client, subject) do
      from(r in Resource, as: :resources)
      |> join(:inner, [resources: r], m in StaticDevicePoolMember,
        on: m.resource_id == r.id and m.account_id == r.account_id,
        as: :members
      )
      |> where([members: m], m.device_id == ^client.id)
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
        online?: &Clients.preload_clients_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :search,
          title: "Client or Actor",
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
            {"Offline", "offline"}
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
          join(queryable, :inner, [devices: d], a in assoc(d, :actor),
            on: a.account_id == d.account_id,
            as: :actors
          )
        end

      {queryable,
       dynamic(
         [devices: devices, actors: actors],
         fulltext_search(actors.name, ^search_term) or
           fulltext_search(devices.name, ^search_term) or
           fulltext_search(actors.email, ^search_term)
       )}
    end

    def filter_by_verification(queryable, "verified") do
      {queryable, dynamic([devices: devices], not is_nil(devices.verified_at))}
    end

    def filter_by_verification(queryable, "not_verified") do
      {queryable, dynamic([devices: devices], is_nil(devices.verified_at))}
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
    @doc """
    Records from the account's posture providers that describe this device.

    A row is matched on the strongest identifier it shares with the Client:

      1. the MDM device id the Client's certificate attested,
      2. the hardware serial that certificate attested,
      3. the hardware serial the Client reports about itself.

    Only the first two prove anything. The third is whatever the Client said
    about itself, so the panel cautions about rows matched that way.

    One row per configured provider rather than per provider type, so an
    account running two Intune tenants sees the device in both.
    """
    @spec list_posture_for_client(Device.t(), Portal.Authentication.Subject.t()) :: [
            %{
              type: atom(),
              provider: PostureProvider.t(),
              device: struct(),
              matched_on: :mdm_device_id | :attested_serial | :device_serial
            }
          ]
    def list_posture_for_client(%Device{type: :client} = device, subject) do
      keys = match_keys(device)
      providers = list_posture_providers(subject)

      if keys == [] or providers == [] do
        []
      else
        providers
        |> Enum.map(& &1.type)
        |> Enum.uniq()
        |> Enum.flat_map(&match_posture(&1, keys, subject))
        |> Enum.flat_map(&posture_entry(&1, Map.new(providers, fn p -> {p.id, p} end)))
        |> Enum.group_by(& &1.provider.id)
        |> Enum.map(fn {_provider_id, entries} -> best_posture_entry(entries) end)
        |> Enum.sort_by(&{provider_type_rank(&1.type), String.downcase(&1.provider.name)})
      end
    end

    def list_posture_for_client(_client, _subject), do: []

    defp posture_entry({type, device, matched_on}, providers_by_id) do
      case Map.fetch(providers_by_id, device.posture_provider_id) do
        {:ok, provider} -> [%{type: type, provider: provider, device: device, matched_on: matched_on}]
        :error -> []
      end
    end

    defp best_posture_entry(entries), do: Enum.min_by(entries, &rung_rank(&1.matched_on))

    @doc """
    Which posture providers hold a record for each device in a list.

    One query per configured provider type for the whole page, so the Clients
    list can badge every row without a lookup per Client.
    """
    @spec posture_types_by_client([Device.t()], Portal.Authentication.Subject.t()) ::
            %{Ecto.UUID.t() => [atom()]}
    def posture_types_by_client(devices, subject) do
      keys_by_client =
        for device <- devices, keys = match_keys(device), keys != [], do: {device.id, keys}

      types = subject |> list_posture_providers() |> Enum.map(& &1.type) |> Enum.uniq()

      if keys_by_client == [] or types == [] do
        %{}
      else
        Enum.reduce(types, %{}, &credit_posture_type(&1, &2, keys_by_client, subject))
      end
    end

    defp credit_posture_type(type, acc, keys_by_client, subject) do
      known = known_posture_values(type, keys_by_client, subject)

      for {client_id, keys} <- keys_by_client,
          posture_known?(type, keys, known),
          reduce: acc do
        acc -> Map.update(acc, client_id, [type], &(&1 ++ [type]))
      end
    end

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

    def certificate_status(_client, _subject), do: nil

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
              Enum.map(rows, &{type, &1, matched_rung(type, keys, &1)})

            _refused ->
              []
          end
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

    defp known_posture_values(type, keys_by_client, subject) do
      fields = type |> posture_match_fields() |> Enum.uniq()

      values =
        keys_by_client
        |> Enum.flat_map(fn {_client_id, keys} -> Keyword.values(keys) end)
        |> Enum.uniq()

      conditions = for field_name <- fields, do: dynamic([d], field(d, ^field_name) in ^values)

      case conditions do
        [] ->
          MapSet.new()

        conditions ->
          from(d in posture_schema(type),
            where: ^Enum.reduce(conditions, &dynamic(^&1 or ^&2)),
            select: map(d, ^fields)
          )
          |> Safe.scoped(subject)
          |> Safe.all()
          |> index_posture_values()
      end
    end

    defp index_posture_values(rows) when is_list(rows) do
      for row <- rows, {field_name, value} <- row, not is_nil(value), into: MapSet.new() do
        {field_name, value}
      end
    end

    # A refused read leaves the list with no badges rather than with wrong ones.
    defp index_posture_values(_refused), do: MapSet.new()

    defp posture_known?(type, keys, known) do
      Enum.any?(keys, fn {rung, value} ->
        Enum.any?(rung_fields(type, rung), &MapSet.member?(known, {&1, value}))
      end)
    end

    defp posture_match_fields(type) do
      Enum.flat_map([:mdm_device_id, :attested_serial, :device_serial], &rung_fields(type, &1))
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
    # Intune and Defender both carry the Entra device id, which is the value a
    # certificate issued through Entra attests. Defender's machine entity
    # reports no hardware serial at all, and neither of the two EDRs carries an
    # MDM device id, so each of those has one rung it cannot answer.
    defp rung_fields(:intune, :mdm_device_id), do: [:intune_id, :entra_device_id]
    defp rung_fields(:intune, _serial_rung), do: [:serial_number]
    defp rung_fields(:iru, :mdm_device_id), do: [:iru_id]
    defp rung_fields(:iru, _serial_rung), do: [:serial_number]
    defp rung_fields(:defender, :mdm_device_id), do: [:defender_id, :entra_device_id]
    defp rung_fields(:defender, _serial_rung), do: []
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
