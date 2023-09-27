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

  def handle_event("delete", _params, socket) do
    {:ok, _client} = Clients.delete_client(socket.assigns.client, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/clients")}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client.id}"}>
        <%= @client.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.header>
      <:title>
        Client Details
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/clients/#{@client}/edit"}>
          Edit Client
        </.edit_button>
      </:actions>
    </.header>
    <!-- Client Details -->
    <div id="client" class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table>
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
          <:label>Remote IPv4</:label>
          <:value><code><%= @client.ipv4 %></code></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Remote IPv6</:label>
          <:value><code><%= @client.ipv6 %></code></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Transfer</:label>
          <:value>TODO</:value>
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

      <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
        <div class="col-span-full mb-4 xl:mb-2">
          <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
            Authorizations
          </h1>
        </div>
      </div>
      <.table id="flows" rows={@flows} row_id={&"flows-#{&1.id}"}>
        <:col :let={flow} label="AUTHORIZED AT">
          <.relative_datetime datetime={flow.inserted_at} />
        </:col>
        <:col :let={flow} label="EXPIRES AT">
          <.relative_datetime datetime={flow.expires_at} />
        </:col>
        <:col :let={flow} label="REMOTE IP">
          <%= flow.source_remote_ip %>
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
          (<%= flow.destination_remote_ip %>)
        </:col>
      </.table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button
          phx-click="delete"
          data-confirm={
            "Are you sure want to delete this client? " <>
            "User still will be able to create a new one by reconnecting to the Firezone."
          }
        >
          Delete Client
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
