defmodule Web.Resources.Index do
  use Web, :live_view
  alias Domain.Resources

  def mount(_params, _session, socket) do
    {_, resources} =
      Resources.list_resources(socket.assigns.subject,
        preload: [:gateway_groups, policies: [:actor_group]]
      )

    {:ok, assign(socket, resources: resources)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Resources
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/resources/new"}>
          Add Resource
        </.add_button>
      </:action>
      <:content>
        <div class="bg-white dark:bg-gray-800 overflow-hidden">
          <.table id="resources" rows={@resources} row_id={&"resource-#{&1.id}"}>
            <:col :let={resource} label="NAME">
              <.link
                navigate={~p"/#{@account}/resources/#{resource.id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= resource.name %>
              </.link>
            </:col>
            <:col :let={resource} label="ADDRESS">
              <code class="block text-xs">
                <%= resource.address %>
              </code>
            </:col>
            <:col :let={resource} label="sites">
              <.link
                :for={gateway_group <- resource.gateway_groups}
                navigate={~p"/#{@account}/sites"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <.badge type="info">
                  <%= gateway_group.name_prefix %>
                </.badge>
              </.link>
            </:col>
            <:col :let={resource} label="AUTHORIZED GROUPS">
              <.link :for={policy <- resource.policies} navigate={~p"/#{@account}/policies/#{policy}"}>
                <.badge><%= policy.actor_group.name %></.badge>
              </.link>
            </:col>
            <:empty>
              <div class="flex justify-center text-center text-slate-500 p-4">
                <div class="w-auto">
                  <div class="pb-4">
                    No resources to display
                  </div>
                  <.add_button navigate={~p"/#{@account}/resources/new"}>
                    Add Resource
                  </.add_button>
                </div>
              </div>
            </:empty>
          </.table>
        </div>
      </:content>
    </.section>
    """
  end
end
