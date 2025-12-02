defmodule Web.Sites.Show do
  use Web, :live_view
  alias Domain.Safe
  alias __MODULE__.DB

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, site} <-
           DB.fetch_site(id, socket.assigns.subject) do
      if connected?(socket) do
        :ok = Domain.Presence.Gateways.Site.subscribe(site.id)
      end

      socket =
        socket
        |> assign(
          page_title: "Site #{site.name}",
          site: site
        )

      mount_page(socket, site)
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp mount_page(socket, %{managed_by: :system, name: "Internet"} = site) do
    with {:ok, resource} <- DB.fetch_internet_resource(socket.assigns.subject) do
      resource = Domain.Repo.preload(resource, :sites)

      socket =
        socket
        |> assign(resource: resource)
        |> assign_live_table("gateways",
          query_module: DB,
          enforce_filters: [
            {:site_id, site.id}
          ],
          sortable_fields: [
            {:gateways, :last_seen_at}
          ],
          callback: &handle_gateways_update!/2
        )
        |> assign_live_table("flows",
          query_module: DB.FlowQuery,
          sortable_fields: [],
          callback: &handle_flows_update!/2
        )
        |> assign_live_table("policies",
          query_module: DB.PolicyQuery,
          hide_filters: [
            :group_id,
            :resource_name,
            :group_or_resource_name
          ],
          enforce_filters: [
            {:resource_id, resource.id}
          ],
          sortable_fields: [],
          callback: &handle_policies_update!/2
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp mount_page(socket, site) do
    socket =
      socket
      |> assign_live_table("gateways",
        query_module: DB,
        enforce_filters: [
          {:site_id, site.id}
        ],
        sortable_fields: [
          {:gateways, :last_seen_at}
        ],
        callback: &handle_gateways_update!/2
      )
      |> assign_live_table("resources",
        query_module: DB.ResourceQuery,
        enforce_filters: [
          {:site_id, site.id}
        ],
        sortable_fields: [
          {:resources, :name},
          {:resources, :address}
        ],
        callback: &handle_resources_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_gateways_update!(socket, list_opts) do
    online_ids = Domain.Presence.Gateways.Site.list(socket.assigns.site.id) |> Map.keys()

    list_opts =
      list_opts
      |> Keyword.put(:preload, [:online?])
      |> Keyword.update(:filter, [], fn filter ->
        filter ++ [{:ids, online_ids}]
      end)

    with {:ok, gateways, metadata} <- DB.list_gateways(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         gateways: gateways,
         gateways_metadata: metadata
       )}
    end
  end

  def handle_resources_update!(socket, list_opts) do
    with {:ok, resources, metadata} <-
           DB.list_resources(socket.assigns.subject, list_opts),
         {:ok, resource_groups_peek} <-
           DB.peek_resource_groups(resources, 3, socket.assigns.subject) do
      {:ok,
       assign(socket,
         resources: resources,
         resources_metadata: metadata,
         resource_groups_peek: resource_groups_peek
       )}
    end
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, group: [], resource: [])

    with {:ok, policies, metadata} <- DB.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def handle_flows_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:site],
        policy: [:resource, :actor_site]
      )

    with {:ok, flows, metadata} <-
           DB.list_flows_for(socket.assigns.resource, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         flows: flows,
         flows_metadata: metadata
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
    </.breadcrumbs>

    <.section>
      <:title>
        Site: <code>{@site.name}</code>
      </:title>

      <:action :if={@site.managed_by == :account}>
        <.edit_button navigate={~p"/#{@account}/sites/#{@site}/edit"}>
          Edit Site
        </.edit_button>
      </:action>

      <:help :if={@site.managed_by == :system and @site.name == "Internet"}>
        Use this Site to manage secure, private access to the public internet for your workforce.
      </:help>

      <:content :if={@site.managed_by != :system and @site.name != "Internet"}>
        <.vertical_table id="site">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@site.name}</:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Online Gateways
        <.link class={["text-sm", link_style()]} navigate={~p"/#{@account}/sites/#{@site}/gateways"}>
          see all <.icon name="hero-arrow-right" class="w-2 h-2" />
        </.link>
      </:title>
      <:action>
        <.docs_action path="/deploy/gateways" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/sites/#{@site}/new_token"}>
          Deploy Gateway
        </.add_button>
      </:action>
      <:action>
        <.button_with_confirmation
          id="revoke_all_tokens"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="revoke_all_tokens"
        >
          <:dialog_title>Confirm revocation of all tokens</:dialog_title>
          <:dialog_content>
            Are you sure you want to revoke all tokens for this Site?
            This will <strong>immediately</strong> disconnect all associated Gateways.
          </:dialog_content>
          <:dialog_confirm_button>
            Revoke All
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Revoke All
        </.button_with_confirmation>
      </:action>
      <:help :if={@site.managed_by == :system and @site.name == "Internet"}>
        Gateways deployed to the Internet Site are used to tunnel all traffic that doesn't match any specific Resource.
      </:help>
      <:help :if={@site.managed_by == :account}>
        Deploy gateways to terminate connections to your site's resources. All
        gateways deployed within a site must be able to reach all
        its resources.
      </:help>
      <:content flash={@flash}>
        <.flash :if={@gateways_metadata.count == 1} kind={:info} style="wide" class="mb-2">
          Deploy at least one more gateway to ensure
          <span class="inline-flex">
            <.website_link path="/kb/deploy/gateways" fragment="deploy-multiple-gateways">
              high availability
            </.website_link>.
          </span>
        </.flash>

        <div class="relative overflow-x-auto">
          <.live_table
            id="gateways"
            rows={@gateways}
            filters={@filters_by_table_id["gateways"]}
            filter={@filter_form_by_table_id["gateways"]}
            ordered_by={@order_by_table_id["gateways"]}
            metadata={@gateways_metadata}
          >
            <:col :let={gateway} label="instance">
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
              <.version_status outdated={Domain.Gateway.gateway_outdated?(gateway)} />
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
                    <.link
                      class={[link_style()]}
                      navigate={~p"/#{@account}/sites/#{@site}/new_token"}
                    >
                      Deploy a Gateway to the Internet Site.
                    </.link>
                  </span>
                  <span :if={@site.managed_by == :account}>
                    <.link
                      class={[link_style()]}
                      navigate={~p"/#{@account}/sites/#{@site}/new_token"}
                    >
                      Deploy a gateway to connect resources.
                    </.link>
                  </span>
                </div>
              </div>
            </:empty>
          </.live_table>
        </div>
      </:content>
    </.section>

    <.section :if={@site.managed_by == :account}>
      <:title>
        Resources
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/resources/new?site_id=#{@site}"}>
          Add Resource
        </.add_button>
      </:action>
      <:help>
        Resources are the subnets, hosts, and applications that you wish to manage access to.
      </:help>
      <:content>
        <div class="relative overflow-x-auto">
          <.live_table
            id="resources"
            rows={@resources}
            filters={@filters_by_table_id["resources"]}
            filter={@filter_form_by_table_id["resources"]}
            ordered_by={@order_by_table_id["resources"]}
            metadata={@resources_metadata}
          >
            <:col :let={resource} label="name" field={{:resources, :name}}>
              <.link
                navigate={~p"/#{@account}/resources/#{resource}?site_id=#{@site}"}
                class={[link_style()]}
              >
                {resource.name}
              </.link>
            </:col>
            <:col :let={resource} label="address" field={{:resources, :address}}>
              <code class="block text-xs">
                {resource.address}
              </code>
            </:col>
            <:col :let={resource} label="Authorized groups">
              <.peek peek={Map.fetch!(@resource_groups_peek, resource.id)}>
                <:empty>
                  <div class="mr-1">
                    <.icon
                      name="hero-exclamation-triangle-solid"
                      class="inline-block w-3.5 h-3.5 text-red-500"
                    /> None.
                  </div>
                  <.link
                    class={[link_style(), "mr-1"]}
                    navigate={~p"/#{@account}/policies/new?resource_id=#{resource}&site_id=#{@site}"}
                  >
                    Create a Policy
                  </.link>
                  to grant access.
                </:empty>

                <:item :let={group}>
                  <.group_badge account={@account} group={group} return_to={@current_path} />
                </:item>

                <:tail :let={count}>
                  <span class="inline-block whitespace-nowrap">
                    and {count} more.
                  </span>
                </:tail>
              </.peek>
            </:col>
            <:empty>
              <div class="flex flex-col items-center justify-center text-center text-neutral-500 p-4">
                <div class="pb-4">
                  No resources to display.
                </div>
              </div>
            </:empty>
          </.live_table>
        </div>
      </:content>
    </.section>

    <.section :if={@site.managed_by == :system and @site.name == "Internet"}>
      <:title>
        Policies
      </:title>
      <:action>
        <.add_button navigate={
          ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{@site}"
        }>
          Add Policy
        </.add_button>
      </:action>
      <:content>
        <.live_table
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
        >
          <:col :let={policy} label="id">
            <.link class={link_style()} navigate={~p"/#{@account}/policies/#{policy}"}>
              {policy.id}
            </.link>
          </:col>
          <:col :let={policy} label="group">
            <.group_badge account={@account} group={policy.group} return_to={@current_path} />
          </:col>
          <:col :let={policy} label="status">
            <%= if is_nil(policy.disabled_at) do %>
              Active
            <% else %>
              Disabled
            <% end %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="pb-4 w-auto">
                <.icon
                  name="hero-exclamation-triangle-solid"
                  class="inline-block w-3.5 h-3.5 mr-1 text-red-500"
                /> No policies to display.
                <.link
                  class={[link_style()]}
                  navigate={~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{@site}"}
                >
                  Add a policy
                </.link>
                to configure access to the internet.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={@site.managed_by == :account}>
      <:action>
        <.button_with_confirmation
          id="delete_site"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of Site</:dialog_title>
          <:dialog_content>
            Are you sure you want to delete this Site? This will <strong>immediately</strong>
            disconnect all associated Gateways.
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Site
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Site
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:sites:" <> _site_id},
        socket
      ) do
    {:noreply, reload_live_table!(socket, "gateways")}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("revoke_all_tokens", _params, socket) do
    # Only account admins can delete site tokens
    deleted_token_count =
      if socket.assigns.subject.actor.type == :account_admin_user do
        import Ecto.Query

        query = from(t in Domain.Token, where: t.site_id == ^socket.assigns.site.id)
        {count, _} = Safe.scoped(socket.assigns.subject) |> Safe.delete_all(query)
        count
      else
        0
      end

    socket =
      socket
      |> put_flash(:success, "#{deleted_token_count} token(s) were revoked.")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _deleted_site} = DB.delete_site(socket.assigns.site, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites")}
  end

  attr :outdated, :boolean

  defp version_status(assigns) do
    ~H"""
    <.icon
      :if={!@outdated}
      name="hero-check-circle"
      class="w-4 h-4 text-green-500"
      title="Up to date"
    />
    <.icon
      :if={@outdated}
      name="hero-arrow-up-circle"
      class="w-4 h-4 text-primary-500"
      title="New version available"
    />
    """
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Gateway

    def fetch_site(id, subject) do
      result =
        from(g in Domain.Site, as: :sites)
        |> where([sites: g], g.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        site -> {:ok, site}
      end
    end

    def list_gateways(subject, opts \\ []) do
      from(g in Gateway, as: :gateways)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:gateways, :asc, :last_seen_at},
        {:gateways, :asc, :id}
      ]
    end

    def preloads do
      [
        online?: &Domain.Presence.Gateways.preload_gateways_presence/1
      ]
    end

    def filters do
      [
        %Domain.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_site_id/2
        },
        %Domain.Repo.Filter{
          name: :ids,
          type: {:list, {:string, :uuid}},
          fun: &filter_by_ids/2
        }
      ]
    end

    def filter_by_site_id(queryable, site_id) do
      {queryable, dynamic([gateways: gateways], gateways.site_id == ^site_id)}
    end

    def filter_by_ids(queryable, ids) do
      {queryable, dynamic([gateways: gateways], gateways.id in ^ids)}
    end

    def delete_site(site, subject) do
      Safe.scoped(site, subject)
      |> Safe.delete()
    end

    def fetch_internet_resource(subject) do
      result =
        from(r in Domain.Resource, as: :resources)
        |> where([resources: r], r.address == "0.0.0.0/0" or r.address == "::/0")
        |> limit(1)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
    end

    def list_resources(subject, opts \\ []) do
      from(r in Domain.Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(DB.ResourceQuery, opts)
    end

    def peek_resource_groups(resources, limit, subject) do
      resource_ids = Enum.map(resources, & &1.id)

      groups_by_resource =
        from(p in Domain.Policy, as: :policies)
        |> join(:inner, [policies: p], g in Domain.Group,
          on: g.id == p.group_id,
          as: :groups
        )
        |> where([policies: p], p.resource_id in ^resource_ids)
        |> where([policies: p], is_nil(p.disabled_at))
        |> select([policies: p, groups: g], {p.resource_id, g})
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      peek =
        Enum.into(resources, %{}, fn resource ->
          all_groups = Map.get(groups_by_resource, resource.id, [])
          peek_groups = Enum.take(all_groups, limit)
          {resource.id, %{
            items: peek_groups,
            count: length(all_groups)
          }}
        end)

      {:ok, peek}
    end

    def list_policies(subject, opts \\ []) do
      from(p in Domain.Policy, as: :policies)
      |> Safe.scoped(subject)
      |> Safe.list(DB.PolicyQuery, opts)
    end

    # Inline functions from Domain.Flows
    def list_flows_for(assoc, subject, opts \\ [])

    def list_flows_for(%Domain.Policy{} = policy, %Domain.Auth.Subject{} = subject, opts) do
      DB.FlowQuery.all()
      |> DB.FlowQuery.by_policy_id(policy.id)
      |> list_flows(subject, opts)
    end

    def list_flows_for(%Domain.Resource{} = resource, %Domain.Auth.Subject{} = subject, opts) do
      DB.FlowQuery.all()
      |> DB.FlowQuery.by_resource_id(resource.id)
      |> list_flows(subject, opts)
    end

    def list_flows_for(%Domain.Client{} = client, %Domain.Auth.Subject{} = subject, opts) do
      DB.FlowQuery.all()
      |> DB.FlowQuery.by_client_id(client.id)
      |> list_flows(subject, opts)
    end

    def list_flows_for(%Domain.Actor{} = actor, %Domain.Auth.Subject{} = subject, opts) do
      DB.FlowQuery.all()
      |> DB.FlowQuery.by_actor_id(actor.id)
      |> list_flows(subject, opts)
    end

    def list_flows_for(%Domain.Gateway{} = gateway, %Domain.Auth.Subject{} = subject, opts) do
      DB.FlowQuery.all()
      |> DB.FlowQuery.by_gateway_id(gateway.id)
      |> list_flows(subject, opts)
    end

    defp list_flows(queryable, subject, opts) do
      queryable
      |> Domain.Safe.scoped(subject)
      |> Domain.Safe.list(DB.FlowQuery, opts)
    end
  end

  defmodule DB.ResourceQuery do
    import Ecto.Query
    import Domain.Repo.Query

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
      {with_joined_connections(queryable),
       dynamic([connections: connections], connections.site_id == ^site_id)}
    end

    def filter_by_type(queryable, {:not_in, types}) do
      {queryable, dynamic([resources: resources], resources.type not in ^types)}
    end

    def filter_by_type(queryable, types) do
      {queryable, dynamic([resources: resources], resources.type in ^types)}
    end

    def with_joined_connections(queryable) do
      ensure_named_binding(queryable, :connections, fn queryable, binding ->
        queryable
        |> join(
          :inner,
          [resources: resources],
          connections in ^Domain.Resources.Connection.Query.all(),
          on: connections.resource_id == resources.id,
          as: ^binding
        )
      end)
    end

    def ensure_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end
  end

  defmodule DB.PolicyQuery do
    def cursor_fields,
      do: [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]

    def filters, do: []
  end

  defmodule DB.FlowQuery do
    use Domain, :query

    def all do
      from(flows in Domain.Flow, as: :flows)
    end

    def expired(queryable) do
      now = DateTime.utc_now()
      where(queryable, [flows: flows], flows.expires_at <= ^now)
    end

    def not_expired(queryable) do
      now = DateTime.utc_now()
      where(queryable, [flows: flows], flows.expires_at > ^now)
    end

    def by_id(queryable, id) do
      where(queryable, [flows: flows], flows.id == ^id)
    end

    def by_account_id(queryable, account_id) do
      where(queryable, [flows: flows], flows.account_id == ^account_id)
    end

    def by_token_id(queryable, token_id) do
      where(queryable, [flows: flows], flows.token_id == ^token_id)
    end

    def by_policy_id(queryable, policy_id) do
      where(queryable, [flows: flows], flows.policy_id == ^policy_id)
    end

    def for_cache(queryable) do
      queryable
      |> select(
        [flows: flows],
        {{flows.client_id, flows.resource_id}, {flows.id, flows.expires_at}}
      )
    end

    def by_policy_group_id(queryable, group_id) do
      queryable
      |> with_joined_policy()
      |> where([policy: policy], policy.group_id == ^group_id)
    end

    def by_membership_id(queryable, membership_id) do
      where(queryable, [flows: flows], flows.membership_id == ^membership_id)
    end

    def by_site_id(queryable, site_id) do
      queryable
      |> with_joined_site()
      |> where([site: site], site.id == ^site_id)
    end

    def by_resource_id(queryable, resource_id) do
      where(queryable, [flows: flows], flows.resource_id == ^resource_id)
    end

    def by_not_in_resource_ids(queryable, resource_ids) do
      where(queryable, [flows: flows], flows.resource_id not in ^resource_ids)
    end

    def by_client_id(queryable, client_id) do
      where(queryable, [flows: flows], flows.client_id == ^client_id)
    end

    def by_actor_id(queryable, actor_id) do
      queryable
      |> with_joined_client()
      |> where([client: client], client.actor_id == ^actor_id)
    end

    def by_gateway_id(queryable, gateway_id) do
      where(queryable, [flows: flows], flows.gateway_id == ^gateway_id)
    end

    def with_joined_policy(queryable) do
      with_flow_named_binding(queryable, :policy, fn queryable, binding ->
        join(queryable, :inner, [flows: flows], policy in assoc(flows, ^binding), as: ^binding)
      end)
    end

    def with_joined_client(queryable) do
      with_flow_named_binding(queryable, :client, fn queryable, binding ->
        join(queryable, :inner, [flows: flows], client in assoc(flows, ^binding), as: ^binding)
      end)
    end

    def with_joined_site(queryable) do
      queryable
      |> with_joined_gateway()
      |> with_flow_named_binding(:site, fn queryable, binding ->
        join(queryable, :inner, [gateway: gateway], site in assoc(gateway, :site), as: ^binding)
      end)
    end

    def with_joined_gateway(queryable) do
      with_flow_named_binding(queryable, :gateway, fn queryable, binding ->
        join(queryable, :inner, [flows: flows], gateway in assoc(flows, ^binding), as: ^binding)
      end)
    end

    def with_flow_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end

    # Pagination
    @impl Domain.Repo.Query
    def cursor_fields,
      do: [
        {:flows, :desc, :inserted_at},
        {:flows, :asc, :id}
      ]
  end
end
