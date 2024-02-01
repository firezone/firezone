defmodule Web.Clients.Index do
  use Web, :live_view
  alias Domain.Clients

  def mount(_params, _session, socket) do
    with {:ok, clients} <- Clients.list_clients(socket.assigns.subject, preload: :actor) do
      :ok = Clients.subscribe_to_clients_presence_in_account(socket.assigns.subject.account)

      socket =
        assign(socket,
          clients: clients,
          page_title: "Clients"
        )

      {:ok, socket}
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
          <!--<.resource_filter />-->
          <.table id="clients" rows={@clients} row_id={&"client-#{&1.id}"}>
            <:col :let={client} label="NAME">
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
          </.table>
          <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/clients"} />-->
        </div>
      </:content>
    </.section>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _account_id},
        socket
      ) do
    {:ok, clients} = Clients.list_clients(socket.assigns.subject, preload: :actor)
    {:noreply, assign(socket, clients: clients)}
  end
end
