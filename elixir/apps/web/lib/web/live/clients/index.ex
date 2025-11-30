defmodule Web.Clients.Index do
  use Web, :live_view
  import Web.Clients.Components
  alias Domain.{Presence.Clients, ComponentVersions}
  alias __MODULE__.DB

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Clients.Account.subscribe(socket.assigns.subject.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Clients")
      |> assign_live_table("clients",
        query_module: DB,
        sortable_fields: [
          {:clients, :name},
          {:clients, :last_seen_version},
          {:clients, :last_seen_at},
          {:clients, :inserted_at},
          {:clients, :last_seen_user_agent}
        ],
        hide_filters: [
          :name
        ],
        callback: &handle_clients_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_clients_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :online?])

    with {:ok, clients, metadata} <- DB.list_clients(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         clients: clients,
         clients_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Clients
      </:title>
      <:help>
        Clients are end-user devices and servers that access your protected Resources.
      </:help>
      <:action>
        <.docs_action path="/deploy/clients" />
      </:action>
      <:content>
        <.live_table
          id="clients"
          rows={@clients}
          row_id={&"client-#{&1.id}"}
          filters={@filters_by_table_id["clients"]}
          filter={@filter_form_by_table_id["clients"]}
          ordered_by={@order_by_table_id["clients"]}
          metadata={@clients_metadata}
        >
          <:col :let={client} class="w-8">
            <.popover placement="right">
              <:target>
                <.client_os_icon client={client} />
              </:target>
              <:content>
                <.client_os_name_and_version client={client} />
              </:content>
            </.popover>
          </:col>
          <:col :let={client} field={{:clients, :name}} label="name">
            <div class="flex items-center space-x-1">
              <.link navigate={~p"/#{@account}/clients/#{client.id}"} class={[link_style()]}>
                {client.name}
              </.link>
              <.icon
                :if={not is_nil(client.verified_at)}
                name="hero-shield-check"
                class="w-4 h-4"
                title="Device attributes of this client are manually verified"
              />
            </div>
          </:col>
          <:col :let={client} label="user">
            <.actor_name_and_role account={@account} actor={client.actor} return_to={@current_path} />
          </:col>
          <:col :let={client} field={{:clients, :last_seen_version}} label="version">
            <.version
              current={client.last_seen_version}
              latest={ComponentVersions.client_version(client)}
            />
          </:col>
          <:col :let={client} label="status">
            <.connection_status schema={client} />
          </:col>
          <:col :let={client} field={{:clients, :last_seen_at}} label="last started">
            <.relative_datetime datetime={client.last_seen_at} />
          </:col>
          <:col :let={client} field={{:clients, :inserted_at}} label="created">
            <.relative_datetime datetime={client.inserted_at} />
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">
              No Actors have signed in from any Client.
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

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

  defmodule DB do
    import Ecto.Query
    import Domain.Repo.Query
    alias Domain.{Presence.Clients, Safe}
    alias Domain.Client

    def list_clients(subject, opts \\ []) do
      from(c in Client, as: :clients)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:clients, :desc, :last_seen_at},
        {:clients, :asc, :id}
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
        %Domain.Repo.Filter{
          name: :name,
          title: "Name",
          type: {:string, :websearch},
          fun: &filter_by_name_fts/2
        },
        %Domain.Repo.Filter{
          name: :actor_id,
          title: "Actor",
          type: {:string, :uuid},
          fun: &filter_by_actor_id/2
        },
        %Domain.Repo.Filter{
          name: :last_seen,
          title: "Last Seen",
          type: {:string, :datetime},
          fun: &filter_by_last_seen/2
        },
        %Domain.Repo.Filter{
          name: :actor_type,
          title: "Actor Type",
          type: :string,
          values: [
            {"Users", :account_user},
            {"Admins", :account_admin_user},
            {"Service Accounts", :service_account}
          ],
          fun: &filter_by_actor_type/2
        }
      ]
    end

    def filter_by_name_fts(queryable, name) do
      {queryable, dynamic([clients: c], fulltext_search(c.name, ^name))}
    end

    def filter_by_actor_id(queryable, actor_id) do
      {queryable, dynamic([clients: c], c.actor_id == ^actor_id)}
    end

    def filter_by_last_seen(queryable, last_seen) do
      {queryable, dynamic([clients: c], c.last_seen_at > ^last_seen)}
    end

    def filter_by_actor_type(queryable, actor_type) do
      queryable = with_joined_actor(queryable)
      {queryable, dynamic([actor: a], a.type == ^actor_type)}
    end

    defp with_joined_actor(queryable) do
      ensure_named_binding(queryable, :actor, fn queryable, binding ->
        join(queryable, :inner, [clients: c], a in assoc(c, ^binding), as: ^binding)
      end)
    end

    defp ensure_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end
  end
end
