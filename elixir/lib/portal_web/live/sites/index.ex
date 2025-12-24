defmodule Web.Sites.Index do
  use Web, :live_view
  alias Domain.Presence
  alias __MODULE__.DB
  require Logger

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Presence.Gateways.Account.subscribe(socket.assigns.account.id)
    end

    internet_resource = DB.get_internet_resource(socket.assigns.subject)

    socket =
      socket
      |> assign(page_title: "Sites")
      |> assign(internet_resource: internet_resource)
      |> assign(internet_site: internet_resource.site)
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
    with {:ok, sites, metadata} <- DB.list_sites(socket.assigns.subject, list_opts) do
      site_ids = Enum.map(sites, & &1.id)
      resources_counts = DB.count_resources_by_site(site_ids, socket.assigns.subject)
      policies_counts = DB.count_policies_by_site(site_ids, socket.assigns.subject)

      {:ok,
       assign(socket,
         sites: sites,
         sites_metadata: metadata,
         resources_counts: resources_counts,
         policies_counts: policies_counts
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
            <% count = Map.get(@resources_counts, site.id, 0) %>
            <%= if count == 0 do %>
              None
            <% else %>
              <.link
                navigate={~p"/#{@account}/resources?resources_filter[site_id]=#{site.id}"}
                class={[link_style()]}
              >
                {count} {ngettext("resource", "resources", count)}
              </.link>
            <% end %>
          </:col>

          <:col :let={site} label="policies">
            <% count = Map.get(@policies_counts, site.id, 0) %>
            <%= if count == 0 do %>
              None
            <% else %>
              <.link
                navigate={~p"/#{@account}/policies?policies_filter[site_id]=#{site.id}"}
                class={[link_style()]}
              >
                {count} {ngettext("policy", "policies", count)}
              </.link>
            <% end %>
          </:col>

          <:col :let={site} label="online gateways" class="w-1/6">
            <% count = Presence.Gateways.Site.list(site.id) |> map_size() %>
            <%= if count == 0 do %>
              <span class="flex items-center">
                <.icon
                  name="hero-exclamation-triangle-solid"
                  class="inline-block w-3.5 h-3.5 mr-1 text-red-500"
                /> None
              </span>
            <% else %>
              <.link navigate={~p"/#{@account}/sites/#{site}"} class={[link_style()]}>
                {count} {ngettext("gateway", "gateways", count)}
              </.link>
            <% end %>
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
    internet_resource = DB.get_internet_resource(socket.assigns.subject)

    socket =
      socket
      |> assign(internet_resource: internet_resource)
      |> assign(internet_site: internet_resource.site)
      |> reload_live_table!("sites")

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Site, Resource}

    def list_sites(subject, opts \\ []) do
      from(g in Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def count_resources_by_site(site_ids, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count(r.id)})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    def count_policies_by_site(site_ids, subject) do
      from(p in Domain.Policy, as: :policies)
      |> join(:inner, [policies: p], r in Resource, on: r.id == p.resource_id, as: :resources)
      |> where([resources: r], r.site_id in ^site_ids)
      |> group_by([resources: r], r.site_id)
      |> select([resources: r], {r.site_id, count()})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    def get_internet_resource(subject) do
      resource =
        from(r in Resource, as: :resources)
        |> where([resources: r], r.type == :internet)
        |> preload(site: :gateways)
        |> Safe.scoped(subject)
        |> Safe.one()

      case resource do
        nil ->
          nil

        resource ->
          gateways = Presence.Gateways.preload_gateways_presence(resource.site.gateways)
          put_in(resource.site.gateways, gateways)
      end
    end

    def cursor_fields,
      do: [
        {:sites, :asc, :inserted_at},
        {:sites, :asc, :id}
      ]

    def filters do
      [
        %Domain.Repo.Filter{
          name: :managed_by,
          type: :string,
          fun: &filter_managed_by/2
        }
      ]
    end

    def filter_managed_by(queryable, value) do
      {queryable, dynamic([sites: sites], sites.managed_by == ^value)}
    end
  end
end
