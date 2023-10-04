defmodule Web.Resources.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Resources, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, resource} <-
           Resources.fetch_resource_by_id(id, socket.assigns.subject,
             preload: [:gateway_groups, created_by_identity: [:actor]]
           ),
         {:ok, flows} <-
           Flows.list_flows_for(resource, socket.assigns.subject,
             preload: [client: [:actor], gateway: [:group], policy: [:resource, :actor_group]]
           ) do
      {:ok, assign(socket, resource: resource, flows: flows)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/#{@resource.id}"}>
        <%= @resource.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Resource: <code><%= @resource.name %></code>
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/resources/#{@resource.id}/edit"}>
          Edit Resource
        </.edit_button>
      </:action>
      <:content>
        <div class="bg-white dark:bg-gray-800 overflow-hidden">
          <.vertical_table id="resource">
            <.vertical_table_row>
              <:label>
                Name
              </:label>
              <:value>
                <%= @resource.name %>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                Address
              </:label>
              <:value>
                <%= @resource.address %>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                Traffic Filtering Rules
              </:label>
              <:value>
                <div :if={@resource.filters == []} %>
                  No traffic filtering rules
                </div>
                <div :for={filter <- @resource.filters} :if={@resource.filters != []} %>
                  <code>
                    <%= pretty_print_filter(filter) %>
                  </code>
                </div>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                Created
              </:label>
              <:value>
                <.created_by account={@account} schema={@resource} />
              </:value>
            </.vertical_table_row>
          </.vertical_table>
        </div>
      </:content>
    </.section>

    <.section>
      <:title>
        Linked Gateway Instance Groups
      </:title>
      <:content>
        <.table id="gateway_instance_groups" rows={@resource.gateway_groups}>
          <:col :let={gateway_group} label="NAME">
            <.link
              navigate={~p"/#{@account}/gateway_groups/#{gateway_group}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= gateway_group.name_prefix %>
            </.link>
          </:col>
        </.table>
      </:content>
    </.section>

    <.section>
      <:title>
        Authorizations
      </:title>
      <:content>
        <.table id="flows" rows={@flows} row_id={&"flows-#{&1.id}"}>
          <:col :let={flow} label="AUTHORIZED AT">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="EXPIRES AT">
            <.relative_datetime datetime={flow.expires_at} />
          </:col>
          <:col :let={flow} label="POLICY">
            <.link
              navigate={~p"/#{@account}/policies/#{flow.policy_id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="CLIENT, ACTOR (IP)">
            <.link
              navigate={~p"/#{@account}/clients/#{flow.client_id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= flow.client.name %>
            </.link>
            owned by
            <.link
              navigate={~p"/#{@account}/actors/#{flow.client.actor_id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= flow.client.actor.name %>
            </.link>
            (<%= flow.client_remote_ip %>)
          </:col>
          <:col :let={flow} label="GATEWAY (IP)">
            <.link
              navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= flow.gateway.group.name_prefix %>-<%= flow.gateway.name_suffix %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} label="ACTIVITY">
            <.link
              navigate={~p"/#{@account}/flows/#{flow.id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              Show
            </.link>
          </:col>
        </.table>
      </:content>
    </.section>

    <.section>
      <:title>Danger Zone</:title>
      <:action>
        <.delete_button
          data-confirm="Are you sure want to delete this resource?"
          phx-click="delete"
          phx-value-id={@resource.id}
        >
          Delete Resource
        </.delete_button>
      </:action>
      <:content></:content>
    </.section>
    """
  end

  def handle_event("delete", %{"id" => _resource_id}, socket) do
    {:ok, _} = Resources.delete_resource(socket.assigns.resource, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources")}
  end

  defp pretty_print_filter(filter) do
    case filter.protocol do
      :all ->
        "All Traffic Allowed"

      :icmp ->
        "ICPM: Allowed"

      :tcp ->
        "TCP: #{pretty_print_ports(filter.ports)}"

      :udp ->
        "UDP: #{pretty_print_ports(filter.ports)}"
    end
  end

  defp pretty_print_ports([]), do: "any port"
  defp pretty_print_ports(ports), do: Enum.join(ports, ", ")
end
