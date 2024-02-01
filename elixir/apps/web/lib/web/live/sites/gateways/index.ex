defmodule Web.Sites.Gateways.Index do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    subject = socket.assigns.subject

    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject),
         # TODO: add LIMIT 100 ORDER BY last_seen_at DESC once we support filters
         {:ok, gateways} <-
           Gateways.list_gateways_for_group(group, subject) do
      gateways = Enum.sort_by(gateways, & &1.online?, :desc)
      :ok = Gateways.subscribe_to_gateways_presence_in_group(group)
      socket = assign(socket, group: group, gateways: gateways, page_title: "Site Gateways")
      {:ok, socket}
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
            <.link navigate={~p"/#{@account}/gateways/#{gateway.id}"} class={[link_style()]}>
              <%= gateway.name %>
            </.link>
          </:col>
          <:col :let={gateway} label="REMOTE IP">
            <code>
              <%= gateway.last_seen_remote_ip %>
            </code>
          </:col>
          <:col :let={gateway} label="STATUS">
            <.connection_status schema={gateway} />
          </:col>
          <:empty>
            <div class="flex flex-col items-center justify-center text-center text-neutral-500 p-4">
              <div class="pb-4">
                No gateways to display.
                <.link class={[link_style()]} navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
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

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _group_id},
        socket
      ) do
    subject = socket.assigns.subject

    {:ok, gateways} =
      Gateways.list_gateways_for_group(socket.assigns.group, subject,
        preload: [token: [created_by_identity: [:actor]]]
      )

    {:noreply, assign(socket, gateways: gateways)}
  end
end
