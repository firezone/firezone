defmodule PortalWeb.Resources.Show do
  use PortalWeb, :live_view
  import PortalWeb.Policies.Components
  import PortalWeb.Resources.Components
  alias Portal.PubSub
  alias __MODULE__.Database

  def mount(%{"id" => id} = params, _session, socket) do
    resource = get_resource!(id, socket.assigns.subject)

    if connected?(socket) do
      :ok = PubSub.Account.subscribe(resource.account_id)
    end

    socket =
      assign(
        socket,
        page_title: "Resource #{resource.name}",
        resource: resource,
        params: Map.take(params, ["site_id"])
      )
      |> assign_live_table("policy_authorizations",
        query_module: Database.PolicyAuthorizationQuery,
        sortable_fields: [],
        hide_filters: [:expiration],
        callback: &handle_policy_authorizations_update!/2
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
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, assign(socket, return_to: uri_path(uri))}
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

  def handle_policy_authorizations_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:site],
        policy: [:resource, :group]
      )

    with {:ok, policy_authorizations, metadata} <-
           Database.list_policy_authorizations_for(
             socket.assigns.resource,
             socket.assigns.subject,
             list_opts
           ) do
      {:ok,
       assign(socket,
         policy_authorizations: policy_authorizations,
         policy_authorizations_metadata: metadata
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
              Site
            </:label>
            <:value>
              <.link
                :if={@resource.site}
                navigate={~p"/#{@account}/sites/#{@resource.site}"}
                class={[link_style()]}
              >
                <.badge type="info">
                  {@resource.site.name}
                </.badge>
              </.link>
              <span :if={is_nil(@resource.site)}>
                Not linked to a site
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
            <.group_badge account={@account} group={policy.group} return_to={@return_to} />
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
          id="policy_authorizations"
          rows={@policy_authorizations}
          row_id={&"policy_authorizations-#{&1.id}"}
          filters={@filters_by_table_id["policy_authorizations"]}
          filter={@filter_form_by_table_id["policy_authorizations"]}
          ordered_by={@order_by_table_id["policy_authorizations"]}
          metadata={@policy_authorizations_metadata}
        >
          <:col :let={policy_authorization} label="authorized">
            <.relative_datetime datetime={policy_authorization.inserted_at} />
          </:col>
          <:col :let={policy_authorization} label="policy">
            <.link
              navigate={~p"/#{@account}/policies/#{policy_authorization.policy_id}"}
              class={[link_style()]}
            >
              <.policy_name policy={policy_authorization.policy} />
            </.link>
          </:col>
          <:col :let={policy_authorization} label="client, actor" class="w-3/12">
            <.link
              navigate={~p"/#{@account}/clients/#{policy_authorization.client_id}"}
              class={[link_style()]}
            >
              {policy_authorization.client.name}
            </.link>
            owned by
            <.link
              navigate={
                ~p"/#{@account}/actors/#{policy_authorization.client.actor_id}?#{[return_to: @return_to]}"
              }
              class={[link_style()]}
            >
              {policy_authorization.client.actor.name}
            </.link>
            {policy_authorization.client_remote_ip}
          </:col>
          <:col :let={policy_authorization} label="gateway" class="w-3/12">
            <.link
              navigate={~p"/#{@account}/gateways/#{policy_authorization.gateway_id}"}
              class={[link_style()]}
            >
              {policy_authorization.gateway.site.name}-{policy_authorization.gateway.name}
            </.link>
            <br />
            <code class="text-xs">{policy_authorization.gateway_remote_ip}</code>
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
        {_action, _old_resource, %Portal.Resource{id: resource_id}},
        %{assigns: %{resource: %{id: id}}} = socket
      )
      when resource_id == id do
    resource = Database.get_resource!(socket.assigns.resource.id, socket.assigns.subject)

    {:noreply, assign(socket, resource: resource)}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("delete", %{"id" => _resource_id}, socket) do
    {:ok, _deleted_resource} =
      Database.delete_resource(socket.assigns.resource, socket.assigns.subject)

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

  defp get_resource!("internet", subject) do
    Database.get_internet_resource!(subject)
  end

  defp get_resource!(id, subject) do
    Database.get_resource!(id, subject)
  end

  defp format_ip_stack(:dual), do: "Dual-stack (IPv4 and IPv6)"
  defp format_ip_stack(:ipv4_only), do: "IPv4 only"
  defp format_ip_stack(:ipv6_only), do: "IPv6 only"

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Authorization, Resource, Policy}

    def get_resource!(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(r in Resource, as: :resources)
        |> where([resources: r], r.id == ^id)
        |> preload([:site, :policies])
        |> Portal.Repo.fetch!(:one)
      end)
    end

    def get_internet_resource!(subject) do
      Authorization.with_subject(subject, fn ->
        from(r in Resource, as: :resources)
        |> where([resources: r], r.type == :internet)
        |> preload([:site, :policies])
        |> Portal.Repo.fetch!(:one)
      end)
    end

    def delete_resource(resource, subject) do
      Authorization.with_subject(subject, fn ->
        Portal.Repo.delete(resource)
      end)
    end

    def list_policies(subject, opts \\ []) do
      Authorization.with_subject(subject, fn ->
        from(p in Policy, as: :policies)
        |> Portal.Repo.list(DB, opts)
      end)
    end

    # Pagination support for policies
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
          name: :group_or_resource_name,
          title: "Group Name or Resource Name",
          type: {:string, :websearch},
          fun: &filter_by_group_or_resource_name/2
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

    def filter_by_group_or_resource_name(queryable, name) do
      queryable = queryable |> with_joined_group() |> with_joined_resource()

      {queryable,
       dynamic(
         [group: g, resource: r],
         fulltext_search(g.name, ^name) or fulltext_search(r.name, ^name)
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

    def preloads, do: []

    # Inline functions from Portal.PolicyAuthorizations
    def list_policy_authorizations_for(assoc, subject, opts \\ [])

    def list_policy_authorizations_for(
          %Portal.Policy{} = policy,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_policy_id(policy.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Resource{} = resource,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_resource_id(resource.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Client{} = client,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_client_id(client.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Actor{} = actor,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_actor_id(actor.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Gateway{} = gateway,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_gateway_id(gateway.id)
      |> list_policy_authorizations(subject, opts)
    end

    defp list_policy_authorizations(queryable, subject, opts) do
      Authorization.with_subject(subject, fn ->
        queryable
        |> Portal.Repo.list(Database.PolicyAuthorizationQuery, opts)
      end)
    end
  end

  defmodule Database.PolicyAuthorizationQuery do
    import Ecto.Query

    def all do
      from(policy_authorizations in Portal.PolicyAuthorization, as: :policy_authorizations)
    end

    def expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at <= ^now
      )
    end

    def not_expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at > ^now
      )
    end

    def by_id(queryable, id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.id == ^id
      )
    end

    def by_account_id(queryable, account_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.account_id == ^account_id
      )
    end

    def by_token_id(queryable, token_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.token_id == ^token_id
      )
    end

    def by_policy_id(queryable, policy_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.policy_id == ^policy_id
      )
    end

    def for_cache(queryable) do
      queryable
      |> select(
        [policy_authorizations: policy_authorizations],
        {{policy_authorizations.client_id, policy_authorizations.resource_id},
         {policy_authorizations.id, policy_authorizations.expires_at}}
      )
    end

    def by_policy_group_id(queryable, group_id) do
      queryable
      |> with_joined_policy()
      |> where([policy: policy], policy.group_id == ^group_id)
    end

    def by_membership_id(queryable, membership_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.membership_id == ^membership_id
      )
    end

    def by_site_id(queryable, site_id) do
      queryable
      |> with_joined_site()
      |> where([site: site], site.id == ^site_id)
    end

    def by_resource_id(queryable, resource_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id == ^resource_id
      )
    end

    def by_not_in_resource_ids(queryable, resource_ids) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id not in ^resource_ids
      )
    end

    def by_client_id(queryable, client_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.client_id == ^client_id
      )
    end

    def by_actor_id(queryable, actor_id) do
      queryable
      |> with_joined_client()
      |> where([client: client], client.actor_id == ^actor_id)
    end

    def by_gateway_id(queryable, gateway_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.gateway_id == ^gateway_id
      )
    end

    def with_joined_policy(queryable) do
      with_policy_authorization_named_binding(queryable, :policy, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          policy in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_client(queryable) do
      with_policy_authorization_named_binding(queryable, :client, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          client in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_site(queryable) do
      queryable
      |> with_joined_gateway()
      |> with_policy_authorization_named_binding(:site, fn queryable, binding ->
        join(queryable, :inner, [gateway: gateway], site in assoc(gateway, :site), as: ^binding)
      end)
    end

    def with_joined_gateway(queryable) do
      with_policy_authorization_named_binding(queryable, :gateway, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          gateway in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_policy_authorization_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end

    # Pagination
    def cursor_fields,
      do: [
        {:policy_authorizations, :desc, :inserted_at},
        {:policy_authorizations, :asc, :id}
      ]

    def filters, do: []

    def preloads, do: []
  end
end
