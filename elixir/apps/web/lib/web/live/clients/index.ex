defmodule Web.Clients.Index do
  use Web, :live_view
  alias Domain.Clients

  def mount(_params, _session, socket) do
    with {:ok, clients} <- Clients.list_clients(socket.assigns.subject, preload: :actor) do
      {:ok, assign(socket, clients: clients)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  # subscribe for presence

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
              <.link
                navigate={~p"/#{@account}/clients/#{client.id}"}
                class={["font-medium", link_style()]}
              >
                <%= client.name %>
              </.link>
            </:col>
            <:col :let={client} label="USER">
              <.link
                navigate={~p"/#{@account}/actors/#{client.actor.id}"}
                class={["font-medium", link_style()]}
              >
                <%= client.actor.name %>
              </.link>
            </:col>
            <:col :let={client} label="STATUS">
              <.connection_status schema={client} />
            </:col>
            <:empty>
              <div class="text-center text-neutral-500 p-4">No clients to display</div>
              <div class="text-center text-neutral-500 mb-4">
                Clients are created automatically when user connects to a resource.
              </div>
            </:empty>
          </.table>
          <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/clients"} />-->
        </div>
      </:content>
    </.section>
    """
  end

  # defp resource_filter(assigns) do
  #   ~H"""
  #   <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
  #     <div class="w-full md:w-1/2">
  #       <form class="flex items-center">
  #         <label for="simple-search" class="sr-only">Search</label>
  #         <div class="relative w-full">
  #           <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
  #             <.icon name="hero-magnifying-glass" class="w-5 h-5 text-neutral-500" />
  #           </div>
  #           <input
  #             type="text"
  #             id="simple-search"
  # class =
  #   {[
  #      "bg-neutral-50 border border-neutral-300 text-neutral-900",
  #      "text-sm rounded-lg",
  #      "block w-full pl-10 p-2"
  #    ]}
  #             placeholder="Search"
  #             required=""
  #           />
  #         </div>
  #       </form>
  #     </div>
  #     <.button_group>
  #       <:first>
  #         All
  #       </:first>
  #       <:middle>
  #         Online
  #       </:middle>
  #       <:last>
  #         Archived
  #       </:last>
  #     </.button_group>
  #   </div>
  #   """
  # end
end
