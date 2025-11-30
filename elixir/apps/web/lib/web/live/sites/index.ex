defmodule Web.Sites.Index do
  use Web, :live_view
  alias Domain.Gateways
  alias __MODULE__.DB
  require Logger

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Gateways.Presence.Account.subscribe(socket.assigns.account.id)
    end

    {:ok, managed_sites, _metadata} =
      DB.list_sites(socket.assigns.subject,
        preload: [
          gateways: [:online?]
        ],
        filter: [
          managed_by: "system"
        ]
      )

    {internet_resource, existing_site_name} =
      with {:ok, internet_resource} <-
             DB.fetch_internet_resource(socket.assigns.subject),
           internet_resource =
             Domain.Repo.preload(internet_resource, connections: :site),
           connection when not is_nil(connection) <-
             Enum.find(internet_resource.connections, fn connection ->
               connection.site.name != "Internet" &&
                 connection.site.managed_by != "system"
             end) do
        {internet_resource, connection.site.name}
      else
        _ -> {nil, nil}
      end

    internet_site = Enum.find(managed_sites, fn site -> site.name == "Internet" end)

    socket =
      socket
      |> assign(page_title: "Sites")
      |> assign(internet_resource: internet_resource)
      |> assign(existing_internet_resource_site_name: existing_site_name)
      |> assign(internet_site: internet_site)
      |> assign_live_table("sites",
        query_module: DB,
        sortable_fields: [
          {:sites, :name}
        ],
        enforce_filters: [
          {:managed_by, "account"}
        ],
        callback: &handle_sites_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_sites_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, gateways: [:online?], connections: [:resource])

    with {:ok, sites, metadata} <-
           DB.list_sites(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         sites: sites,
         sites_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Sites
      </:title>

      <:action>
        <.docs_action path="/deploy/sites" />
      </:action>

      <:action>
        <.add_button navigate={~p"/#{@account}/sites/new"}>
          Add Site
        </.add_button>
      </:action>

      <:help>
        Sites represent a shared network environment that Gateways and Resources exist within.
      </:help>

      <:content>
        <.live_table
          id="sites"
          rows={@sites}
          row_id={&"site-#{&1.id}"}
          filters={@filters_by_table_id["sites"]}
          filter={@filter_form_by_table_id["sites"]}
          ordered_by={@order_by_table_id["sites"]}
          metadata={@sites_metadata}
        >
          <:col :let={site} field={{:sites, :name}} label="site" class="w-1/6">
            <.link navigate={~p"/#{@account}/sites/#{site}"} class={[link_style()]}>
              {site.name}
            </.link>
          </:col>

          <:col :let={site} label="resources">
            <% connections = Enum.reject(site.connections, &is_nil(&1.resource))
            peek = %{count: length(connections), items: Enum.take(connections, 5)} %>
            <.peek peek={peek}>
              <:empty>
                None
              </:empty>

              <:separator>
                <span class="pr-1">,</span>
              </:separator>

              <:item :let={connection}>
                <.link
                  navigate={
                    ~p"/#{@account}/resources/#{connection.resource}?site_id=#{connection.site_id}"
                  }
                  class={["inline-block", link_style()]}
                  phx-no-format
                ><%= connection.resource.name %></.link>
              </:item>

              <:tail :let={count}>
                <span class="pl-1">
                  and
                  <.link
                    navigate={~p"/#{@account}/sites/#{site}?#resources"}
                    class={["font-medium", link_style()]}
                  >
                    {count} more.
                  </.link>
                </span>
              </:tail>
            </.peek>
          </:col>

          <:col :let={site} label="online gateways" class="w-1/6">
            <% gateways = Enum.filter(site.gateways, & &1.online?)
            peek = %{count: length(gateways), items: Enum.take(gateways, 5)} %>
            <.peek peek={peek}>
              <:empty>
                <span class="justify flex items-center">
                  <.icon
                    name="hero-exclamation-triangle-solid"
                    class="inline-block w-3.5 h-3.5 mr-1 text-red-500"
                  /> None
                </span>
              </:empty>

              <:separator>
                <span class="pr-1">,</span>
              </:separator>

              <:item :let={gateway}>
                <.link
                  navigate={~p"/#{@account}/gateways/#{gateway}"}
                  class={["inline-block", link_style()]}
                  phx-no-format
                ><%= gateway.name %></.link>
              </:item>

              <:tail :let={count}>
                <span class="pl-1">
                  and
                  <.link
                    navigate={~p"/#{@account}/sites/#{site}?#gateways"}
                    class={["font-medium", link_style()]}
                  >
                    {count} more.
                  </.link>
                </span>
              </:tail>
            </.peek>
          </:col>

          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No sites to display.
                <.link class={[link_style()]} navigate={~p"/#{@account}/sites/new"}>
                  Add a site
                </.link>
                to start deploying gateways and adding resources.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section :if={@internet_site} id="internet-site-banner">
      <:title>
        <div class="flex items-center space-x-2.5">
          <span>Internet</span>

          <% online? = Enum.any?(@internet_site.gateways, & &1.online?) %>

          <.ping_icon
            :if={Domain.Account.internet_resource_enabled?(@account)}
            color={if online?, do: "success", else: "danger"}
            title={if online?, do: "Online", else: "Offline"}
          />

          <.link
            :if={not Domain.Account.internet_resource_enabled?(@account)}
            navigate={~p"/#{@account}/settings/billing"}
            class="text-sm text-primary-500"
          >
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
            </.badge>
          </.link>
        </div>
      </:title>

      <:action>
        <.docs_action path="/deploy/resources" fragment="the-internet-resource" />
      </:action>

      <:action :if={Domain.Account.internet_resource_enabled?(@account)}>
        <.edit_button navigate={~p"/#{@account}/sites/#{@internet_site}"}>
          Manage Internet Site
        </.edit_button>
      </:action>

      <:help>
        Use the Internet Site to manage secure, private access to the public internet for your workforce.
      </:help>
      <:content></:content>
    </.section>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _account_id},
        socket
      ) do
    {:ok, managed_sites, _metadata} =
      DB.list_sites(socket.assigns.subject,
        preload: [
          gateways: [:online?]
        ],
        filter: [
          managed_by: "system"
        ]
      )

    internet_resource =
      case DB.fetch_internet_resource(socket.assigns.subject) do
        {:ok, internet_resource} -> Domain.Repo.preload(internet_resource, :connections)
        _ -> nil
      end

    internet_site = Enum.find(managed_sites, fn site -> site.name == "Internet" end)

    socket =
      socket
      |> assign(internet_resource: internet_resource)
      |> assign(internet_site: internet_site)
      |> reload_live_table!("sites")

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Site
    alias Domain.Resource

    def list_sites(subject, opts \\ []) do
      from(g in Site, as: :sites)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_internet_resource(subject) do
      result =
        from(r in Resource, as: :resources)
        |> where([resources: r], r.type == :internet)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
    end

    def cursor_fields,
      do: [
        {:sites, :asc, :inserted_at},
        {:sites, :asc, :id}
      ]

    def preloads,
      do: [
        gateways: [
          online?: &Domain.Gateways.Presence.preload_gateways_presence/1
        ]
      ]
  end
end
