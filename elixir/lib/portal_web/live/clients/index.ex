defmodule PortalWeb.Clients.Index do
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
      |> assign_live_table("clients",
        query_module: Database,
        sortable_fields: [
          {:clients, :name},
          {:clients, :last_seen_version},
          {:clients, :last_seen_at},
          {:clients, :inserted_at},
          {:clients, :last_seen_user_agent}
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
            <.actor_name_and_role
              account={@account}
              actor={client.actor}
              return_to={@return_to}
            />
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

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Presence.Clients, Safe}
    alias Portal.Client

    def list_clients(subject, opts \\ []) do
      base_query = from(c in Client, as: :clients)

      # Check if we need to prefilter by presence
      base_query =
        case get_in(opts, [:filter, :presence]) do
          "online" ->
            ids = Clients.online_client_ids(subject.account.id)
            where(base_query, [clients: c], c.id in ^ids)

          "offline" ->
            ids = Clients.online_client_ids(subject.account.id)
            where(base_query, [clients: c], c.id not in ^ids)

          _ ->
            base_query
        end

      base_query
      |> Safe.scoped(subject, :replica)
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
          join(queryable, :inner, [clients: c], a in assoc(c, :actor), as: :actors)
        end

      {queryable,
       dynamic(
         [clients: clients, actors: actors],
         fulltext_search(clients.name, ^name_or_email) or
           fulltext_search(actors.name, ^name_or_email) or
           fulltext_search(actors.email, ^name_or_email)
       )}
    end

    def filter_by_verification(queryable, "verified") do
      {queryable, dynamic([clients: clients], not is_nil(clients.verified_at))}
    end

    def filter_by_verification(queryable, "not_verified") do
      {queryable, dynamic([clients: clients], is_nil(clients.verified_at))}
    end

    def filter_by_presence(queryable, _presence) do
      # This is handled as a prefilter in list_clients
      # Return the queryable unchanged since actual filtering happens above
      {queryable, true}
    end
  end
end
