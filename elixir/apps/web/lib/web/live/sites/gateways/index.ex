defmodule Web.Sites.Gateways.Index do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    subject = socket.assigns.subject

    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject),
         # TODO: add LIMIT 100 ORDER BY last_seen_at DESC once we support filters
         {:ok, gateways} <-
           Gateways.list_gateways_for_group(group, subject,
             preload: [token: [created_by_identity: [:actor]]]
           ) do
      gateways = Enum.sort_by(gateways, & &1.online?, :desc)
      :ok = Gateways.subscribe_for_gateways_presence_in_group(group)
      {:ok, assign(socket, group: group, gateways: gateways)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}/gateways"}>
        Gateways
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Site <code><%= @group.name %></code> Gateways
      </:title>
      <:help>
        Deploy gateways to terminate connections to your site's resources. All
        gateways deployed within a site must be able to reach all
        its resources.
      </:help>
      <:content>
        <.table id="gateways" rows={@gateways}>
          <:col :let={gateway} label="INSTANCE">
            <.link
              navigate={~p"/#{@account}/gateways/#{gateway.id}"}
              class="font-medium text-accent-600 hover:underline"
            >
              <%= gateway.name %>
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
            <div class="flex flex-col items-center justify-center text-center text-neutral-500 p-4">
              <div class="pb-4">
                No gateways to display.
                <.link
                  class="font-medium text-blue-600 hover:underline"
                  navigate={~p"/#{@account}/sites/#{@group}/new_token"}
                >
                  Deploy a gateway to connect resources.
                </.link>
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id}, socket) do
    subject = socket.assigns.subject

    {:ok, gateways} =
      Gateways.list_gateways_for_group(socket.assigns.group, subject,
        preload: [token: [created_by_identity: [:actor]]]
      )

    {:noreply, assign(socket, gateways: gateways)}
  end
end
