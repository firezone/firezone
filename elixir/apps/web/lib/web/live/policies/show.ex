defmodule Web.Policies.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Policies, Flows, Config}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource, [created_by_identity: :actor]]
           ),
         {:ok, flows} <-
           Flows.list_flows_for(policy, socket.assigns.subject,
             preload: [client: [:actor], gateway: [:group]]
           ) do
      socket =
        assign(socket,
          policy: policy,
          flows: flows,
          page_title: "Policy",
          flows_enabled?: Config.flows_enabled?()
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <.policy_name policy={@policy} />
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        <%= @page_title %>: <code><%= @policy.id %></code>
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/policies/#{@policy}/edit"}>
          Edit Policy
        </.edit_button>
      </:action>
      <:content>
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
              <.link navigate={~p"/#{@account}/groups/#{@policy.actor_group_id}"} class={link_style()}>
                <%= @policy.actor_group.name %>
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Resource
            </:label>
            <:value>
              <.link navigate={~p"/#{@account}/resources/#{@policy.resource_id}"} class={link_style()}>
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
              <.datetime datetime={@policy.inserted_at} /> by
              <.link
                navigate={~p"/#{@account}/actors/#{@policy.created_by_identity.actor.id}"}
                class={link_style()}
              >
                <%= @policy.created_by_identity.actor.name %>
              </.link>
            </:value>
          </.vertical_table_row>
        </.vertical_table>
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
          <:col :let={flow} label="CLIENT, ACTOR (IP)">
            <.link navigate={~p"/#{@account}/clients/#{flow.client_id}"} class={link_style()}>
              <%= flow.client.name %>
            </.link>
            owned by
            <.link navigate={~p"/#{@account}/actors/#{flow.client.actor_id}"} class={link_style()}>
              <%= flow.client.actor.name %>
            </.link>
            (<%= flow.client_remote_ip %>)
          </:col>
          <:col :let={flow} label="GATEWAY (IP)">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={link_style()}>
              <%= flow.gateway.group.name_prefix %>-<%= flow.gateway.name_suffix %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} :if={@flows_enabled?} label="ACTIVITY">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={link_style()}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-slate-500 p-4">No authorizations to display</div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.danger_zone>
      <:action>
        <.delete_button
          phx-click="delete"
          phx-value-id={@policy.id}
          data-confirm="Are you sure you want to delete this policy?"
        >
          Delete Policy
        </.delete_button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_event("delete", %{"id" => _policy_id}, socket) do
    {:ok, _} = Policies.delete_policy(socket.assigns.policy, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies")}
  end
end
