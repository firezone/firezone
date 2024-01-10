defmodule Web.Resources.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Resources, Flows, Config}

  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, resource} <-
           Resources.fetch_resource_by_id(id, socket.assigns.subject,
             preload: [:gateway_groups, :policies, created_by_identity: [:actor]]
           ),
         {:ok, actor_groups_peek} <-
           Resources.peek_resource_actor_groups([resource], 3, socket.assigns.subject),
         {:ok, flows} <-
           Flows.list_flows_for(resource, socket.assigns.subject,
             preload: [client: [:actor], gateway: [:group], policy: [:resource, :actor_group]]
           ) do
      socket =
        assign(
          socket,
          resource: resource,
          actor_groups_peek: Map.fetch!(actor_groups_peek, resource.id),
          flows: flows,
          params: Map.take(params, ["site_id"]),
          traffic_filters_enabled?: Config.traffic_filters_enabled?(),
          page_title: "Resources"
        )

      {:ok, socket}
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
        <span :if={not is_nil(@resource.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@resource.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/resources/#{@resource.id}/edit?#{@params}"}>
          Edit Resource
        </.edit_button>
      </:action>
      <:content>
        <div class="bg-white overflow-hidden">
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
                Authorized groups
              </:label>
              <:value>
                <.peek peek={@actor_groups_peek}>
                  <:empty>
                    <.icon name="hero-exclamation-triangle" class="text-red-500 mr-1" /> None,
                    <.link
                      class={["px-1", link_style()]}
                      navigate={
                        if site_id = @params["site_id"] do
                          ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{site_id}"
                        else
                          ~p"/#{@account}/policies/new?resource_id=#{@resource}"
                        end
                      }
                    >
                      create a Policy
                    </.link>
                    to grant access.
                  </:empty>

                  <:item :let={group}>
                    <.link
                      class={link_style()}
                      navigate={~p"/#{@account}/groups/#{group.id}?#{@params}"}
                    >
                      <.badge>
                        <%= group.name %>
                      </.badge>
                    </.link>
                  </:item>

                  <:tail :let={count}>
                    <span class="inline-block whitespace-nowrap">
                      and <%= count %> more.
                    </span>
                  </:tail>

                  <:call_to_action>
                    <.link
                      class={["text-neutral-600", "hover:underline", "relative"]}
                      navigate={
                        if site_id = @params["site_id"] do
                          ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{site_id}"
                        else
                          ~p"/#{@account}/policies/new?resource_id=#{@resource}"
                        end
                      }
                    >
                      <.icon name="hero-plus w-3 h-3 absolute bottom-1" />
                    </.link>
                  </:call_to_action>
                </.peek>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row :if={@traffic_filters_enabled?}>
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
        Sites
      </:title>
      <:content>
        <.table id="gateway_instance_groups" rows={@resource.gateway_groups}>
          <:col :let={gateway_group} label="NAME">
            <.link navigate={~p"/#{@account}/sites/#{gateway_group}"} class={[link_style()]}>
              <%= gateway_group.name %>
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No linked gateways to display</div>
          </:empty>
        </.table>
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
        <.table id="flows" rows={@flows} row_id={&"flows-#{&1.id}"}>
          <:col :let={flow} label="AUTHORIZED AT">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="EXPIRES AT">
            <.relative_datetime datetime={flow.expires_at} />
          </:col>
          <:col :let={flow} label="POLICY">
            <.link navigate={~p"/#{@account}/policies/#{flow.policy_id}"} class={[link_style()]}>
              <.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="CLIENT, ACTOR (IP)">
            <.link navigate={~p"/#{@account}/clients/#{flow.client_id}"} class={[link_style()]}>
              <%= flow.client.name %>
            </.link>
            owned by
            <.link navigate={~p"/#{@account}/actors/#{flow.client.actor_id}"} class={[link_style()]}>
              <%= flow.client.actor.name %>
            </.link>
            (<%= flow.client_remote_ip %>)
          </:col>
          <:col :let={flow} label="GATEWAY (IP)">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} label="ACTIVITY">
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

    <.danger_zone :if={is_nil(@resource.deleted_at)}>
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
    </.danger_zone>
    """
  end

  def handle_event("delete", %{"id" => _resource_id}, socket) do
    {:ok, _} = Resources.delete_resource(socket.assigns.resource, socket.assigns.subject)

    if site_id = socket.assigns.params["site_id"] do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}")}
    else
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources")}
    end
  end

  defp pretty_print_filter(filter) do
    case filter.protocol do
      :all ->
        "All Traffic Allowed"

      :icmp ->
        "ICMP: Allowed"

      :tcp ->
        "TCP: #{pretty_print_ports(filter.ports)}"

      :udp ->
        "UDP: #{pretty_print_ports(filter.ports)}"
    end
  end

  defp pretty_print_ports([]), do: "any port"
  defp pretty_print_ports(ports), do: Enum.join(ports, ", ")
end
