defmodule Web.Clients.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Clients, Flows, Config}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, client} <-
           Clients.fetch_client_by_id(id, socket.assigns.subject,
             preload: [:actor, last_used_token: [identity: [:provider]]]
           ),
         {:ok, flows} <-
           Flows.list_flows_for(client, socket.assigns.subject,
             preload: [gateway: [:group], policy: [:resource, :actor_group]]
           ) do
      :ok = Clients.subscribe_to_clients_presence_in_account(client.account_id)

      socket =
        assign(
          socket,
          client: client,
          flows: flows,
          flow_activities_enabled?: Config.flow_activities_enabled?(),
          page_title: "Client #{client.name}"
        )

      {:ok, socket}
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
        <span :if={not is_nil(@client.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@client.deleted_at)}>
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
            <:label>Status</:label>
            <:value><.connection_status schema={@client} /></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last used sign in method</:label>
            <:value>
              <span :if={@client.actor.type != :service_account}>
                <.identity_identifier account={@account} identity={@client.last_used_token.identity} />
                <.link
                  navigate={
                    ~p"/#{@account}/actors/#{@client.actor_id}?#tokens-#{@client.last_used_token_id}"
                  }
                  class={[link_style(), "text-xs"]}
                >
                  show tokens
                </.link>
              </span>
              <span :if={@client.actor.type == :service_account}>
                token
                <.link
                  navigate={
                    ~p"/#{@account}/actors/#{@client.actor_id}?#tokens-#{@client.last_used_token_id}"
                  }
                  class={[link_style()]}
                >
                  <%= @client.last_used_token.name %>
                </.link>
                <span :if={not is_nil(@client.last_used_token.deleted_at)}>
                  (deleted)
                </span>
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Owner</:label>
            <:value>
              <.link navigate={~p"/#{@account}/actors/#{@client.actor.id}"} class={[link_style()]}>
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
            <:label>Last Seen Remote IP</:label>
            <:value>
              <.last_seen schema={@client} />
            </:value>
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
      <:title>Activity</:title>
      <:help>
        Attempts by the actor using this client to access resources.
      </:help>
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
            <.link navigate={~p"/#{@account}/policies/#{flow.policy_id}"} class={[link_style()]}>
              <.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="GATEWAY (IP)">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="ACTIVITY">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={[link_style()]}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.table>
      </:content>
    </.section>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "clients:" <> _account_id, payload: payload},
        socket
      ) do
    client = socket.assigns.client

    socket =
      cond do
        Map.has_key?(payload.joins, client.id) ->
          assign(socket, client: %{client | online?: true})

        Map.has_key?(payload.leaves, client.id) ->
          assign(socket, client: %{client | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end
end
