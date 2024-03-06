defmodule Web.Clients.Index do
  use Web, :live_view
  alias Domain.Clients

  def mount(_params, _session, socket) do
    :ok = Clients.subscribe_to_clients_presence_in_account(socket.assigns.subject.account)

    sortable_fields = [
      {:clients, :name}
    ]

    {:ok, assign(socket, page_title: "Clients", sortable_fields: sortable_fields)}
  end

  def handle_params(params, uri, socket) do
    {socket, list_opts} =
      handle_rich_table_params(params, uri, socket, "clients", Clients.Client.Query,
        preload: :actor
      )

    with {:ok, clients, metadata} <- Clients.list_clients(socket.assigns.subject, list_opts) do
      socket =
        assign(socket,
          clients: clients,
          metadata: metadata
        )

      {:noreply, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
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
      <:content>
        <div class="bg-white overflow-hidden">
          <.rich_table
            id="clients"
            rows={@clients}
            row_id={&"client-#{&1.id}"}
            sortable_fields={@sortable_fields}
            filters={@filters}
            filter={@filter}
            metadata={@metadata}
          >
            <:col :let={client} label="NAME" field={{:clients, :name}} order_by={@order_by}>
              <.link navigate={~p"/#{@account}/clients/#{client.id}"} class={[link_style()]}>
                <%= client.name %>
              </.link>
            </:col>
            <:col :let={client} label="USER">
              <.link navigate={~p"/#{@account}/actors/#{client.actor.id}"} class={[link_style()]}>
                <%= client.actor.name %>
              </.link>
            </:col>
            <:col :let={client} label="STATUS">
              <.connection_status schema={client} />
            </:col>
            <:empty>
              <div class="text-center text-neutral-500 p-4">
                No clients to display. Clients are created automatically when a user connects to a resource.
              </div>
            </:empty>
          </.rich_table>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_rich_table_event(event, params, socket)

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _account_id},
        socket
      ) do
    {:ok, clients} = Clients.list_clients(socket.assigns.subject, preload: :actor)
    {:noreply, assign(socket, clients: clients)}
  end
end
