defmodule Web.Resources.New do
  use Web, :live_view

  alias Domain.Gateways

  def mount(_params, _session, socket) do
    {:ok, gateway_groups} = Gateways.list_groups(socket.assigns.subject)

    {:ok, assign(socket, gateway_groups: gateway_groups)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/new"}>Add Resource</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Add Resource
      </:title>
    </.header>
    <!-- Add Resource -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Resource details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="name">
                Name
              </.label>
              <.input
                type="text"
                name="name"
                id="resource-name"
                placeholder="Name this Resource"
                value=""
                required
              />
            </div>
            <div>
              <.label for="address">
                Address
              </.label>
              <.input
                autocomplete="off"
                type="text"
                name="address"
                id="resource-address"
                placeholder="Enter IP address, CIDR, or DNS name"
                value=""
                required
              />
            </div>
            <hr />
            <div class="w-full">
              <h3>
                Traffic Restriction
              </h3>
              <div class="h-12 flex items-center mb-4">
                <.checkbox id="filter-all" name="traffic-filter" value="none" checked={true} />
                <.label for="filter-all" class="ml-4 mt-2">
                  Permit all
                </.label>
              </div>
              <div class="h-12 flex items-center mb-4">
                <.checkbox id="filter-icmp" name="traffic-filter" value="icmp" checked={false} />
                <.label for="filter-icmp" class="ml-4 mt-2">
                  ICMP
                </.label>
              </div>
              <div class="h-12 flex items-center mb-4">
                <.checkbox id="filter-tcp" name="traffic-filter" value="tcp" checked={false} />
                <.label for="filter-tcp" class="ml-4 mr-4 mt-2">
                  TCP
                </.label>
                <.input
                  placeholder="Enter port range(s)"
                  id="tcp-port"
                  name="tcp-port"
                  value=""
                  class="ml-8"
                />
              </div>
              <div class="h-12 flex items-center">
                <.checkbox id="filter-udp" name="traffic-filter" value="udp" checked={false} />
                <.label for="filter-udp" class="ml-4 mr-4 mt-2">
                  UDP
                </.label>
                <.input placeholder="Enter port range(s)" id="udp-port" name="udp-port" value="" />
              </div>
            </div>
            <hr />
            <div>
              <h3>
                Gateway Instance Group(s)
              </h3>
              <div class="rounded-lg relative overflow-x-auto">
                <.table id="gateway_groups" rows={@gateway_groups}>
                  <:col :let={gateway_group}>
                    <.checkbox name="gateway_group" value={gateway_group.id} />
                  </:col>
                  <:col :let={gateway_group} label="NAME">
                    <%= gateway_group.name_prefix %>
                  </:col>
                  <:col :let={_gateway_group} label="STATUS">
                    <.badge type="success">TODO: Online</.badge>
                  </:col>
                </.table>
              </div>
            </div>
          </div>
          <div class="flex items-center space-x-4">
            <.submit_button>
              Save
            </.submit_button>
          </div>
        </form>
      </div>
    </section>
    """
  end
end
