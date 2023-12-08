defmodule Web.Resources.Index do
  use Web, :live_view
  alias Domain.Resources

  def mount(_params, _session, socket) do
    with {:ok, resources} <-
           Resources.list_resources(socket.assigns.subject,
             preload: [:gateway_groups]
           ),
         {:ok, resource_actor_groups_peek} <-
           Resources.peek_resource_actor_groups(resources, 3, socket.assigns.subject) do
      {:ok,
       assign(socket,
         resources: resources,
         resource_actor_groups_peek: resource_actor_groups_peek
       )}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
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
        <div class="bg-white overflow-hidden">
          <.table id="resources" rows={@resources} row_id={&"resource-#{&1.id}"}>
            <:col :let={resource} label="NAME">
              <.link
                navigate={~p"/#{@account}/resources/#{resource.id}"}
                class={["font-medium", link_style()]}
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
                navigate={~p"/#{@account}/sites/#{gateway_group}"}
                class={["font-medium", link_style()]}
              >
                <.badge type="info">
                  <%= gateway_group.name %>
                </.badge>
              </.link>
            </:col>
            <:col :let={resource} label="Authorized groups">
              <.peek peek={Map.fetch!(@resource_actor_groups_peek, resource.id)}>
                <:empty>
                  None,
                  <.link
                    class={["px-1", link_style()]}
                    navigate={~p"/#{@account}/policies/new?resource_id=#{resource}"}
                  >
                    create a Policy
                  </.link>
                  to grant access.
                </:empty>

                <:item :let={group}>
                  <.link class={link_style()} navigate={~p"/#{@account}/groups/#{group.id}"}>
                    <.badge>
                      <%= group.name %>
                    </.badge>
                  </.link>
                </:item>

                <:tail :let={count}>
                  <span class="inline-block whitespace-nowrap">
                    and <%= count %> more.
                  </span>
                </:tail>
              </.peek>
            </:col>
            <:empty>
              <div class="flex justify-center text-center text-neutral-500 p-4">
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
