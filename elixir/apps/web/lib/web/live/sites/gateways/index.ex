defmodule Web.Sites.Gateways.Index do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- Gateways.fetch_group_by_id(id, socket.assigns.subject) do
      if connected?(socket) do
        :ok = Gateways.subscribe_to_gateways_presence_in_group(group)
      end

      socket =
        socket
        |> assign(
          page_title: "Site Gateways",
          group: group
        )
        |> assign_live_table("gateways",
          query_module: Gateways.Gateway.Query,
          enforce_filters: [
            {:gateway_group_id, group.id}
          ],
          sortable_fields: [
            {:gateways, :name},
            {:gateways, :last_seen_at}
          ],
          callback: &handle_gateways_update!/2
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

  def handle_gateways_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:online?])

    with {:ok, gateways, metadata} <- Gateways.list_gateways(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         gateways: gateways,
         gateways_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        {@group.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}/gateways"}>
        Gateways
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Site <code>{@group.name}</code> Gateways
      </:title>
      <:help :if={@group.managed_by == :system and @group.name == "Internet"}>
        Gateways deployed to the Internet Site will be used for full-route tunneling
        of traffic that doesn't match a more specific Resource.
      </:help>
      <:help :if={is_nil(@group.deleted_at) and @group.managed_by == :account}>
        Deploy gateways to terminate connections to your site's resources. All
        gateways deployed within a site must be able to reach all
        its resources.
      </:help>
      <:content>
        <.live_table
          id="gateways"
          rows={@gateways}
          filters={@filters_by_table_id["gateways"]}
          filter={@filter_form_by_table_id["gateways"]}
          ordered_by={@order_by_table_id["gateways"]}
          metadata={@gateways_metadata}
        >
          <:col :let={gateway} field={{:gateways, :name}} label="instance">
            <.link navigate={~p"/#{@account}/gateways/#{gateway.id}"} class={[link_style()]}>
              {gateway.name}
            </.link>
          </:col>
          <:col :let={gateway} label="remote ip">
            <code>
              {gateway.last_seen_remote_ip}
            </code>
          </:col>
          <:col :let={gateway} label="version">
            {gateway.last_seen_version}
          </:col>
          <:col :let={gateway} label="status">
            <.connection_status schema={gateway} />
          </:col>
          <:empty>
            <div class="flex flex-col items-center justify-center text-center text-neutral-500 p-4">
              <div class="pb-4">
                No gateways to display.
                <span :if={@group.managed_by == :system and @group.name == "Internet"}>
                  <.link class={[link_style()]} navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
                    Deploy a Gateway to the Internet Site.
                  </.link>
                </span>
                <span :if={is_nil(@group.deleted_at) and @group.managed_by == :account}>
                  <.link class={[link_style()]} navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
                    Deploy a Gateway to connect Resources.
                  </.link>
                </span>
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _group_id} = event,
        socket
      ) do
    rendered_gateway_ids = Enum.map(socket.assigns.gateways, & &1.id)

    if presence_updates_any_id?(event, rendered_gateway_ids) do
      socket = reload_live_table!(socket, "gateways")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)
end
