defmodule Web.Gateways.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Gateways, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(id, socket.assigns.subject, preload: :group),
         {:ok, flows} <-
           Flows.list_flows_for(gateway, socket.assigns.subject,
             preload: [client: [:actor], policy: [:resource, :actor_group]]
           ) do
      :ok = Gateways.subscribe_for_gateways_presence_in_group(gateway.group)
      {:ok, assign(socket, gateway: gateway, flows: flows)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id, payload: payload},
        socket
      ) do
    if Map.has_key?(payload.joins, socket.assigns.gateway.id) or
         Map.has_key?(payload.leaves, socket.assigns.gateway.id) do
      {:ok, gateway} =
        Gateways.fetch_gateway_by_id(socket.assigns.gateway.id, socket.assigns.subject,
          preload: :group
        )

      {:noreply, assign(socket, gateway: gateway)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _gateway} = Gateways.delete_gateway(socket.assigns.gateway, socket.assigns.subject)

    socket =
      redirect(socket,
        to: ~p"/#{socket.assigns.account}/gateway_groups/#{socket.assigns.gateway.group}"
      )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/gateway_groups"}>Gateway Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateway_groups/#{@gateway.group}"}>
        <%= @gateway.group.name_prefix %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}"}>
        <%= @gateway.name_suffix %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Gateway: <code><%= @gateway.name_suffix %></code>
      </:title>
    </.header>
    <!-- Gateway details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="gateway">
        <.vertical_table_row>
          <:label>Instance Group Name</:label>
          <:value>
            <.link
              navigate={~p"/#{@account}/gateway_groups/#{@gateway.group}"}
              class="font-bold text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @gateway.group.name_prefix %>
            </.link>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Instance Name</:label>
          <:value><%= @gateway.name_suffix %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Connectivity</:label>
          <:value>TODO: Peer to Peer</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Status</:label>
          <:value>
            <.connection_status schema={@gateway} />
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Last seen
          </:label>
          <:value>
            <.relative_datetime datetime={@gateway.last_seen_at} />
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Seen Remote IP</:label>
          <:value>
            <code><%= @gateway.last_seen_remote_ip %></code>
          </:value>
        </.vertical_table_row>
        <!--
        <.vertical_table_row>
          <:label>Transfer</:label>
          <:value>TODO: 4.43 GB up, 1.23 GB down</:value>
        </.vertical_table_row>
        -->
        <.vertical_table_row>
          <:label>Version</:label>
          <:value>
            <%= @gateway.last_seen_version %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>User Agent</:label>
          <:value>
            <%= @gateway.last_seen_user_agent %>
          </:value>
        </.vertical_table_row>
        <!--
        <.vertical_table_row>
          <:label>Deployment Method</:label>
          <:value>TODO: Docker</:value>
        </.vertical_table_row>
        -->
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
          <%= flow.gateway_remote_ip %>
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
        <:col :let={flow} label="ACTIVITY">
          <.link
            navigate={~p"/#{@account}/flows/#{flow.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            Show
          </.link>
        </:col>
      </.table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button phx-click="delete">
          Delete Gateway
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
