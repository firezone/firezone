defmodule Web.Sites.Show do
  use Web, :live_view
  alias Domain.{Gateways, Resources, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
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
        |> assign_live_table("gateways",
          query_module: Gateways.Gateway.Query,
          enforce_filters: [
            {:gateway_group_id, group.id}
          ],
          sortable_fields: [
            {:gateways, :last_seen_at}
          ],
          limit: 10,
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
          limit: 10,
          callback: &handle_resources_update!/2
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

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Site: <code><%= @group.name %></code>
        <span :if={not is_nil(@group.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@group.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/sites/#{@group}/edit"}>
          Edit Site
        </.edit_button>
      </:action>

      <:content>
        <.vertical_table id="group">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @group.name %></:value>
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
      <:action :if={is_nil(@group.deleted_at)}>
        <.add_button navigate={~p"/#{@account}/sites/#{@group}/new_token"}>
          Deploy Gateway
        </.add_button>
      </:action>
      <:action :if={is_nil(@group.deleted_at)}>
        <.delete_button
          phx-click="revoke_all_tokens"
          data-confirm="Are you sure you want to revoke all tokens? This will immediately disconnect all gateways in this site."
        >
          Revoke All Tokens
        </.delete_button>
      </:action>
      <:help :if={is_nil(@group.deleted_at)}>
        Deploy gateways to terminate connections to your site's resources. All
        gateways deployed within a site must be able to reach all
        its resources.
      </:help>
      <:content flash={@flash}>
        <div class="relative overflow-x-auto">
          <.live_table
            id="gateways"
            rows={@gateways}
            filters={@filters_by_table_id["gateways"]}
            filter={@filter_form_by_table_id["gateways"]}
            ordered_by={@order_by_table_id["gateways"]}
            metadata={@gateways_metadata}
          >
            <:col :let={gateway} label="INSTANCE">
              <.link navigate={~p"/#{@account}/gateways/#{gateway.id}"} class={[link_style()]}>
                <%= gateway.name %>
              </.link>
            </:col>
            <:col :let={gateway} label="REMOTE IP">
              <code>
                <%= gateway.last_seen_remote_ip %>
              </code>
            </:col>
            <:col :let={gateway} label="STATUS">
              <.connection_status schema={gateway} />
            </:col>
            <:empty>
              <div class="flex flex-col items-center justify-center text-center text-neutral-500 p-4">
                <div class="pb-4">
                  No gateways to display.
                  <span :if={is_nil(@group.deleted_at)}>
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

    <.section>
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
            <:col :let={resource} label="NAME" field={{:resources, :name}}>
              <.link
                navigate={~p"/#{@account}/resources/#{resource}?site_id=#{@group}"}
                class={[link_style()]}
              >
                <%= resource.name %>
              </.link>
            </:col>
            <:col :let={resource} label="ADDRESS" field={{:resources, :address}}>
              <code class="block text-xs">
                <%= resource.address %>
              </code>
            </:col>
            <:col :let={resource} label="Authorized groups">
              <.peek peek={Map.fetch!(@resource_actor_groups_peek, resource.id)}>
                <:empty>
                  None -
                  <.link
                    class={["px-1", link_style()]}
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
                    and <%= count %> more.
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

    <.danger_zone :if={is_nil(@group.deleted_at)}>
      <:action>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this gateway group and disconnect all it's gateways?"
        >
          Delete Site
        </.delete_button>
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
end
