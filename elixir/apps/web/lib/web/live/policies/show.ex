defmodule Web.Policies.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Policies, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource, [created_by_identity: :actor]]
           ),
         {:ok, flows} <-
           Flows.list_flows_for(policy, socket.assigns.subject,
             preload: [:client, gateway: [:group]]
           ) do
      {:ok, assign(socket, policy: policy, flows: flows)}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp pretty_print_date(date) do
    "#{date.month}/#{date.day}/#{date.year} #{date.hour}:#{date.minute}:#{date.second}"
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <.policy_name policy={@policy} />
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing Policy <code><%= @policy.id %></code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/policies/#{@policy}/edit"}>
          Edit Policy
        </.edit_button>
      </:actions>
    </.header>
    <!-- Show Policy -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="policy">
        <.vertical_table_row>
          <:label>
            ID
          </:label>
          <:value>
            <%= @policy.id %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Group
          </:label>
          <:value>
            <.link
              navigate={~p"/#{@account}/groups/#{@policy.actor_group_id}"}
              class="text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @policy.actor_group.name %>
            </.link>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Resource
          </:label>
          <:value>
            <.link
              navigate={~p"/#{@account}/resources/#{@policy.resource_id}"}
              class="text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @policy.resource.name %>
            </.link>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Description
          </:label>
          <:value>
            <span class="whitespace-pre" phx-no-format><%= @policy.description %></span>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>
            Created
          </:label>
          <:value>
            <%= pretty_print_date(@policy.inserted_at) %> by
            <.link
              navigate={~p"/#{@account}/actors/#{@policy.created_by_identity.actor.id}"}
              class="text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= @policy.created_by_identity.actor.name %>
            </.link>
          </:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>

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
      <:col :let={flow} label="CLIENT (IP)">
        <.link
          navigate={~p"/#{@account}/clients/#{flow.client_id}"}
          class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
        >
          <%= flow.client.name %>
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
    </.table>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button phx-click="delete" phx-value-id={@policy.id}>
          Delete Policy
        </.delete_button>
      </:actions>
    </.header>
    """
  end

  def handle_event("delete", %{"id" => _policy_id}, socket) do
    {:ok, _} = Policies.delete_policy(socket.assigns.policy, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies")}
  end
end
