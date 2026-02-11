defmodule PortalWeb.Sites.Gateways.Index do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(%{"id" => id}, _session, socket) do
    site = Database.get_site!(id, socket.assigns.subject)

    if connected?(socket) do
      :ok = Portal.Presence.Gateways.Site.subscribe(site.id)
    end

    socket =
      socket
      |> assign(
        page_title: "Site Gateways",
        site: site
      )
      |> assign_live_table("gateways",
        query_module: Database,
        enforce_filters: [
          {:site_id, site.id}
        ],
        sortable_fields: [
          {:gateways, :name},
          {:gateways, :last_seen_at}
        ],
        callback: &handle_gateways_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_gateways_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:online?])

    with {:ok, gateways, metadata} <- Database.list_gateways(socket.assigns.subject, list_opts) do
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
      <.breadcrumb path={~p"/#{@account}/sites/#{@site}"}>
        {@site.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@site}/gateways"}>
        Gateways
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Site <code>{@site.name}</code> Gateways
      </:title>
      <:help :if={@site.managed_by == :system and @site.name == "Internet"}>
        Gateways deployed to the Internet Site will be used for full-route tunneling
        of traffic that doesn't match a more specific Resource.
      </:help>
      <:help :if={@site.managed_by == :account}>
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
                <span :if={@site.managed_by == :system and @site.name == "Internet"}>
                  <.link class={[link_style()]} navigate={~p"/#{@account}/sites/#{@site}/new_token"}>
                    Deploy a Gateway to the Internet Site.
                  </.link>
                </span>
                <span :if={@site.managed_by == :account}>
                  <.link class={[link_style()]} navigate={~p"/#{@account}/sites/#{@site}/new_token"}>
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
        %Phoenix.Socket.Broadcast{topic: "presences:sites:" <> _site_id} = event,
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

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, Gateway}

    def get_site!(id, subject) do
      from(s in Portal.Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def list_gateways(subject, opts \\ []) do
      from(g in Gateway, as: :gateways)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:gateways, :asc, :name},
        {:gateways, :asc, :last_seen_at},
        {:gateways, :asc, :id}
      ]
    end

    def preloads do
      [
        online?: &Portal.Presence.Gateways.preload_gateways_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_site_id/2
        }
      ]
    end

    def filter_by_site_id(queryable, site_id) do
      {queryable, dynamic([gateways: gateways], gateways.site_id == ^site_id)}
    end
  end
end
