defmodule Web.Policies.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Accounts, Policies, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [actor_group: [:provider], resource: [], created_by_identity: :actor]
           ) do
      if connected?(socket) do
        :ok = Policies.subscribe_to_events_for_policy(policy)
      end

      socket =
        assign(socket,
          page_title: "Policy #{policy.id}",
          policy: policy,
          flow_activities_enabled?: Accounts.flow_activities_enabled?(socket.assigns.account)
        )
        |> assign_live_table("flows",
          query_module: Flows.Flow.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_flows_update!/2
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_flows_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:group]
      )

    with {:ok, flows, metadata} <-
           Flows.list_flows_for(socket.assigns.policy, socket.assigns.subject, list_opts) do
      assign(socket,
        flows: flows,
        flows_metadata: metadata
      )
    else
      {:error, :invalid_cursor} -> raise Web.LiveErrors.InvalidRequestError
      {:error, {:unknown_filter, _metadata}} -> raise Web.LiveErrors.InvalidRequestError
      {:error, {:invalid_type, _metadata}} -> raise Web.LiveErrors.InvalidRequestError
      {:error, {:invalid_value, _metadata}} -> raise Web.LiveErrors.InvalidRequestError
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
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
        Policy: <code><%= @policy.id %></code>
        <span :if={not is_nil(@policy.disabled_at)} class="text-primary-600">(disabled)</span>
        <span :if={not is_nil(@policy.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@policy.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/policies/#{@policy}/edit"}>
          Edit Policy
        </.edit_button>
      </:action>
      <:action :if={is_nil(@policy.deleted_at)}>
        <.button
          :if={is_nil(@policy.disabled_at)}
          phx-click="disable"
          style="warning"
          icon="hero-lock-closed"
          data-confirm="Are you sure? Access granted by this policy will be revoked immediately."
        >
          Disable
        </.button>
        <.button
          :if={not is_nil(@policy.disabled_at)}
          phx-click="enable"
          style="warning"
          icon="hero-lock-open"
          data-confirm="Are you sure want to enable this policy?"
        >
          Enable
        </.button>
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
              <.group account={@account} group={@policy.actor_group} />
              <span :if={not is_nil(@policy.actor_group.deleted_at)} class="text-red-600">
                (deleted)
              </span>
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
              <span :if={not is_nil(@policy.resource.deleted_at)} class="text-red-600">
                (deleted)
              </span>
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
        Activity
      </:title>
      <:help>
        Attempts by actors to access the resource governed by this policy.
      </:help>
      <:content>
        <.live_table
          id="flows"
          rows={@flows}
          row_id={&"flows-#{&1.id}"}
          filters={@filters_by_table_id["flows"]}
          filter={@filter_form_by_table_id["flows"]}
          ordered_by={@order_by_table_id["flows"]}
          metadata={@flows_metadata}
        >
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
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="ACTIVITY">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={link_style()}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@policy.deleted_at)}>
      <:action>
        <.delete_button
          phx-click="delete"
          phx-value-id={@policy.id}
          data-confirm="Are you sure you want to delete this policy?"
        >
          Delete Policy
        </.delete_button>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info({_action, _policy_id}, socket) do
    {:ok, policy} =
      Policies.fetch_policy_by_id(socket.assigns.policy.id, socket.assigns.subject,
        preload: [:actor_group, :resource, created_by_identity: :actor]
      )

    {:noreply, assign(socket, policy: policy)}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("disable", _params, socket) do
    {:ok, policy} = Policies.disable_policy(socket.assigns.policy, socket.assigns.subject)

    policy = %{
      policy
      | actor_group: socket.assigns.policy.actor_group,
        resource: socket.assigns.policy.resource,
        created_by_identity: socket.assigns.policy.created_by_identity
    }

    {:noreply, assign(socket, policy: policy)}
  end

  def handle_event("enable", _params, socket) do
    {:ok, policy} = Policies.enable_policy(socket.assigns.policy, socket.assigns.subject)

    policy = %{
      policy
      | actor_group: socket.assigns.policy.actor_group,
        resource: socket.assigns.policy.resource,
        created_by_identity: socket.assigns.policy.created_by_identity
    }

    {:noreply, assign(socket, policy: policy)}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Policies.delete_policy(socket.assigns.policy, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies")}
  end
end
