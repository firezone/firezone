defmodule PortalWeb.Resources.Index do
  use PortalWeb, :live_view
  alias Portal.{Changes.Change, PubSub, Resource}
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = PubSub.Account.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(stale: false)
      |> assign(page_title: "Resources")
      |> assign_live_table("resources",
        query_module: DB,
        sortable_fields: [
          {:resources, :name},
          {:resources, :address}
        ],
        callback: &handle_resources_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"resources_filter" => %{"site_id" => site_id}} = params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    filter_site = Database.get_site(site_id, socket.assigns.subject)
    {:noreply, assign(socket, filter_site: filter_site)}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, assign(socket, filter_site: nil)}
  end

  def handle_resources_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:site])

    with {:ok, resources, metadata} <-
           Database.list_resources(socket.assigns.subject, list_opts) do
      resource_policy_counts =
        Database.count_policies_for_resources(resources, socket.assigns.subject)

      {:ok,
       assign(socket,
         resources: resources,
         resource_policy_counts: resource_policy_counts,
         resources_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Resources
      </:title>
      <:help>
        <p class="mb-2">
          Resources define the subnets, hosts, and applications for which you want to manage access. You can manage Resources per Site
          in the <.link navigate={~p"/#{@account}/sites"} class={link_style()}>Sites</.link> section.
        </p>
      </:help>
      <:action>
        <.docs_action path="/deploy/resources" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/resources/new"}>
          Add Resource
        </.add_button>
      </:action>
      <:content>
        <.live_table
          stale={@stale}
          id="resources"
          rows={@resources}
          row_id={&"resource-#{&1.id}"}
          filters={@filters_by_table_id["resources"]}
          filter={@filter_form_by_table_id["resources"]}
          ordered_by={@order_by_table_id["resources"]}
          metadata={@resources_metadata}
        >
          <:notice :if={@filter_site} type="info">
            Viewing Resources for Site <strong>{@filter_site.name}</strong>.
            <.link navigate={~p"/#{@account}/resources"} class={link_style()}>
              View all resources
            </.link>
          </:notice>
          <:col :let={resource} field={{:resources, :name}} label="Name">
            <.link navigate={~p"/#{@account}/resources/#{resource.id}"} class={link_style()}>
              {resource.name}
            </.link>
          </:col>
          <:col :let={resource} field={{:resources, :address}} label="Address">
            <code :if={resource.type != :internet} class="block text-xs">
              {resource.address}
            </code>
            <span :if={resource.type == :internet} class="block text-xs">
              <code>0.0.0.0/0</code>, <code>::/0 </code>
            </span>
          </:col>
          <:col :let={resource} label="site">
            <.link
              :if={resource.site}
              navigate={~p"/#{@account}/sites/#{resource.site}"}
              class={link_style()}
            >
              <.badge type="info">
                {resource.site.name}
              </.badge>
            </.link>
          </:col>
          <:col :let={resource} label="Policies" class="w-2/12">
            <% count = Map.get(@resource_policy_counts, resource.id, 0) %>
            <%= if count == 0 do %>
              <.link
                class={link_style()}
                navigate={~p"/#{@account}/policies/new?resource_id=#{resource}"}
              >
                Create a Policy
              </.link>
            <% else %>
              <.link
                class={link_style()}
                navigate={~p"/#{@account}/policies?policies_filter[resource_id]=#{resource.id}"}
              >
                {count} {ngettext("policy", "policies", count)}
              </.link>
            <% end %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto">
                <div class="pb-4">
                  No resources to display
                </div>
                <.add_button navigate={~p"/#{@account}/resources/new"}>
                  Add Resource
                </.add_button>
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section :if={Portal.Account.internet_resource_enabled?(@account)}>
      <:title>
        Internet
      </:title>
      <:help>
        The Internet Resource is a special resource that matches all traffic not matched by any other resource.
      </:help>
      <:action>
        <.button id="view-internet-resource" navigate={~p"/#{@account}/resources/internet"}>
          View Internet Resource
        </.button>
      </:action>
      <:content></:content>
    </.section>
    """
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "reload"],
      do: handle_live_table_event(event, params, socket)

  def handle_info(%Change{old_struct: %Resource{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info(%Change{struct: %Resource{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Resource, Policy, Site}

    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def list_resources(subject, opts \\ []) do
      from(resources in Resource, as: :resources)
      |> where([resources: r], r.type != :internet)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def count_policies_for_resources(resources, subject) do
      ids = resources |> Enum.map(& &1.id) |> Enum.uniq()

      from(p in Policy, as: :policies)
      |> where([policies: p], p.resource_id in ^ids)
      |> where([policies: p], is_nil(p.disabled_at))
      |> group_by([policies: p], p.resource_id)
      |> select([policies: p], {p.resource_id, count(p.id)})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> %{}
        counts -> Map.new(counts)
      end
    end

    def cursor_fields do
      [
        {:resources, :asc, :name},
        {:resources, :asc, :inserted_at},
        {:resources, :asc, :id}
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name_or_address,
          title: "Name or Address",
          type: {:string, :websearch},
          fun: &filter_by_name_fts_or_address/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_site_id/2
        }
      ]
    end

    def filter_by_name_fts_or_address(queryable, name_or_address) do
      {queryable,
       dynamic(
         [resources: resources],
         fulltext_search(resources.name, ^name_or_address) or
           fulltext_search(resources.address, ^name_or_address)
       )}
    end

    def filter_by_site_id(queryable, site_id) do
      {queryable, dynamic([resources: r], r.site_id == ^site_id)}
    end
  end
end
