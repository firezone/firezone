defmodule Web.Flows.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Flows, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, flow} <-
           Flows.fetch_flow_by_id(id, socket.assigns.subject,
             preload: [
               policy: [:resource, :actor_group],
               client: [],
               gateway: [:group],
               resource: []
             ]
           ) do
      socket = assign(socket, flow: flow, page_title: "Flows")
      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb>Flows</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/flows/#{@flow.id}"}>
        <%= @flow.client.name %> flow
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Flow for: <code><%= @flow.client.name %></code>
      </:title>
      <:action>
        <.button
          navigate={~p"/#{@account}/flows/#{@flow}/activities.csv"}
          icon="hero-arrow-down-on-square"
        >
          Export to CSV
        </.button>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="flow">
          <.vertical_table_row>
            <:label>Authorized At</:label>
            <:value>
              <.relative_datetime datetime={@flow.inserted_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Expires At</:label>
            <:value>
              <.relative_datetime datetime={@flow.expires_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Policy</:label>
            <:value>
              <.link navigate={~p"/#{@account}/policies/#{@flow.policy_id}"} class={link_style()}>
                <.policy_name policy={@flow.policy} />
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Client</:label>
            <:value>
              <.link navigate={~p"/#{@account}/clients/#{@flow.client_id}"} class={link_style()}>
                <%= @flow.client.name %>
              </.link>
              <div>Remote IP: <%= @flow.client_remote_ip %></div>
              <div>User Agent: <%= @flow.client_user_agent %></div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Gateway</:label>
            <:value>
              <.link navigate={~p"/#{@account}/gateways/#{@flow.gateway_id}"} class={link_style()}>
                <%= @flow.gateway.group.name %>-<%= @flow.gateway.name %>
              </.link>
              <div>
                Remote IP: <%= @flow.gateway_remote_ip %>
              </div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Resource</:label>
            <:value>
              <.link navigate={~p"/#{@account}/resources/#{@flow.resource_id}"} class={link_style()}>
                <%= @flow.resource.name %>
              </.link>
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>
    """
  end
end
