defmodule Web.GatewayGroups.Index do
  use Web, :live_view
  alias Domain.Gateways

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    with {:ok, groups} <-
           Gateways.list_groups(subject, preload: [:gateways, connections: [:resource]]) do
      :ok = Gateways.subscribe_for_gateways_presence_in_account(socket.assigns.account)
      {:ok, assign(socket, groups: groups)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/gateway_groups"}>Gateway Instance Groups</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Gateways
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/gateway_groups/new"}>
          Add Instance Group
        </.add_button>
      </:action>
      <:content>
        <div class="bg-white dark:bg-gray-800 overflow-hidden">
          <!--<.resource_filter />-->
          <.table_with_groups
            id="groups"
            groups={@groups}
            group_items={& &1.gateways}
            group_id={&"group-#{&1.id}"}
            row_id={&"gateway-#{&1.id}"}
          >
            <:group :let={group}>
              <.link
                navigate={~p"/#{@account}/gateway_groups/#{group.id}"}
                class="font-bold text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= group.name_prefix %>
              </.link>
              <%= if not Enum.empty?(group.tags), do: "(" <> Enum.join(group.tags, ", ") <> ")" %>

              <div class="font-light flex">
                <span class="pr-1 inline-block">Resources:</span>
                <.intersperse_blocks>
                  <:separator><span class="pr-1">,</span></:separator>

                  <:item :for={connection <- group.connections}>
                    <.link
                      navigate={~p"/#{@account}/resources/#{connection.resource}"}
                      class="font-medium text-blue-600 dark:text-blue-500 hover:underline inline-block"
                      phx-no-format
                    ><%= connection.resource.name %></.link>
                  </:item>
                </.intersperse_blocks>
              </div>
            </:group>

            <:col :let={gateway} label="INSTANCE">
              <.link
                navigate={~p"/#{@account}/gateways/#{gateway.id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= gateway.name_suffix %>
              </.link>
            </:col>
            <:col :let={gateway} label="REMOTE IP">
              <code class="block text-xs">
                <%= gateway.last_seen_remote_ip %>
              </code>
            </:col>

            <:col :let={gateway} label="STATUS">
              <.connection_status schema={gateway} />
            </:col>
          </.table_with_groups>
          <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/gateway_groups"} />-->
        </div>
      </:content>
    </.section>
    """
  end

  def resource_filter(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 p-4">
      <div class="w-full md:w-1/2">
        <form class="flex items-center">
          <label for="simple-search" class="sr-only">Search</label>
          <div class="relative w-full">
            <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
            </div>
            <input
              type="text"
              id="simple-search"
              class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-500 focus:border-primary-500 block w-full pl-10 p-2 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
              placeholder="Search"
              required=""
            />
          </div>
        </form>
      </div>
      <.button_group>
        <:first>
          All
        </:first>
        <:middle>
          Online
        </:middle>
        <:last>
          Deleted
        </:last>
      </.button_group>
    </div>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateways:" <> _account_id}, socket) do
    subject = socket.assigns.subject
    {:ok, groups} = Gateways.list_groups(subject, preload: [:gateways, connections: [:resource]])
    {:noreply, assign(socket, groups: groups)}
  end
end
