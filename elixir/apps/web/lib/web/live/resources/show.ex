defmodule Web.Resources.Show do
  use Web, :live_view
  import Web.Policies.Components
  import Web.Resources.Components
  alias Domain.PubSub
  alias __MODULE__.DB

  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, resource} <- fetch_resource(id, socket.assigns.subject),
         {:ok, groups_peek} <-
           DB.peek_resource_groups([resource], 3, socket.assigns.subject) do
      if connected?(socket) do
        :ok = PubSub.Account.subscribe(resource.account_id)
      end

      socket =
        assign(
          socket,
          page_title: "Resource #{resource.name}",
          resource: resource,
          groups_peek: Map.fetch!(groups_peek, resource.id),
          params: Map.take(params, ["site_id"])
        )
        |> assign_live_table("flows",
          query_module: DB.FlowQuery,
          sortable_fields: [],
          hide_filters: [:expiration],
          callback: &handle_flows_update!/2
        )
        |> assign_live_table("policies",
          query_module: DB,
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

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
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
        policy: [:resource, :group]
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
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/#{@resource.id}"}>
        {@resource.name}
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Resource: <code>{@resource.name}</code>
      </:title>
      <:action :if={@resource.type != :internet}>
        <.edit_button navigate={~p"/#{@account}/resources/#{@resource.id}/edit?#{@params}"}>
          Edit Resource
        </.edit_button>
      </:action>
      <:content>
        <.vertical_table id="resource">
          <.vertical_table_row>
            <:label>
              ID
            </:label>
            <:value>
              {@resource.id}
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Name
            </:label>
            <:value>
              {@resource.name}
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Address
            </:label>
            <:value>
              <span :if={@resource.type == :internet}>
                0.0.0.0/0, ::/0
              </span>
              <span :if={@resource.type != :internet}>
                {@resource.address}
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Address Description
            </:label>
            <:value>
              <span :if={@resource.type == :internet}>
                The Internet Resource includes all IPv4 and IPv6 addresses.
              </span>

              <span :if={@resource.type != :internet}>
                <%= if http_link?(@resource.address_description) do %>
                  <.link class={link_style()} navigate={@resource.address_description} target="_blank">
                    {@resource.address_description}
                    <.icon name="hero-arrow-top-right-on-square" class="mb-3 w-3 h-3" />
                  </.link>
                <% else %>
                  {@resource.address_description}
                <% end %>
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={@resource.ip_stack}>
            <:label>
              IP Stack
            </:label>
            <:value>
              <span>
                {format_ip_stack(@resource.ip_stack)}
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Connected Sites
            </:label>
            <:value>
              <.link
                :for={site <- @resource.sites}
                :if={@resource.sites != []}
                navigate={~p"/#{@account}/sites/#{site}"}
                class={[link_style()]}
              >
                <.badge type="info">
                  {site.name}
                </.badge>
              </.link>
              <span :if={@resource.sites == []}>
                No linked Sites to display
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Traffic restriction
            </:label>
            <:value>
              <div :if={@resource.filters == []} %>
                All traffic allowed
              </div>
              <div :for={filter <- @resource.filters} :if={@resource.filters != []} %>
                <.filter_description filter={filter} />
              </div>
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Policies
      </:title>
      <:action>
        <.add_button navigate={
          if site_id = @params["site_id"] do
            ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{site_id}"
          else
            ~p"/#{@account}/policies/new?resource_id=#{@resource}"
          end
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
                  navigate={
                    if site_id = @params["site_id"] do
                      ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{site_id}"
                    else
                      ~p"/#{@account}/policies/new?resource_id=#{@resource}"
                    end
                  }
                >
                  Add a policy
                </.link>
                to grant access to this Resource.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section>
      <:title>Recent Connections</:title>
      <:help>
        Recent connections opened by Actors to access this Resource.
      </:help>
      <:content>
        <.live_table
          id="flows"
          rows={@flows}
          row_id={&"flows-#{&1.id}"}
          filters={@filters_by_table_id["flows"]}
          filter={@filter_form_by_table_id["flows"]}
          ordered_by={@order_by_table_id["flows"]}
          metadata={@flows_metadata}
        >
          <:col :let={flow} label="authorized">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="policy">
            <.link navigate={~p"/#{@account}/policies/#{flow.policy_id}"} class={[link_style()]}>
              <.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="client, actor" class="w-3/12">
            <.link navigate={~p"/#{@account}/clients/#{flow.client_id}"} class={[link_style()]}>
              {flow.client.name}
            </.link>
            owned by
            <.link
              navigate={~p"/#{@account}/actors/#{flow.client.actor_id}?#{[return_to: @current_path]}"}
              class={[link_style()]}
            >
              {flow.client.actor.name}
            </.link>
            {flow.client_remote_ip}
          </:col>
          <:col :let={flow} label="gateway" class="w-3/12">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              {flow.gateway.site.name}-{flow.gateway.name}
            </.link>
            <br />
            <code class="text-xs">{flow.gateway_remote_ip}</code>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={@resource.type != :internet}>
      <:action>
        <.button_with_confirmation
          id="delete_resource"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
          on_confirm_id={@resource.id}
        >
          <:dialog_title>Confirm deletion of Resource</:dialog_title>
          <:dialog_content>
            Are you sure want to delete this Resource along with all associated Policies?
            This will immediately end all active sessions opened for this Resource.
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Resource
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Resource
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  # TODO: Do we really want to update the view in place?
  def handle_info(
        {_action, _old_resource, %Domain.Resource{id: resource_id}},
        %{assigns: %{resource: %{id: id}}} = socket
      )
      when resource_id == id do
    {:ok, resource} =
      DB.fetch_resource_by_id(socket.assigns.resource.id, socket.assigns.subject)

    resource = Domain.Safe.preload(resource, [:sites, :policies])

    {:noreply, assign(socket, resource: resource)}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("delete", %{"id" => _resource_id}, socket) do
    {:ok, _deleted_resource} =
      DB.delete_resource(socket.assigns.resource, socket.assigns.subject)

    socket = put_flash(socket, :success, "Resource was deleted.")

    if site_id = socket.assigns.params["site_id"] do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}")}
    else
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources")}
    end
  end

  defp http_link?(nil), do: false

  defp http_link?(address_description) do
    uri = URI.parse(address_description)

    if not is_nil(uri.scheme) and not is_nil(uri.host) and String.starts_with?(uri.scheme, "http") do
      true
    else
      false
    end
  end

  defp fetch_resource("internet", subject) do
    DB.fetch_internet_resource(subject)
    |> case do
      {:ok, resource} -> {:ok, Domain.Safe.preload(resource, :sites)}
      error -> error
    end
  end

  defp fetch_resource(id, subject) do
    DB.fetch_resource_by_id(id, subject)
    |> case do
      {:ok, resource} -> {:ok, Domain.Safe.preload(resource, :sites)}
      error -> error
    end
  end

  defp format_ip_stack(:dual), do: "Dual-stack (IPv4 and IPv6)"
  defp format_ip_stack(:ipv4_only), do: "IPv4 only"
  defp format_ip_stack(:ipv6_only), do: "IPv6 only"

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Resource, Repo, Policy}

    def fetch_resource_by_id(id, subject) do
      result =
        from(r in Resource, as: :resources)
        |> where([resources: r], r.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
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

    def all do
      from(resources in Resource, as: :resources)
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

    def delete_resource(resource, subject) do
      Safe.scoped(resource, subject)
      |> Safe.delete()
    end

    def list_policies(subject, opts \\ []) do
      from(p in Policy, as: :policies)
      |> where([policies: p], is_nil(p.deleted_at))
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    # Pagination support for policies
    def cursor_fields,
      do: [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]

    def filters, do: []

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
