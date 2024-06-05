defmodule Web.Clients.Index do
  use Web, :live_view
  alias Domain.Clients

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Clients.subscribe_to_clients_presence_in_account(socket.assigns.subject.account)
    end

    socket =
      socket
      |> assign(page_title: "Clients")
      |> assign_live_table("clients",
        query_module: Clients.Client.Query,
        sortable_fields: [
          {:clients, :name}
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

    with {:ok, clients, metadata} <- Clients.list_clients(socket.assigns.subject, list_opts) do
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
      <:content>
        <.flash_group flash={@flash} />
        <.live_table
          id="clients"
          rows={@clients}
          row_id={&"client-#{&1.id}"}
          filters={@filters_by_table_id["clients"]}
          filter={@filter_form_by_table_id["clients"]}
          ordered_by={@order_by_table_id["clients"]}
          metadata={@clients_metadata}
        >
          <:col :let={client} field={{:clients, :name}} label="name">
            <.link navigate={~p"/#{@account}/clients/#{client.id}"} class={[link_style()]}>
              <%= client.name %>
            </.link>
          </:col>
          <:col :let={client} label="user">
            <.link navigate={~p"/#{@account}/actors/#{client.actor.id}"} class={[link_style()]}>
              <%= client.actor.name %>
            </.link>
          </:col>
          <:col :let={client} label="status">
            <.connection_status schema={client} />
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">
              No clients to display. Clients are created automatically when a user connects to a resource.
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
end
