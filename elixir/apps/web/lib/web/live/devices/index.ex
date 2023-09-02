defmodule Web.Devices.Index do
  use Web, :live_view

  alias Domain.Devices

  def mount(_params, _session, socket) do
    with {:ok, devices} <- Devices.list_devices(socket.assigns.subject, preload: :actor) do
      {:ok, assign(socket, devices: devices)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/devices"}>Devices</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        All devices
      </:title>
    </.header>
    <!-- Devices Table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <div :if={Enum.empty?(@devices)} class="text-center align-middle pb-8 pt-4">
        <h3 class="mt-2 text-lg font-semibold text-gray-900">There are no devices to display.</h3>

        <div class="mt-6">
          Devices are created automatically when user connects to a Resource.
        </div>
      </div>
      <!--<.resource_filter />-->
      <.table :if={not Enum.empty?(@devices)} id="devices" rows={@devices} row_id={&"device-#{&1.id}"}>
        <:col :let={device} label="NAME" sortable="true">
          <.link
            navigate={~p"/#{@account}/devices/#{device.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= device.name %>
          </.link>
        </:col>
        <:col :let={device} label="USER" sortable="true">
          <.link
            navigate={~p"/#{@account}/actors/#{device.actor.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= device.actor.name %>
          </.link>
        </:col>
        <:col :let={device} label="STATUS" sortable="true">
          <.connection_status schema={device} />
        </:col>
      </.table>
      <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/devices"} />-->
    </div>
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
  #             <.icon name="hero-magnifying-glass" class="w-5 h-5 text-gray-500 dark:text-gray-400" />
  #           </div>
  #           <input
  #             type="text"
  #             id="simple-search"
  # class =
  #   {[
  #      "bg-gray-50 border border-gray-300 text-gray-900",
  #      "text-sm rounded-lg focus:ring-primary-500 focus:border-primary-500",
  #      "block w-full pl-10 p-2 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white",
  #      "dark:focus:ring-primary-500 dark:focus:border-primary-500"
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
