defmodule PortalWeb.Policies.Index do
  use PortalWeb, :live_view
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(stale: false)
      |> assign(page_title: "Policies")
      |> assign_live_table("policies",
        query_module: Database,
        sortable_fields: [],
        hide_filters: [
          :group_id,
          :group_name,
          :resource_id,
          :resource_name,
          :site_id
        ],
        callback: &handle_policies_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"policies_filter" => %{"site_id" => site_id}} = params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    filter_site = Database.get_site(site_id, socket.assigns.subject)

    {:noreply,
     assign(socket, filter_site: filter_site, filter_resource: nil, return_to: uri_path(uri))}
  end

  def handle_params(%{"policies_filter" => %{"resource_id" => resource_id}} = params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    filter_resource = Database.get_resource(resource_id, socket.assigns.subject)

    {:noreply,
     assign(socket, filter_site: nil, filter_resource: filter_resource, return_to: uri_path(uri))}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, assign(socket, filter_site: nil, filter_resource: nil, return_to: uri_path(uri))}
  end

  defp uri_path(uri) do
    parsed = URI.parse(uri)
    "#{parsed.path}?#{parsed.query}"
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, group: [], resource: [])

    with {:ok, policies, metadata} <- Database.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>{@page_title}</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:action>
        <.docs_action path="/deploy/policies" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/policies/new"}>
          Add Policy
        </.add_button>
      </:action>
      <:help>
        Policies grant access to Resources.
      </:help>
      <:content>
        <.live_table
          stale={@stale}
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
        >
          <:notice :if={@filter_site} type="info">
            Viewing Policies for Site <strong>{@filter_site.name}</strong>.
            <.link navigate={~p"/#{@account}/policies"} class={link_style()}>
              View all policies
            </.link>
          </:notice>
          <:notice :if={@filter_resource} type="info">
            Viewing Policies for Resource <strong>{@filter_resource.name}</strong>.
            <.link navigate={~p"/#{@account}/policies"} class={link_style()}>
              View all policies
            </.link>
          </:notice>
          <:col :let={policy} label="id" class="w-3/12">
            <.link class={link_style()} navigate={~p"/#{@account}/policies/#{policy}"}>
              <span class="block truncate">
                {policy.id}
              </span>
            </.link>
          </:col>
          <:col :let={policy} label="group" class="w-3/12">
            <.group_badge account={@account} group={policy.group} return_to={@return_to} />
          </:col>
          <:col :let={policy} label="resource" class="w-2/12">
            <.link class={link_style()} navigate={~p"/#{@account}/resources/#{policy.resource_id}"}>
              {policy.resource.name}
            </.link>
          </:col>
          <:col :let={policy} label="status">
            <%= if is_nil(policy.disabled_at) do %>
              <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
                Active
              </span>
            <% else %>
              <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
                Disabled
              </span>
            <% end %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="pb-4 w-auto">
                No policies to display.
                <.link class={[link_style()]} navigate={~p"/#{@account}/policies/new"}>
                  Add a policy
                </.link>
                to grant access to Resources.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "reload"],
      do: handle_live_table_event(event, params, socket)

  def handle_info(%Change{old_struct: %Portal.Policy{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info(%Change{struct: %Portal.Policy{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Policy, Site, Resource}

    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_resource(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def list_policies(subject, opts \\ []) do
      from(p in Policy, as: :policies)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    # Pagination support
    def cursor_fields,
      do: [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :resource_id,
          title: "Resource",
          type: {:string, :uuid},
          fun: &filter_by_resource_id/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
          name: :group_id,
          title: "Group",
          type: {:string, :uuid},
          fun: &filter_by_group_id/2
        },
        %Portal.Repo.Filter{
          name: :group_name,
          title: "Group Name",
          type: {:string, :websearch},
          fun: &filter_by_group_name/2
        },
        %Portal.Repo.Filter{
          name: :resource_name,
          title: "Resource Name",
          type: {:string, :websearch},
          fun: &filter_by_resource_name/2
        },
        %Portal.Repo.Filter{
          name: :group_or_resource,
          title: "Group or Resource",
          type: {:string, :websearch},
          fun: &filter_by_group_or_resource/2
        },
        %Portal.Repo.Filter{
          name: :status,
          title: "Status",
          type: :string,
          values: [
            {"Active", "active"},
            {"Disabled", "disabled"}
          ],
          fun: &filter_by_status/2
        }
      ]
    end

    def filter_by_resource_id(queryable, resource_id) do
      {queryable, dynamic([policies: p], p.resource_id == ^resource_id)}
    end

    def filter_by_site_id(queryable, site_id) do
      queryable = with_joined_resource(queryable)
      {queryable, dynamic([resource: r], r.site_id == ^site_id)}
    end

    def filter_by_group_id(queryable, group_id) do
      {queryable, dynamic([policies: p], p.group_id == ^group_id)}
    end

    def filter_by_group_name(queryable, name) do
      queryable = with_joined_group(queryable)
      {queryable, dynamic([group: g], fulltext_search(g.name, ^name))}
    end

    def filter_by_resource_name(queryable, name) do
      queryable = with_joined_resource(queryable)
      {queryable, dynamic([resource: r], fulltext_search(r.name, ^name))}
    end

    def filter_by_group_or_resource(queryable, search_term) do
      queryable = queryable |> with_joined_group() |> with_joined_resource()

      {queryable,
       dynamic(
         [group: g, resource: r],
         fulltext_search(g.name, ^search_term) or
           fulltext_search(r.name, ^search_term) or
           fulltext_search(r.address, ^search_term)
       )}
    end

    def filter_by_status(queryable, "active") do
      {queryable, dynamic([policies: p], is_nil(p.disabled_at))}
    end

    def filter_by_status(queryable, "disabled") do
      {queryable, dynamic([policies: p], not is_nil(p.disabled_at))}
    end

    defp with_joined_group(queryable) do
      if has_named_binding?(queryable, :group) do
        queryable
      else
        join(queryable, :inner, [policies: p], g in assoc(p, :group), as: :group)
      end
    end

    defp with_joined_resource(queryable) do
      if has_named_binding?(queryable, :resource) do
        queryable
      else
        join(queryable, :inner, [policies: p], r in assoc(p, :resource), as: :resource)
      end
    end
  end
end
