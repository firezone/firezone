defmodule Web.Resources.Index do
  use Web, :live_view
  alias Domain.Resources

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Resources.subscribe_to_events_for_account(socket.assigns.account)
    end

    socket =
      socket
      |> assign(page_title: "Resources")
      |> assign_live_table("resources",
        query_module: Resources.Resource.Query,
        sortable_fields: [
          {:resources, :name},
          {:resources, :address}
        ],
        callback: &handle_resources_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_resources_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:gateway_groups])

    with {:ok, resources, metadata} <-
           Resources.list_resources(socket.assigns.subject, list_opts) do
      {:ok, resource_actor_groups_peek} =
        Resources.peek_resource_actor_groups(resources, 3, socket.assigns.subject)

      assign(socket,
        resources: resources,
        resource_actor_groups_peek: resource_actor_groups_peek,
        resources_metadata: metadata
      )
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
      <:help>
        Resources define the subnets, hosts, and applications for which you want to manage access. You can manage resources per site
        in the <.link navigate={~p"/#{@account}/sites"} class={link_style()}>sites</.link> section.
      </:help>
      <:action>
        <.add_button
          :if={Domain.Accounts.multi_site_resources_enabled?(@account)}
          navigate={~p"/#{@account}/resources/new"}
        >
          Add Multi-Site Resource
        </.add_button>
      </:action>
      <:content>
        <.flash_group flash={@flash} />
        <.live_table
          id="resources"
          rows={@resources}
          row_id={&"resource-#{&1.id}"}
          filters={@filters_by_table_id["resources"]}
          filter={@filter_form_by_table_id["resources"]}
          ordered_by={@order_by_table_id["resources"]}
          metadata={@resources_metadata}
        >
          <:col :let={resource} field={{:resources, :name}} label="NAME">
            <.link navigate={~p"/#{@account}/resources/#{resource.id}"} class={link_style()}>
              <%= resource.name %>
            </.link>
          </:col>
          <:col :let={resource} field={{:resources, :address}} label="ADDRESS">
            <code class="block text-xs">
              <%= resource.address %>
            </code>
          </:col>
          <:col :let={resource} label="sites">
            <.link
              :for={gateway_group <- resource.gateway_groups}
              navigate={~p"/#{@account}/sites/#{gateway_group}"}
              class={link_style()}
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
                <.group account={@account} group={group} />
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
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_info({:create_resource, _resource_id}, socket) do
    {:noreply, socket}
  end

  def handle_info({:delete_resource, resource_id}, socket) do
    if Enum.find(socket.assigns.policies, fn resource -> resource.id == resource_id end) do
      policies =
        Enum.filter(socket.assigns.policies, fn resource ->
          resource.id != resource_id
        end)

      {:noreply, assign(socket, policies: policies)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({_action, _resource_id}, socket) do
    {:noreply, reload_live_table!(socket, "resources")}
  end
end
