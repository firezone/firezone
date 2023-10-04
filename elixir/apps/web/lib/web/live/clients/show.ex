defmodule Web.Clients.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Clients, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, client} <- Clients.fetch_client_by_id(id, socket.assigns.subject, preload: :actor),
         {:ok, flows} <-
           Flows.list_flows_for(client, socket.assigns.subject,
             preload: [gateway: [:group], policy: [:resource, :actor_group]]
           ) do
      {:ok, assign(socket, client: client, flows: flows)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client.id}"}>
        <%= @client.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Client Details
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/clients/#{@client}/edit"}>
          Edit Client
        </.edit_button>
      </:action>
      <:content>
        <.vertical_table id="client">
          <.vertical_table_row>
            <:label>Identifier</:label>
            <:value><%= @client.id %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @client.name %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Owner</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/actors/#{@client.actor.id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= @client.actor.name %>
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <.relative_datetime datetime={@client.inserted_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last Seen</:label>
            <:value>
              <.relative_datetime datetime={@client.last_seen_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Transfer</:label>
            <:value>TODO</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last Seen Remote IP</:label>
            <:value><code><%= @client.last_seen_remote_ip %></code></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Client Version</:label>
            <:value><%= @client.last_seen_version %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>User Agent</:label>
            <:value><%= @client.last_seen_user_agent %></:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Authorizations</:title>
      <:content>
        <.table id="flows" rows={@flows} row_id={&"flows-#{&1.id}"}>
          <:col :let={flow} label="AUTHORIZED AT">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="EXPIRES AT">
            <.relative_datetime datetime={flow.expires_at} />
          </:col>
          <:col :let={flow} label="REMOTE IP">
            <%= flow.client_remote_ip %>
          </:col>
          <:col :let={flow} label="POLICY">
            <.link
              navigate={~p"/#{@account}/policies/#{flow.policy_id}"}
              class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
            >
              <.policy_name policy={flow.policy} />
            </.link>
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
          phx-click="delete"
          data-confirm={
            "Are you sure want to delete this client? " <>
            "User still will be able to create a new one by reconnecting to the Firezone."
          }
        >
          Delete Client
        </.delete_button>
      </:action>
      <:content></:content>
    </.section>
    """
  end

  def handle_event("delete", _params, socket) do
    {:ok, _client} = Clients.delete_client(socket.assigns.client, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/clients")}
  end
end
