defmodule Web.Sites.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Accounts, Gateways, Resources, Policies, Flows, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               created_by_identity: [:actor],
               created_by_actor: []
             ]
           ) do
      if connected?(socket) do
        :ok = Gateways.subscribe_to_gateways_presence_in_group(group)
      end

      socket =
        socket
        |> assign(
          page_title: "Site #{group.name}",
          group: group
        )

      mount_page(socket, group)
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp mount_page(socket, %{managed_by: :system, name: "Internet"} = group) do
    with {:ok, resource} <-
           Resources.fetch_internet_resource(socket.assigns.subject,
             preload: [
               :gateway_groups,
               :created_by_actor,
               created_by_identity: [:actor],
               replaced_by_resource: [],
               replaces_resource: []
             ]
           ) do
      socket =
        socket
        |> assign(resource: resource)
        |> assign_live_table("gateways",
          query_module: Gateways.Gateway.Query,
          enforce_filters: [
            {:gateway_group_id, group.id}
          ],
          sortable_fields: [
            {:gateways, :last_seen_at}
          ],
          callback: &handle_gateways_update!/2
        )
        |> assign_live_table("flows",
          query_module: Flows.Flow.Query,
          sortable_fields: [],
          callback: &handle_flows_update!/2
        )
        |> assign_live_table("policies",
          query_module: Policies.Policy.Query,
          hide_filters: [
            :actor_group_id,
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

  defp mount_page(socket, group) do
    socket =
      socket
      |> assign_live_table("gateways",
        query_module: Gateways.Gateway.Query,
        enforce_filters: [
          {:gateway_group_id, group.id}
        ],
        sortable_fields: [
          {:gateways, :last_seen_at}
        ],
        callback: &handle_gateways_update!/2
      )
      |> assign_live_table("resources",
        query_module: Resources.Resource.Query,
        enforce_filters: [
          {:gateway_group_id, group.id}
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
    online_ids = Gateways.all_online_gateway_ids_by_group_id!(socket.assigns.group.id)

    list_opts =
      list_opts
      |> Keyword.put(:preload, [:online?])
      |> Keyword.update(:filter, [], fn filter ->
        filter ++ [{:ids, online_ids}]
      end)

    with {:ok, gateways, metadata} <- Gateways.list_gateways(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         gateways: gateways,
         gateways_metadata: metadata
       )}
    end
  end

  def handle_resources_update!(socket, list_opts) do
    with {:ok, resources, metadata} <-
           Resources.list_resources(socket.assigns.subject, list_opts),
         {:ok, resource_actor_groups_peek} <-
           Resources.peek_resource_actor_groups(resources, 3, socket.assigns.subject) do
      {:ok,
       assign(socket,
         resources: resources,
         resources_metadata: metadata,
         resource_actor_groups_peek: resource_actor_groups_peek
       )}
    end
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, actor_group: [:provider], resource: [])

    with {:ok, policies, metadata} <- Policies.list_policies(socket.assigns.subject, list_opts) do
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
        gateway: [:group],
        policy: [:resource, :actor_group]
      )

    with {:ok, flows, metadata} <-
           Flows.list_flows_for(socket.assigns.resource, socket.assigns.subject, list_opts) do
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
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        {@group.name}
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Site: <code>{@group.name}</code>
        <span :if={not is_nil(@group.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>

      <:action :if={is_nil(@group.deleted_at) and @group.managed_by == :account}>
        <.edit_button navigate={~p"/#{@account}/sites/#{@group}/edit"}>
          Edit Site
        </.edit_button>
      </:action>

      <:help :if={@group.managed_by == :system and @group.name == "Internet"}>
        The Internet Site is a dedicated Site for Internet traffic that does not match any specific Resource.
        Deploy Gateways here to secure access to the public Internet for your workforce.
      </:help>

      <:content>
        <.vertical_table id="group">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@group.name}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <.created_by account={@account} schema={@group} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Online Gateways
        <.link class={["text-sm", link_style()]} navigate={~p"/#{@account}/sites/#{@group}/gateways"}>
          see all <.icon name="hero-arrow-right" class="w-2 h-2" />
        </.link>
      </:title>
      <:action>
        <.docs_action path="/deploy/gateways" />
      </:action>
      <:action :if={is_nil(@group.deleted_at)}>
        <.add_button navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
          Deploy Gateway
        </.add_button>
      </:action>
      <:action :if={is_nil(@group.deleted_at)}>
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
      <:help :if={@group.managed_by == :system and @group.name == "Internet"}>
        Gateways deployed to the Internet Site are used to tunnel all traffic that doesn't match any specific Resource.
      </:help>
      <:help :if={is_nil(@group.deleted_at) and @group.managed_by == :account}>
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
              <.version_status outdated={Gateways.gateway_outdated?(gateway)} />
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
                    <.link
                      class={[link_style()]}
                      navigate={~p"/#{@account}/sites/#{@group}/new_token"}
                    >
                      Deploy a Gateway to the Internet Site.
                    </.link>
                  </span>
                  <span :if={is_nil(@group.deleted_at) and @group.managed_by == :account}>
                    <.link
                      class={[link_style()]}
                      navigate={~p"/#{@account}/sites/#{@group}/new_token"}
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

    <.section :if={@group.managed_by == :account}>
      <:title>
        Resources
      </:title>
      <:action :if={is_nil(@group.deleted_at)}>
        <.add_button navigate={~p"/#{@account}/resources/new?site_id=#{@group}"}>
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
                navigate={~p"/#{@account}/resources/#{resource}?site_id=#{@group}"}
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
              <.peek peek={Map.fetch!(@resource_actor_groups_peek, resource.id)}>
                <:empty>
                  <div class="mr-1">
                    <.icon
                      name="hero-exclamation-triangle-solid"
                      class="inline-block w-3.5 h-3.5 text-red-500"
                    /> None.
                  </div>
                  <.link
                    class={[link_style(), "mr-1"]}
                    navigate={~p"/#{@account}/policies/new?resource_id=#{resource}&site_id=#{@group}"}
                  >
                    Create a Policy
                  </.link>
                  to grant access.
                </:empty>

                <:item :let={group}>
                  <.group account={@account} group={group} />
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

    <.section :if={@group.managed_by == :system and @group.name == "Internet"}>
      <:title>
        Policies
      </:title>
      <:action>
        <.add_button navigate={
          ~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{@group}"
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
            <.group account={@account} group={policy.actor_group} />
          </:col>
          <:col :let={policy} label="status">
            <%= if is_nil(policy.deleted_at) do %>
              <%= if is_nil(policy.disabled_at) do %>
                Active
              <% else %>
                Disabled
              <% end %>
            <% else %>
              Deleted
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
                  navigate={~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{@group}"}
                >
                  Add a policy
                </.link>
                to allow usage of the Internet Site.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section :if={@group.managed_by == :system and @group.name == "Internet"}>
      <:title>Recent Connections</:title>
      <:help>
        Recent connections opened by Actors to the Internet.
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
            <.link navigate={~p"/#{@account}/actors/#{flow.client.actor_id}"} class={[link_style()]}>
              {flow.client.actor.name}
            </.link>
            {flow.client_remote_ip}
          </:col>
          <:col :let={flow} label="gateway" class="w-3/12">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              {flow.gateway.group.name}-{flow.gateway.name}
            </.link>
            <br />
            <code class="text-xs">{flow.gateway_remote_ip}</code>
          </:col>
          <:col :let={flow} :if={Accounts.flow_activities_enabled?(@account)} label="activity">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={[link_style()]}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@group.deleted_at) and @group.managed_by == :account}>
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
        %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _group_id},
        socket
      ) do
    {:noreply, reload_live_table!(socket, "gateways")}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("revoke_all_tokens", _params, socket) do
    {:ok, deleted_tokens} = Tokens.delete_tokens_for(socket.assigns.group, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "#{length(deleted_tokens)} token(s) were revoked.")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _group} = Gateways.delete_group(socket.assigns.group, socket.assigns.subject)
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
end
