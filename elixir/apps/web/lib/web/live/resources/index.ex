defmodule Web.Resources.Index do
  use Web, :live_view
  alias Domain.{Changes.Change, PubSub, Resource}
  alias __MODULE__.DB

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
        enforce_filters: [
          # The Internet Resource is shown in another section
          {:type, {:not_in, ["internet"]}}
        ],
        callback: &handle_resources_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_resources_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:site])

    with {:ok, resources, metadata} <-
           DB.list_resources(socket.assigns.subject, list_opts),
         {:ok, resource_groups_peek} <-
           DB.peek_resource_groups(resources, 3, socket.assigns.subject) do
      {:ok,
       assign(socket,
         resources: resources,
         resource_groups_peek: resource_groups_peek,
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
          <:col :let={resource} label="Authorized groups" class="w-4/12">
            <.peek peek={Map.fetch!(@resource_groups_peek, resource.id)}>
              <:empty>
                None -
                <.link
                  class={["px-1", link_style()]}
                  navigate={~p"/#{@account}/policies/new?resource_id=#{resource}"}
                >
                  Create a Policy
                </.link>
                to grant access.
              </:empty>

              <:item :let={group}>
                <.group_badge account={@account} group={group} class="mr-2" return_to={@current_path} />
              </:item>

              <:tail :let={count}>
                <span class="inline-block whitespace-nowrap">
                  and {count} more.
                </span>
              </:tail>
            </.peek>
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

    <.section :if={Domain.Account.internet_resource_enabled?(@account)}>
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

  defmodule DB do
    import Ecto.Query
    import Domain.Repo.Query
    alias Domain.{Safe, Resource, Repo, Policy}

    def list_resources(subject, opts \\ []) do
      all()
      |> filter_features(subject.account)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def all do
      from(resources in Resource, as: :resources)
    end

    def filter_features(queryable, %Domain.Account{} = account) do
      if Domain.Account.internet_resource_enabled?(account) do
        queryable
      else
        where(queryable, [resources: resources], resources.type != ^:internet)
      end
    end

    def peek_resource_groups(resources, limit, subject) do
      ids = resources |> Enum.map(& &1.id) |> Enum.uniq()

      {:ok, peek} =
        all()
        |> by_id({:in, ids})
        |> preload_few_groups_for_each_resource(limit)
        |> where(account_id: ^subject.account.id)
        |> Repo.peek(resources)

      group_by_ids =
        Enum.flat_map(peek, fn {_id, %{items: items}} -> items end)
        |> Enum.map(&{&1.id, &1})
        |> Enum.into(%{})

      peek =
        for {id, %{items: items} = map} <- peek, into: %{} do
          {id, %{map | items: Enum.map(items, &Map.fetch!(group_by_ids, &1.id))}}
        end

      {:ok, peek}
    end

    def by_id(queryable, {:in, ids}) do
      where(queryable, [resources: resources], resources.id in ^ids)
    end

    def preload_few_groups_for_each_resource(queryable, limit) do
      queryable
      |> with_joined_groups(limit)
      |> with_joined_policies_counts()
      |> select(
        [resources: resources, groups: groups, policies_counts: policies_counts],
        %{
          id: resources.id,
          count: policies_counts.count,
          item: groups
        }
      )
    end

    def with_joined_groups(queryable, limit) do
      policies_subquery =
        from(p in Policy, as: :policies)
        |> where([policies: p], is_nil(p.disabled_at))
        |> where([policies: policies], policies.resource_id == parent_as(:resources).id)
        |> select([policies: policies], policies.group_id)
        |> limit(^limit)

      groups_subquery =
        from(g in Domain.Group, as: :groups)
        |> where([groups: groups], groups.id in subquery(policies_subquery))

      join(
        queryable,
        :cross_lateral,
        [resources: resources],
        groups in subquery(groups_subquery),
        as: :groups
      )
    end

    def with_joined_policies_counts(queryable) do
      subquery =
        from(p in Policy, as: :policies)
        |> where([policies: p], is_nil(p.disabled_at))
        |> group_by([policies: policies], policies.resource_id)
        |> select([policies: policies], %{
          resource_id: policies.resource_id,
          count: count(policies.id)
        })
        |> where([policies: policies], policies.resource_id == parent_as(:resources).id)

      join(
        queryable,
        :cross_lateral,
        [resources: resources],
        policies_counts in subquery(subquery),
        as: :policies_counts
      )
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
        %Domain.Repo.Filter{
          name: :name_or_address,
          title: "Name or Address",
          type: {:string, :websearch},
          fun: &filter_by_name_fts_or_address/2
        },
        %Domain.Repo.Filter{
          name: :site_id,
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_site_id/2
        },
        %Domain.Repo.Filter{
          name: :type,
          type: {:list, :string},
          fun: &filter_by_type/2
        }
      ]
    end

    def filter_by_name_fts_or_address(queryable, name_or_address) do
      {queryable,
       dynamic(
         [resources: resources],
         fulltext_search(resources.name, ^name_or_address) or
           ilike(resources.address, ^"%#{name_or_address}%")
       )}
    end

    def filter_by_site_id(queryable, site_id) do
      {queryable, dynamic([resources: r], r.site_id == ^site_id)}
    end

    def filter_by_type(queryable, {:not_in, types}) do
      {queryable, dynamic([resources: resources], resources.type not in ^types)}
    end

    def filter_by_type(queryable, types) do
      {queryable, dynamic([resources: resources], resources.type in ^types)}
    end
  end
end
