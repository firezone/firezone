defmodule PortalWeb.Sites.Show do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(%{"id" => id}, _session, socket) do
    site = Database.get_site!(id, socket.assigns.subject)

    if connected?(socket) do
      :ok = Portal.Presence.Gateways.Site.subscribe(site.id)
    end

    socket =
      socket
      |> assign(
        page_title: "Site #{site.name}",
        site: site
      )

    mount_page(socket, site)
  end

  defp mount_page(socket, %{managed_by: :system, name: "Internet"} = site) do
    resource = Database.get_internet_resource!(socket.assigns.subject)

    socket =
      socket
      |> assign(resource: resource)
      |> assign_live_table("gateways",
        query_module: Database,
        enforce_filters: [
          {:site_id, site.id}
        ],
        sortable_fields: [
          {:gateways, :last_seen_at}
        ],
        callback: &handle_gateways_update!/2
      )
      |> assign_live_table("policies",
        query_module: Database.PolicyQuery,
        enforce_filters: [
          {:resource_id, resource.id}
        ],
        sortable_fields: [],
        callback: &handle_policies_update!/2
      )

    {:ok, socket}
  end

  defp mount_page(socket, site) do
    socket =
      socket
      |> assign_live_table("gateways",
        query_module: Database,
        enforce_filters: [
          {:site_id, site.id}
        ],
        sortable_fields: [
          {:gateways, :last_seen_at}
        ],
        callback: &handle_gateways_update!/2
      )
      |> assign_live_table("resources",
        query_module: Database.ResourceQuery,
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
    online_ids = Portal.Presence.Gateways.Site.list(socket.assigns.site.id) |> Map.keys()

    list_opts =
      list_opts
      |> Keyword.put(:preload, [:online?])
      |> Keyword.update(:filter, [], fn filter ->
        filter ++ [{:ids, online_ids}]
      end)

    with {:ok, gateways, metadata} <- Database.list_gateways(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         gateways: gateways,
         gateways_metadata: metadata
       )}
    end
  end

  def handle_resources_update!(socket, list_opts) do
    with {:ok, resources, metadata} <-
           Database.list_resources(socket.assigns.subject, list_opts) do
      resource_ids = Enum.map(resources, & &1.id)
      policy_counts = Database.count_policies_by_resource(resource_ids, socket.assigns.subject)

      {:ok,
       assign(socket,
         resources: resources,
         resources_metadata: metadata,
         policy_counts: policy_counts
       )}
    end
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

      <:content :if={@site.managed_by != :system}>
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
            This will <strong>immediately</strong>
            disconnect all associated Gateways and delete all linked Resources.
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
              <.version_status outdated={Portal.Gateway.gateway_outdated?(gateway)} />
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
            <:col :let={resource} label="Policies">
              <% count = Map.get(@policy_counts, resource.id, 0) %>
              <%= if count == 0 do %>
                <div class="flex items-center">
                  <.icon
                    name="hero-exclamation-triangle-solid"
                    class="inline-block w-3.5 h-3.5 mr-1 text-red-500"
                  /> None.
                  <.link
                    class={[link_style(), "ml-1"]}
                    navigate={~p"/#{@account}/policies/new?resource_id=#{resource}&site_id=#{@site}"}
                  >
                    Create a Policy
                  </.link>
                </div>
              <% else %>
                <.link
                  navigate={~p"/#{@account}/policies?policies_filter[resource_id]=#{resource.id}"}
                  class={[link_style()]}
                >
                  {count} {ngettext("policy", "policies", count)}
                </.link>
              <% end %>
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
                  navigate={~p"/#{@account}/policies/new?resource_id=#{@resource}&site_id=#{@site}"}
                >
                  Add a policy
                </.link>
                to configure secure access to the internet.
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
          <:dialog_title>Delete Site</:dialog_title>
          <:dialog_content>
            <.deletion_stats site={@site} subject={@subject} />
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
    # Permission check happens in Portal.Safe - only account_admin_user can delete tokens
    deleted_token_count =
      case Database.delete_tokens_for_site(socket.assigns.site, socket.assigns.subject) do
        {:error, :unauthorized} -> 0
        {count, _} -> count
      end

    socket =
      socket
      |> put_flash(:success, "#{deleted_token_count} token(s) were revoked.")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _deleted_site} = Database.delete_site(socket.assigns.site, socket.assigns.subject)
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

  defp deletion_stats(assigns) do
    stats = Database.count_site_deletion_stats(assigns.site, assigns.subject)
    total = stats.gateways + stats.tokens + stats.resources
    assigns = assign(assigns, stats: stats, total: total)

    ~H"""
    <div>
      <p class="text-neutral-700">
        Are you sure you want to delete <strong>{@site.name}</strong>?
      </p>
      <%= if @total > 0 do %>
        <p class="mt-3 text-neutral-700">
          This will permanently delete:
        </p>
        <ul class="list-disc list-inside mt-2 text-neutral-700 space-y-1">
          <li :if={@stats.gateways > 0}>
            <strong>{@stats.gateways}</strong> {ngettext("gateway", "gateways", @stats.gateways)}
          </li>
          <li :if={@stats.tokens > 0}>
            <strong>{@stats.tokens}</strong> {ngettext("token", "tokens", @stats.tokens)}
          </li>
          <li :if={@stats.resources > 0}>
            <strong>{@stats.resources}</strong> {ngettext("resource", "resources", @stats.resources)}
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Gateway

    def get_site!(id, subject) do
      from(s in Portal.Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def delete_tokens_for_site(site, subject) do
      from(t in Portal.GatewayToken, where: t.site_id == ^site.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
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
        online?: &Portal.Presence.Gateways.preload_gateways_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          values: [],
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
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

    def count_site_deletion_stats(site, subject) do
      gateways =
        from(g in Gateway, where: g.site_id == ^site.id)
        |> Safe.scoped(subject)
        |> Safe.aggregate(:count)

      tokens =
        from(t in Portal.GatewayToken, where: t.site_id == ^site.id)
        |> Safe.scoped(subject)
        |> Safe.aggregate(:count)

      resources =
        from(r in Portal.Resource, where: r.site_id == ^site.id)
        |> Safe.scoped(subject)
        |> Safe.aggregate(:count)

      %{gateways: gateways, tokens: tokens, resources: resources}
    end

    def get_internet_resource!(subject) do
      from(r in Portal.Resource, as: :resources)
      |> where([resources: r], r.type == :internet)
      |> limit(1)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def list_resources(subject, opts \\ []) do
      from(r in Portal.Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(Database.ResourceQuery, opts)
    end

    def count_policies_by_resource(resource_ids, subject) do
      from(p in Portal.Policy, as: :policies)
      |> where([policies: p], p.resource_id in ^resource_ids)
      |> group_by([policies: p], p.resource_id)
      |> select([policies: p], {p.resource_id, count(p.id)})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    def list_policies(subject, opts \\ []) do
      from(p in Portal.Policy, as: :policies)
      |> Safe.scoped(subject)
      |> Safe.list(Database.PolicyQuery, opts)
    end
  end

  defmodule Database.ResourceQuery do
    import Ecto.Query
    import Portal.Repo.Query

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
      {queryable, dynamic([resources: resources], resources.site_id == ^site_id)}
    end
  end

  defmodule Database.PolicyQuery do
    import Ecto.Query

    def cursor_fields,
      do: [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :resource_id,
          type: {:string, :uuid},
          fun: &filter_by_resource_id/2
        }
      ]
    end

    def filter_by_resource_id(queryable, resource_id) do
      {queryable, dynamic([policies: p], p.resource_id == ^resource_id)}
    end
  end
end
