defmodule Web.ResourcesLive.Edit do
  use Web, :live_view

  alias Domain.Gateways
  alias Domain.Resources

  def filter_states(filters) do
    accumulator = %{all: false, icmp: false, tcp: false, udp: false}

    Enum.reduce(filters, accumulator, fn f, acc ->
      Map.put(acc, f.protocol, true)
    end)
  end

  def ports(filters, type) do
    filter = Enum.find(filters, &(&1.protocol == type))

    case filter do
      nil -> ""
      _ -> Enum.join(filter.ports, ", ")
    end
  end

  def mount(%{"id" => id} = _params, _session, socket) do
    {:ok, resource} =
      Resources.fetch_resource_by_id(id, socket.assigns.subject, preload: :gateway_groups)

    {:ok, gateway_groups} = Gateways.list_groups(socket.assigns.subject)

    socket =
      assign(socket,
        filter_states: filter_states(resource.filters),
        gateway_groups: gateway_groups,
        resource: resource
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/#{@subject.account}/dashboard"},
          %{label: "Resources", path: ~p"/#{@subject.account}/resources"},
          %{
            label: "#{@resource.name}",
            path: ~p"/#{@subject.account}/resources/#{@resource.id}"
          },
          %{
            label: "Edit",
            path: ~p"/#{@subject.account}/resources/#{@resource.id}/edit"
          }
        ]} />
      </:breadcrumbs>
      <:title>
        Edit Resource
      </:title>
    </.section_header>
    <!-- Edit Resource -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit Resource details</h2>
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
                value={@resource.name}
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
                value={@resource.address}
                required
              />
            </div>
            <hr />
            <div class="w-full">
              <h3>
                Traffic Restriction
              </h3>
              <div class="h-12 flex items-center mb-4">
                <.checkbox
                  id="filter-all"
                  name="traffic-filter"
                  value="none"
                  checked={@filter_states[:all]}
                />
                <.label for="filter-all" class="ml-4 mt-2">
                  Permit all
                </.label>
              </div>
              <div class="h-12 flex items-center mb-4">
                <.checkbox
                  id="filter-icmp"
                  name="traffic-filter"
                  value="icmp"
                  checked={@filter_states[:icmp]}
                />
                <.label for="filter-icmp" class="ml-4 mt-2">
                  ICMP
                </.label>
              </div>
              <div class="h-12 flex items-center mb-4">
                <.checkbox
                  id="filter-tcp"
                  name="traffic-filter"
                  value="tcp"
                  checked={@filter_states[:tcp]}
                />
                <.label for="filter-tcp" class="ml-4 mr-4 mt-2">
                  TCP
                </.label>
                <.input
                  placeholder="Enter port range(s)"
                  id="tcp-port"
                  name="tcp-port"
                  value={ports(@resource.filters, :tcp)}
                  class="ml-8"
                />
              </div>
              <div class="h-12 flex items-center">
                <.checkbox
                  id="filter-udp"
                  name="traffic-filter"
                  value="udp"
                  checked={@filter_states[:udp]}
                />
                <.label for="filter-udp" class="ml-4 mr-4 mt-2">
                  UDP
                </.label>
                <.input
                  placeholder="Enter port range(s)"
                  id="udp-port"
                  name="udp-port"
                  value={ports(@resource.filters, :udp)}
                />
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
                    <.checkbox
                      name="gateway_group"
                      value={gateway_group.id}
                      checked={Enum.member?(@resource.gateway_groups, gateway_group)}
                    />
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
