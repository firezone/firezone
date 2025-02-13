defmodule Web.Sites.Index do
  use Web, :live_view
  alias Domain.Gateways

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Gateways.subscribe_to_gateways_presence_in_account(socket.assigns.account)
    end

    with {:ok, managed_groups, _metadata} <-
           Gateways.list_groups(socket.assigns.subject,
             preload: [
               gateways: [:online?]
             ],
             filter: [managed_by: "system"]
           ) do
      socket =
        socket
        |> assign(page_title: "Sites")
        |> assign(managed_groups: managed_groups)
        |> assign_live_table("groups",
          query_module: Gateways.Group.Query,
          sortable_fields: [
            {:groups, :name}
          ],
          enforce_filters: [
            {:managed_by, "account"}
          ],
          callback: &handle_groups_update!/2
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_groups_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, gateways: [:online?], connections: [:resource])

    with {:ok, groups, metadata} <-
           Gateways.list_groups(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         groups: groups,
         groups_metadata: metadata
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
        <.flash_group flash={@flash} />
        <.live_table
          id="groups"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
        >
          <:col :let={group} field={{:groups, :name}} label="site" class="w-1/6">
            <.link navigate={~p"/#{@account}/sites/#{group}"} class={[link_style()]}>
              {group.name}
            </.link>
          </:col>

          <:col :let={group} label="resources">
            <% connections = Enum.reject(group.connections, &is_nil(&1.resource))
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
                    ~p"/#{@account}/resources/#{connection.resource}?site_id=#{connection.gateway_group_id}"
                  }
                  class={["inline-block", link_style()]}
                  phx-no-format
                ><%= connection.resource.name %></.link>
              </:item>

              <:tail :let={count}>
                <span class="pl-1">
                  and
                  <.link
                    navigate={~p"/#{@account}/sites/#{group}?#resources"}
                    class={["font-medium", link_style()]}
                  >
                    {count} more.
                  </.link>
                </span>
              </:tail>
            </.peek>
          </:col>

          <:col :let={group} label="online gateways" class="w-1/6">
            <% gateways = Enum.filter(group.gateways, & &1.online?)
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
                    navigate={~p"/#{@account}/sites/#{group}?#gateways"}
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

    <% internet_gateway_group =
      Enum.find(assigns.managed_groups, fn group -> group.name == "Internet" end) %>
    <.section :if={internet_gateway_group} id="internet-site-banner">
      <:title>
        <div class="flex items-center space-x-2.5">
          <span>Internet</span>

          <% online? = Enum.any?(internet_gateway_group.gateways, & &1.online?) %>

          <.ping_icon
            :if={Domain.Accounts.internet_resource_enabled?(@account)}
            color={if online?, do: "success", else: "danger"}
            title={if online?, do: "Online", else: "Offline"}
          />

          <.link
            :if={not Domain.Accounts.internet_resource_enabled?(@account)}
            navigate={~p"/#{@account}/settings/billing"}
            class="text-sm text-primary-500"
          >
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
            </.badge>
          </.link>
        </div>
      </:title>

      <:action :if={Domain.Accounts.internet_resource_enabled?(@account)}>
        <.edit_button navigate={~p"/#{@account}/sites/#{internet_gateway_group}"}>
          Manage Full-route Tunneling
        </.edit_button>
      </:action>

      <:help>
        This is a dedicated Site for Internet traffic that does not match any specific Resource.
        Deploy Gateways here to secure access to the public Internet for your workforce.
      </:help>

      <:content></:content>
    </.section>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _account_id},
        socket
      ) do
    {:ok, managed_groups, _metadata} =
      Gateways.list_groups(socket.assigns.subject,
        preload: [
          gateways: [:online?]
        ],
        filter: [managed_by: "system"]
      )

    socket =
      socket
      |> assign(managed_groups: managed_groups)
      |> reload_live_table!("groups")

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)
end
