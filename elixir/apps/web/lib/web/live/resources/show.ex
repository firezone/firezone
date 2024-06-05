defmodule Web.Resources.Show do
  use Web, :live_view
  import Web.Policies.Components
  import Web.Resources.Components
  alias Domain.{Accounts, Resources, Policies, Flows}

  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, resource} <-
           Resources.fetch_resource_by_id(id, socket.assigns.subject,
             preload: [:gateway_groups, created_by_identity: [:actor]]
           ),
         {:ok, actor_groups_peek} <-
           Resources.peek_resource_actor_groups([resource], 3, socket.assigns.subject) do
      if connected?(socket) do
        :ok = Resources.subscribe_to_events_for_resource(resource)
      end

      socket =
        assign(
          socket,
          page_title: "Resource #{resource.name}",
          flow_activities_enabled?: Accounts.flow_activities_enabled?(socket.assigns.account),
          resource: resource,
          actor_groups_peek: Map.fetch!(actor_groups_peek, resource.id),
          params: Map.take(params, ["site_id"])
        )
        |> assign_live_table("flows",
          query_module: Flows.Flow.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_flows_update!/2
        )
        |> assign_live_table("policies",
          query_module: Policies.Policy.Query,
          hide_filters: [:actor_group_id],
          enforce_filters: [
            {:resource_id, resource.id}
          ],
          sortable_fields: [],
          callback: &handle_policies_update!/2
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, actor_group: [:provider], resource: [])

    with {:ok, policies, metadata} <- Policies.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def handle_flows_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:group],
        policy: [:resource, :actor_group]
      )

    with {:ok, flows, metadata} <-
           Flows.list_flows_for(socket.assigns.resource, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         flows: flows,
         flows_metadata: metadata
       )}
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
        <span :if={not is_nil(@resource.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@resource.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/resources/#{@resource.id}/edit?#{@params}"}>
          Edit Resource
        </.edit_button>
      </:action>
      <:content>
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
          <.vertical_table_row :if={false}>
            <:label>
              Address Description
            </:label>
            <:value>
              <a
                href={
                  if String.starts_with?(@resource.address_description, ["http", "ftp", "//"]) do
                    @resource.address_description
                  else
                    "//" <> @resource.address_description
                  end
                }
                target="_blank"
                class={link_style()}
              >
                <%= @resource.address_description %>
                <.icon name="hero-arrow-top-right-on-square" class="mb-3 w-3 h-3" />
              </a>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Connected Sites
            </:label>
            <:value>
              <.link
                :for={gateway_group <- @resource.gateway_groups}
                :if={@resource.gateway_groups != []}
                navigate={~p"/#{@account}/sites/#{gateway_group}"}
                class={[link_style()]}
              >
                <.badge type="info">
                  <%= gateway_group.name %>
                </.badge>
              </.link>
              <span :if={@resource.gateway_groups == []}>
                No linked gateways to display
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Traffic restriction
            </:label>
            <:value>
              <div :if={@resource.filters == []} %>
                All traffic allowed
              </div>
              <div :for={filter <- @resource.filters} :if={@resource.filters != []} %>
                <.filter_description filter={filter} />
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
      </:content>
    </.section>

    <.section>
      <:title>
        Policies
      </:title>
      <:action>
        <.add_button navigate={
          if site_id = @params["site_id"] do
            ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{site_id}"
          else
            ~p"/#{@account}/policies/new?resource_id=#{@resource}"
          end
        }>
          Add Policy
        </.add_button>
      </:action>
      <:content>
        <.live_table
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
        >
          <:col :let={policy} label="id">
            <.link class={link_style()} navigate={~p"/#{@account}/policies/#{policy}"}>
              <%= policy.id %>
            </.link>
          </:col>
          <:col :let={policy} label="group">
            <.group account={@account} group={policy.actor_group} />
          </:col>
          <:col :let={policy} label="status">
            <%= if is_nil(policy.deleted_at) do %>
              <%= if is_nil(policy.disabled_at) do %>
                Active
              <% else %>
                Disabled
              <% end %>
            <% else %>
              Deleted
            <% end %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="pb-4 w-auto">
                No policies to display.
                <.link
                  class={[link_style()]}
                  navigate={
                    if site_id = @params["site_id"] do
                      ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{site_id}"
                    else
                      ~p"/#{@account}/policies/new?resource_id=#{@resource}"
                    end
                  }
                >
                  Add a policy
                </.link>
                to grant access to a resource.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Activity
      </:title>
      <:help>
        Attempts by actors to access this resource.
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
          <:col :let={flow} label="authorized">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="expires">
            <.relative_datetime datetime={flow.expires_at} />
          </:col>
          <:col :let={flow} label="policy">
            <.link navigate={~p"/#{@account}/policies/#{flow.policy_id}"} class={[link_style()]}>
              <.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="client, actor" class="w-3/12">
            <.link navigate={~p"/#{@account}/clients/#{flow.client_id}"} class={[link_style()]}>
              <%= flow.client.name %>
            </.link>
            owned by
            <.link navigate={~p"/#{@account}/actors/#{flow.client.actor_id}"} class={[link_style()]}>
              <%= flow.client.actor.name %>
            </.link>
            <%= flow.client_remote_ip %>
          </:col>
          <:col :let={flow} label="gateway" class="w-3/12">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            <br />
            <code class="text-xs"><%= flow.gateway_remote_ip %></code>
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="activity">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={[link_style()]}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@resource.deleted_at)}>
      <:action>
        <.delete_button
          data-confirm="Are you sure want to delete this resource along with all associated policies?"
          phx-click="delete"
          phx-value-id={@resource.id}
        >
          Delete Resource
        </.delete_button>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info({_action, _resource_id}, socket) do
    {:ok, resource} =
      Resources.fetch_resource_by_id(socket.assigns.resource.id, socket.assigns.subject,
        preload: [:gateway_groups, :policies, created_by_identity: [:actor]]
      )

    {:noreply, assign(socket, resource: resource)}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("delete", %{"id" => _resource_id}, socket) do
    {:ok, _} = Resources.delete_resource(socket.assigns.resource, socket.assigns.subject)

    if site_id = socket.assigns.params["site_id"] do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}")}
    else
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources")}
    end
  end
end
