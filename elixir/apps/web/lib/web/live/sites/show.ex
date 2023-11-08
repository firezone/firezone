defmodule Web.Sites.Show do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               gateways: [token: [created_by_identity: [:actor]]],
               connections: [:resource],
               created_by_identity: [:actor]
             ]
           ) do
      group = %{
        group
        | gateways: Enum.sort_by(group.gateways, &{&1.online?, &1.name_suffix}, :desc)
      }

      :ok = Gateways.subscribe_for_gateways_presence_in_group(group)
      {:ok, assign(socket, group: group)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        <%= @group.name_prefix %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Site: <code><%= @group.name_prefix %></code>
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/sites/#{@group}/edit"}>
          Edit Site
        </.edit_button>
      </:action>

      <:content>
        <.vertical_table id="group">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @group.name_prefix %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <.created_by account={@account} schema={@group} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Gateways</:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
          Deploy
        </.add_button>
      </:action>
      <:content>
        <div class="relative overflow-x-auto">
          <.table id="gateways" rows={@group.gateways}>
            <:col :let={gateway} label="INSTANCE">
              <.link
                navigate={~p"/#{@account}/gateways/#{gateway.id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= gateway.name_suffix %>
              </.link>
            </:col>
            <:col :let={gateway} label="REMOTE IP">
              <code>
                <%= gateway.last_seen_remote_ip %>
              </code>
            </:col>
            <:col :let={gateway} label="TOKEN CREATED AT">
              <.created_by account={@account} schema={gateway.token} />
            </:col>
            <:col :let={gateway} label="STATUS">
              <.connection_status schema={gateway} />
            </:col>
            <:empty>
              <div class="flex flex-col items-center justify-center text-center text-slate-500 p-4">
                <div class="pb-4">
                  No gateway instances to display.
                </div>
                <div class="pb-4">
                  <.add_button navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
                    Deploy a Gateway
                  </.add_button>
                </div>
                <div>
                  <p>
                    Gateways serve as a termination point for all VPN connections within a site, they must be deployed
                    to your infrastructure to enable VPN connectivity.
                  </p>
                  <p>
                    If site has more than one gateway deployed,
                    connections will be load balanced between them. Because of this, all gateways within a site must
                    be able to access all site resources.
                  </p>
                </div>
              </div>
            </:empty>
          </.table>
        </div>
      </:content>
    </.section>

    <.section>
      <:title>
        Resources
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/resources/new?site_id=#{@group}"}>
          Create
        </.add_button>
      </:action>
      <:content>
        <div class="relative overflow-x-auto">
          <.table
            id="resources"
            rows={Enum.reject(@group.connections, &is_nil(&1.resource))}
            row_item={& &1.resource}
          >
            <:col :let={resource} label="NAME">
              <.link
                navigate={~p"/#{@account}/resources/#{resource}?site_id=#{@group}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= resource.name %>
              </.link>
            </:col>
            <:col :let={resource} label="ADDRESS">
              <%= resource.address %>
            </:col>
            <:empty>
              <div class="flex flex-col items-center justify-center text-center text-slate-500 p-4">
                <div class="pb-4">
                  No resources to display.
                </div>
                <div class="pb-4">
                  <.add_button navigate={~p"/#{@account}/resources/new?site_id=#{@group}"}>
                    Create a Resource
                  </.add_button>
                </div>
                <div>
                  <p>
                    Resources are the endpoints that you want to make available to your clients.
                  </p>
                  <p>
                    Access to them is controlled by Policies.
                  </p>
                </div>
              </div>
            </:empty>
          </.table>
        </div>
      </:content>
    </.section>

    <.danger_zone>
      <:action>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this gateway group and disconnect all it's gateways?"
        >
          Delete Site
        </.delete_button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id}, socket) do
    socket =
      redirect(socket, to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.group}")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    # TODO: make sure tokens are all deleted too!
    {:ok, _group} = Gateways.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/sites")}
  end
end
