defmodule Web.Policies.New do
  use Web, :live_view

  alias Domain.{Resources, Actors}

  def mount(_params, _session, socket) do
    {:ok, resources} = Resources.list_resources(socket.assigns.subject)
    {:ok, actor_groups} = Actors.list_groups(socket.assigns.subject)

    socket =
      assign(socket,
        resources: resources,
        actor_groups: actor_groups
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/new"}>Add Policy</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Add a new Policy
      </:title>
    </.header>
    <!-- Add Policy -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Policy details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="policy-name">
                Name
              </.label>
              <.input
                autocomplete="off"
                type="text"
                name="name"
                value=""
                id="policy-name"
                placeholder="Enter a name for this policy"
              />
            </div>
            <div>
              <.label for="group">
                Group
              </.label>

              <.input
                type="select"
                options={Enum.map(@actor_groups, fn g -> [key: g.name, value: g.id] end)}
                name="actor_group"
                value=""
              />
            </div>
            <div>
              <.label for="resource">
                Resource
              </.label>
              <.input
                type="select"
                options={Enum.map(@resources, fn r -> [key: r.name, value: r.id] end)}
                name="resource"
                value=""
              />
            </div>
          </div>
          <div class="flex items-center space-x-4">
            <.button type="submit">
              Save
            </.button>
          </div>
        </form>
      </div>
    </section>
    """
  end
end
