defmodule PortalWeb.Clients do
  use PortalWeb, :live_view
  import PortalWeb.Clients.Components
  alias Portal.{Presence.Clients, ComponentVersions}
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Clients.Account.subscribe(socket.assigns.subject.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Clients")
      |> assign(selected_client: nil)
      |> assign(base_client_assigns())
      |> assign_live_table("clients",
        query_module: Database,
        sortable_fields: [
          {:devices, :name},
          {:latest_session, :version},
          {:latest_session, :inserted_at},
          {:devices, :inserted_at},
          {:latest_session, :user_agent}
        ],
        callback: &handle_clients_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    client = Database.get_client_for_panel(id, socket.assigns.subject)

    if client do
      {:noreply,
       socket
       |> assign(selected_client: client)
       |> assign(show_client_assigns())}
    else
      {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients")}
    end
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    client = Database.get_client_for_panel(id, socket.assigns.subject)

    if client do
      changeset = Database.change_client(client)

      {:noreply,
       socket
       |> assign(selected_client: client)
       |> assign(edit_client_assigns(to_form(changeset)))}
    else
      {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients")}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     socket
     |> assign(selected_client: nil)
     |> assign(base_client_assigns())}
  end

  def handle_clients_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :online?, :last_seen])

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
          <.icon name="ri-computer-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Clients</:title>
        <:description>
          End-user devices and servers that access your protected Resources.
        </:description>
        <:action>
          <.docs_action path="/deploy/clients" />
        </:action>
        <:filters>
          <% verified_count = Enum.count(@clients, &(not is_nil(&1.verified_at))) %>
          <% unverified_count = length(@clients) - verified_count %>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {@clients_metadata.count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--status-active)]"></span>
            Verified {verified_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--text-muted)]"></span>
            Unverified {unverified_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
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
                <div class="font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
                  {client.name}
                </div>
                <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">
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
          <:col :let={client} field={{:latest_session, :version}} label="Version" class="w-32">
            <.version
              current={client.latest_session && client.latest_session.version}
              latest={ComponentVersions.client_version(client)}
            />
          </:col>
          <:col :let={client} label="Verified" class="w-28">
            <span
              :if={not is_nil(client.verified_at)}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--status-active)] bg-[var(--status-active-bg)]"
              title="Device attributes of this client are manually verified"
            >
              <.icon name="ri-shield-check-line" class="w-2.5 h-2.5" /> Verified
            </span>
            <span
              :if={is_nil(client.verified_at)}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--text-muted)] bg-[var(--surface-raised)]"
            >
              Unverified
            </span>
          </:col>
          <:col :let={client} label="Status" class="w-28">
            <.status_badge status={if client.online?, do: :online, else: :offline} />
          </:col>
          <:col
            :let={client}
            field={{:latest_session, :inserted_at}}
            label="Last Started"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-[var(--text-tertiary)]">
              <.relative_datetime datetime={
                client.latest_session && client.latest_session.inserted_at
              } />
            </span>
          </:col>
          <:col
            :let={client}
            field={{:devices, :inserted_at}}
            label="Created"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-[var(--text-tertiary)]">
              <.relative_datetime datetime={client.inserted_at} />
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-computer-line" class="w-5 h-5 text-[var(--text-tertiary)]" />
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No clients yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
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
      />
    </div>
    """
  end

  defp client_panel_state(assigns) do
    %{
      panel_view: assigns.client_panel.view,
      client_edit_form: assigns.client_panel.edit_form
    }
  end

  defp client_confirm_state(assigns) do
    %{
      confirm_delete_client: assigns.client_confirm.delete?
    }
  end

  defp base_client_assigns do
    [
      client_panel: %{
        view: :details,
        edit_form: nil
      },
      client_confirm: %{
        delete?: false
      }
    ]
  end

  defp show_client_assigns, do: base_client_assigns()

  defp edit_client_assigns(form) do
    [
      client_panel: %{
        view: :edit_client,
        edit_form: form
      },
      client_confirm: %{
        delete?: false
      }
    ]
  end

  defp merge_state(socket, key, attrs) do
    update(socket, key, &Map.merge(&1, Map.new(attrs)))
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "table_row_click", "change_limit"],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients?#{params}")}
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

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Presence.Clients, ClientSession, Safe}
    alias Portal.Device
    alias Portal.Repo.Filter
    alias Portal.Repo.OffsetPaginator

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
             Safe.aggregate(Safe.scoped(filtered_query, subject, :replica), :count),
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
      |> join(
        :left_lateral,
        [devices: d],
        s in subquery(
          from(s in ClientSession,
            where: s.device_id == parent_as(:devices).id,
            where: s.account_id == parent_as(:devices).account_id,
            order_by: [desc: s.inserted_at],
            limit: 1
          )
        ),
        on: true,
        as: :latest_session
      )
      |> where([devices: d], d.type == :client)
    end

    defp hydrated_query(subject) do
      subject
      |> page_query()
      |> select_merge([latest_session: s], %{
        latest_session_inserted_at: s.inserted_at,
        latest_session_version: s.version,
        latest_session_user_agent: s.user_agent
      })
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
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    defp fetch_clients_page([], _preload, _subject), do: []

    defp fetch_clients_page(client_ids, preload, subject) do
      clients =
        hydrated_query(subject)
        |> where([devices: d], d.id in ^client_ids)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> maybe_preload_clients(preload, subject)

      clients_by_id = Map.new(clients, &{&1.id, &1})

      Enum.map(client_ids, fn client_id ->
        Map.fetch!(clients_by_id, client_id)
      end)
    end

    defp maybe_preload_clients(clients, preload, _subject) do
      Enum.reduce(preload, clients, fn
        :actor, clients ->
          Safe.preload(clients, :actor, :replica)

        :online?, clients ->
          Clients.preload_clients_presence(clients)

        :last_seen, clients ->
          preload_latest_sessions(clients)

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
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case client do
        %Device{type: :client} ->
          session =
            from(s in ClientSession,
              where: s.device_id == ^client.id,
              order_by: [desc: s.inserted_at],
              limit: 1
            )
            |> Safe.scoped(subject, :replica)
            |> Safe.one(fallback_to_primary: true)

          client = Clients.preload_clients_presence([client]) |> List.first()
          %{client | latest_session: session}

        _ ->
          nil
      end
    end

    def cursor_fields do
      [
        {:latest_session, :desc, :inserted_at},
        {:devices, :asc, :id}
      ]
    end

    def preloads do
      [
        :actor,
        online?: &Clients.preload_clients_presence/1,
        last_seen: &preload_latest_sessions/1
      ]
    end

    # The latest session fields are already loaded by the lateral join in list_clients/2.
    # We build the struct from those virtual fields to avoid a redundant DB round-trip.
    defp preload_latest_sessions(clients) do
      Enum.map(clients, fn client ->
        if client.latest_session_inserted_at do
          %{
            client
            | latest_session: %ClientSession{
                version: client.latest_session_version,
                inserted_at: client.latest_session_inserted_at,
                user_agent: client.latest_session_user_agent
              }
          }
        else
          client
        end
      end)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Client or Actor",
          type: {:string, :websearch},
          fun: &filter_by_name_or_email_fts/2
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

    def filter_by_name_or_email_fts(queryable, name_or_email) do
      queryable =
        if has_named_binding?(queryable, :actors) do
          queryable
        else
          join(queryable, :inner, [devices: d], a in assoc(d, :actor), as: :actors)
        end

      {queryable,
       dynamic(
         [devices: devices, actors: actors],
         fulltext_search(actors.name, ^name_or_email) or
           fulltext_search(devices.name, ^name_or_email) or
           fulltext_search(devices.email, ^name_or_email)
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
  end
end
