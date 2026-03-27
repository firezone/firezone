defmodule PortalWeb.Resources.Components do
  use PortalWeb, :component_library
  alias __MODULE__.Database

  @resource_types %{
    internet: %{index: 1, label: nil},
    dns: %{index: 2, label: "DNS"},
    ip: %{index: 3, label: "IP"},
    cidr: %{index: 4, label: "CIDR"},
    static_device_pool: %{index: 5, label: "Device Pools"}
  }

  def fetch_resource_option(id, subject) do
    resource = Database.get_resource!(id, subject)
    {:ok, resource_option(resource)}
  end

  def list_resource_options(search_query_or_nil, subject) do
    filter =
      if search_query_or_nil != "" and search_query_or_nil != nil,
        do: [name_or_address: search_query_or_nil],
        else: []

    {:ok, resources, metadata} =
      Database.list_resources(subject,
        preload: [:site],
        limit: 25,
        filter: filter
      )

    {:ok, grouped_resource_options(resources), metadata}
  end

  defp grouped_resource_options(resources) do
    resources
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {type, _} ->
      Map.fetch!(@resource_types, type) |> Map.fetch!(:index)
    end)
    |> Enum.map(fn {type, resources} ->
      options =
        resources
        |> Enum.sort_by(fn resource -> resource.name end)
        |> Enum.map(&resource_option(&1))

      label = Map.fetch!(@resource_types, type) |> Map.fetch!(:label)

      {label, options}
    end)
  end

  defp resource_option(resource) do
    {resource.id, resource.name, resource}
  end

  def map_filters_form_attrs(attrs, account) do
    attrs =
      if Portal.Account.traffic_filters_enabled?(account) do
        attrs
      else
        Map.put(attrs, "filters", %{})
      end

    Map.update(attrs, "filters", [], fn filters ->
      filters =
        for {id, filter_attrs} <- filters,
            filter_attrs["enabled"] == "true",
            into: %{} do
          {id,
           %{
             "protocol" => filter_attrs["protocol"],
             "ports" => ports_to_list(filter_attrs["ports"])
           }}
        end

      filters
    end)
  end

  defp ports_to_list(nil), do: []

  defp ports_to_list(ports) do
    ports
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  attr :form, :any, required: true
  attr :account, :any, required: true

  def filters_form(assigns) do
    # Code is taken from https://github.com/phoenixframework/phoenix_live_view/blob/v0.19.5/lib/phoenix_component.ex#L2356
    %Phoenix.HTML.FormField{field: field_name, form: parent_form} = assigns.form
    options = assigns |> Map.take([:id, :as, :default, :append, :prepend]) |> Keyword.new()
    options = Keyword.merge(parent_form.options, options)
    forms = parent_form.impl.to_form(parent_form.source, parent_form, field_name, options)

    forms_by_protocol =
      for %Phoenix.HTML.Form{params: params, hidden: hidden} = form <- forms, into: %{} do
        id = Ecto.Changeset.apply_changes(form.source).protocol
        form_id = "#{parent_form.id}_#{field_name}_#{id}"
        new_params = Map.put(params, :protocol, id)
        new_hidden = [{:protocol, id} | hidden]
        new_form = %Phoenix.HTML.Form{form | id: form_id, params: new_params, hidden: new_hidden}
        {id, new_form}
      end

    assigns =
      assigns
      |> Map.put(:forms_by_protocol, forms_by_protocol)
      |> Map.put(
        :traffic_filters_enabled?,
        Portal.Account.traffic_filters_enabled?(assigns.account)
      )

    ~H"""
    <fieldset class="flex flex-col gap-2">
      <div class="mb-1 flex items-center justify-between">
        <legend class="text-xl">Traffic Restriction</legend>

        <%= if @traffic_filters_enabled? == false do %>
          <.link navigate={~p"/#{@account}/settings/billing"} class="text-sm text-primary-500">
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
            </.badge>
          </.link>
        <% end %>
      </div>

      <p class="text-sm text-neutral-500">
        Restrict access to the specified protocols and ports. By default, <strong>all</strong>
        protocols and ports are accessible.
      </p>

      <div class={[
        @traffic_filters_enabled? == false && "opacity-50",
        "mt-4"
      ]}>
        <div class="flex items-top mb-4">
          <.input type="hidden" name={"#{@form.name}[tcp][protocol]"} value="tcp" />
          <div class="mt-2.5 w-24" phx-update="ignore" id="tcp-filter-checkbox">
            <.input
              title="Restrict traffic to TCP traffic"
              type="checkbox"
              name={"#{@form.name}[tcp][enabled]"}
              checked={Map.has_key?(@forms_by_protocol, :tcp)}
              disabled={!@traffic_filters_enabled?}
              label="TCP"
            />
          </div>

          <div class="flex-none">
            <% ports = (@forms_by_protocol[:tcp] || %{ports: %{value: []}})[:ports] %>
            <.input
              type="text"
              inline_errors={true}
              field={ports}
              name={"#{@form.name}[tcp][ports]"}
              value={Enum.any?(ports.value) && pretty_print_ports(ports.value)}
              disabled={!@traffic_filters_enabled? || !Map.has_key?(@forms_by_protocol, :tcp)}
              placeholder="E.g. 80, 443, 8080-8090"
              class="w-96"
            />
            <p class="mt-2 text-xs text-neutral-500">
              List of comma-separated port range(s), Matches all ports if empty.
            </p>
          </div>
        </div>

        <div class="flex items-top mb-4">
          <.input type="hidden" name={"#{@form.name}[udp][protocol]"} value="udp" />
          <div class="mt-2.5 w-24" phx-update="ignore" id="udp-filter-checkbox">
            <.input
              type="checkbox"
              name={"#{@form.name}[udp][enabled]"}
              checked={Map.has_key?(@forms_by_protocol, :udp)}
              disabled={!@traffic_filters_enabled?}
              label="UDP"
            />
          </div>

          <div class="flex-none">
            <% ports = (@forms_by_protocol[:udp] || %{ports: %{value: []}})[:ports] %>
            <.input
              type="text"
              inline_errors={true}
              field={ports}
              name={"#{@form.name}[udp][ports]"}
              value={Enum.any?(ports.value) && pretty_print_ports(ports.value)}
              disabled={!@traffic_filters_enabled? || !Map.has_key?(@forms_by_protocol, :udp)}
              placeholder="E.g. 53, 60000-61000"
              class="w-96"
            />
            <p class="mt-2 text-xs text-neutral-500">
              List of comma-separated port range(s), Matches all ports if empty.
            </p>
          </div>
        </div>

        <div class="flex items-top mb-4">
          <.input type="hidden" name={"#{@form.name}[icmp][protocol]"} value="icmp" />

          <div class="mt-2.5 w-24" phx-update="ignore" id="icmp-filter-checkbox">
            <.input
              title="Allow ICMP echo requests/replies"
              type="checkbox"
              name={"#{@form.name}[icmp][enabled]"}
              checked={Map.has_key?(@forms_by_protocol, :icmp)}
              disabled={!@traffic_filters_enabled?}
              label="ICMP echo"
            />
          </div>
        </div>
      </div>
    </fieldset>
    """
  end

  attr :form, :any, required: true

  def ip_stack_form(assigns) do
    ~H"""
    <div>
      <legend class="text-xl mb-4">IP Stack</legend>
      <p class="text-sm text-neutral-500 mb-4">
        Determines what
        <.website_link path="/kb/deploy/resources" fragment="ip-stack">record types</.website_link>
        are generated by the stub resolver. If unsure, leave this unchanged.
      </p>
      <div class="mb-2">
        <.input
          id="resource-ip-stack--dual"
          type="radio"
          field={@form[:ip_stack]}
          value="dual"
          checked={"#{@form[:ip_stack].value}" == "" or "#{@form[:ip_stack].value}" == "dual"}
        >
          <label>
            <span class="font-medium">Dual-stack:</span>
            <.code class="text-xs">A</.code>
            and
            <.code class="text-xs">AAAA</.code>
            records
            <span :if={ip_stack_recommendation(@form) == "dual"}>
              <.badge type="info">Recommended for this Resource</.badge>
            </span>
          </label>
        </.input>
      </div>
      <div class="mb-2">
        <.input
          id="resource-ip-stack--ipv4-only"
          type="radio"
          field={@form[:ip_stack]}
          value="ipv4_only"
          checked={"#{@form[:ip_stack].value}" == "ipv4_only"}
        >
          <label>
            <span class="font-medium">IPv4:</span>
            <.code class="text-xs">A</.code>
            records only
            <span :if={ip_stack_recommendation(@form) == "ipv4_only"}>
              <.badge type="info">Recommended for this Resource</.badge>
            </span>
          </label>
        </.input>
      </div>
      <div class="mb-2">
        <.input
          id="resource-ip-stack--ipv6-only"
          type="radio"
          field={@form[:ip_stack]}
          value="ipv6_only"
          checked={"#{@form[:ip_stack].value}" == "ipv6_only"}
        >
          <label>
            <span class="font-medium">IPv6:</span>
            <.code class="text-xs">AAAA</.code>
            records only
            <span :if={ip_stack_recommendation(@form) == "ipv6_only"}>
              <.badge type="info">Recommended for this Resource</.badge>
            </span>
          </label>
        </.input>
      </div>
    </div>
    """
  end

  attr :filter, :any, required: true

  def filter_description(assigns) do
    ~H"""
    <code>{pretty_print_filter(@filter)}</code>
    """
  end

  defp pretty_print_filter(%{protocol: :icmp}),
    do: "ICMP: Allowed"

  defp pretty_print_filter(%{protocol: :tcp, ports: ports}),
    do: "TCP: #{pretty_print_ports(ports)}"

  defp pretty_print_filter(%{protocol: :udp, ports: ports}),
    do: "UDP: #{pretty_print_ports(ports)}"

  defp pretty_print_ports([]), do: "All ports allowed"
  defp pretty_print_ports(ports), do: Enum.join(ports, ", ")

  attr :form, :any, required: true
  attr :sites, :list, required: true
  attr :rest, :global

  def site_form(assigns) do
    ~H"""
    <.input
      field={@form[:site_id]}
      type="select"
      label="Site"
      options={
        Enum.map(@sites, fn site ->
          {site.name, site.id}
        end)
      }
      placeholder="Select a Site"
      required
      {@rest}
    />
    """
  end

  attr :selected_clients, :list, required: true
  attr :client_search_results, :any, default: nil
  attr :client_search, :string, default: ""

  def client_picker(assigns) do
    ~H"""
    <div class="border border-neutral-200 rounded-sm">
      <div
        class="p-3 bg-neutral-50 border-b border-neutral-200 relative"
        phx-click-away="blur_client_search"
      >
        <input
          type="text"
          name="client_search"
          value={@client_search}
          placeholder="Search clients to add..."
          phx-change="search_client"
          phx-debounce="300"
          phx-focus="focus_client_search"
          autocomplete="off"
          data-1p-ignore
          class="block w-full rounded-md border-neutral-300 focus:border-accent-400 focus:ring-3 focus:ring-accent-200/50 text-neutral-900 text-sm"
        />

        <div
          :if={@client_search_results != nil}
          class="absolute z-10 left-3 right-3 mt-1 bg-white border border-neutral-300 rounded-md shadow-md max-h-48 overflow-y-auto"
        >
          <button
            :for={client <- @client_search_results}
            type="button"
            phx-click="add_client"
            phx-value-client_id={client.id}
            class="w-full text-left px-3 py-2 hover:bg-accent-50 border-b border-neutral-100 last:border-b-0"
          >
            <div class="flex items-center gap-2">
              <div class={[
                "w-2 h-2 rounded-full flex-shrink-0",
                if(client.online?, do: "bg-green-500", else: "bg-red-500")
              ]} />
              <div class="space-y-0.5 min-w-0">
                <div class="text-sm font-medium text-neutral-900">{client.name}</div>
                <div class="text-xs text-neutral-500">
                  {client_details(client)}
                </div>
              </div>
            </div>
          </button>
          <div
            :if={@client_search_results == []}
            class="px-3 py-4 text-center text-sm text-neutral-500"
          >
            No clients found
          </div>
        </div>
      </div>

      <ul :if={@selected_clients != []} class="divide-y divide-neutral-200 max-h-64 overflow-y-auto">
        <li :for={client <- @selected_clients} class="p-3 flex items-center justify-between">
          <div class="min-w-0">
            <p class="text-sm font-medium text-neutral-900 truncate">{client.name}</p>
            <p class="text-xs text-neutral-500 truncate">{client_details(client)}</p>
          </div>
          <button
            type="button"
            phx-click="remove_client"
            phx-value-client_id={client.id}
            class="text-xs text-red-600 hover:text-red-700"
          >
            Remove
          </button>
        </li>
      </ul>

      <div :if={@selected_clients == []} class="p-4 text-sm text-neutral-500">
        No devices selected.
      </div>
    </div>
    """
  end

  defp client_details(client) do
    [
      client.ipv4 && Portal.Types.INET.to_string(client.ipv4),
      client.ipv6 && Portal.Types.INET.to_string(client.ipv6),
      client.device_serial,
      client.device_uuid,
      client.id
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" | ")
  end

  @known_recommendations %{
    "mongodb.net" => "ipv4_only"
  }

  defp ip_stack_recommendation(form) do
    if address = form[:address].value do
      @known_recommendations
      |> Enum.find_value(fn {key, value} ->
        String.ends_with?(String.trim(address), key) && value
      end)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Device, Features, Resource, Safe, StaticDevicePoolMember}

    def get_resource!(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def list_resources(subject, opts \\ []) do
      from(r in Resource, as: :resources)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(Database.ListQuery, opts)
    end

    def client_to_client_enabled?(account) do
      query = from(f in Features, where: f.feature == :client_to_client and f.enabled == true)

      account_feature_enabled? = account.features.client_to_client == true

      Safe.unscoped(query, :replica) |> Safe.exists?() and account_feature_enabled?
    end

    def all_sites(subject) do
      from(s in Portal.Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def get_client(client_id, subject) do
      from(c in Device, as: :clients)
      |> where([clients: c], c.type == :client)
      |> where([clients: c], c.id == ^client_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def search_clients(search_term, _subject, _selected_clients) when search_term in [nil, ""],
      do: nil

    def search_clients(search_term, subject, selected_clients) do
      selected_ids = Enum.map(selected_clients, & &1.id)
      pattern = "%#{search_term}%"

      query =
        from(c in Device, as: :clients)
        |> where([clients: c], c.type == :client)
        |> join(:inner, [clients: c], a in assoc(c, :actor), as: :actors)
        |> where([clients: c], c.id not in ^selected_ids)
        |> where(^client_search_filter(pattern))
        |> limit(10)

      case query |> Safe.scoped(subject, :replica) |> Safe.all() do
        {:error, _} ->
          []

        clients ->
          clients
          |> Portal.Presence.Clients.preload_clients_presence()
          |> Enum.sort_by(&if &1.online?, do: 0, else: 1)
      end
    end

    defp client_search_filter(pattern) do
      dynamic(
        [clients: c, actors: a],
        ilike(c.name, ^pattern) or
          ilike(a.name, ^pattern) or
          ilike(coalesce(a.email, ""), ^pattern) or
          ilike(type(c.id, :string), ^pattern) or
          ilike(coalesce(c.firezone_id, ""), ^pattern) or
          ilike(coalesce(c.device_serial, ""), ^pattern) or
          ilike(coalesce(c.device_uuid, ""), ^pattern) or
          ilike(coalesce(c.identifier_for_vendor, ""), ^pattern) or
          ilike(coalesce(c.firebase_installation_id, ""), ^pattern) or
          ilike(type(c.ipv4, :string), ^pattern) or
          ilike(type(c.ipv6, :string), ^pattern)
      )
    end

    def validate_selected_clients([], _subject), do: {:ok, []}

    def validate_selected_clients(selected_clients, subject) do
      ids =
        selected_clients
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      from(c in Device, as: :clients)
      |> where([clients: c], c.type == :client)
      |> where([clients: c], c.id in ^ids)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} ->
          {:error, :invalid_clients}

        clients when length(clients) == length(ids) ->
          {:ok, clients}

        _ ->
          {:error, :invalid_clients}
      end
    end

    def validate_static_device_pool_feature_enabled(changeset, account) do
      if Ecto.Changeset.get_field(changeset, :type) == :static_device_pool and
           not client_to_client_enabled?(account) do
        Ecto.Changeset.add_error(
          changeset,
          :type,
          "device pools are not enabled for this account"
        )
      else
        changeset
      end
    end

    def sync_static_pool_members(
          %Portal.Resource{type: :static_device_pool} = resource,
          clients,
          subject
        ) do
      selected_client_ids = clients |> Enum.map(& &1.id) |> Enum.uniq()

      existing_client_ids =
        from(m in StaticDevicePoolMember,
          where: m.resource_id == ^resource.id,
          select: m.device_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, _} -> []
          ids -> ids
        end

      to_remove = existing_client_ids -- selected_client_ids
      to_add = selected_client_ids -- existing_client_ids

      with :ok <- maybe_delete_pool_members(resource, to_remove, subject),
           :ok <- maybe_insert_pool_members(resource, to_add, subject) do
        :ok
      end
    end

    def sync_static_pool_members(%Portal.Resource{} = resource, _clients, subject) do
      case from(m in StaticDevicePoolMember, where: m.resource_id == ^resource.id)
           |> Safe.scoped(subject)
           |> Safe.delete_all() do
        {:error, reason} -> {:error, reason}
        {_, _} -> :ok
      end
    end

    defp maybe_delete_pool_members(_resource, [], _subject), do: :ok

    defp maybe_delete_pool_members(resource, to_remove, subject) do
      case from(m in StaticDevicePoolMember,
             where: m.resource_id == ^resource.id and m.device_id in ^to_remove
           )
           |> Safe.scoped(subject)
           |> Safe.delete_all() do
        {:error, reason} -> {:error, reason}
        {_, _} -> :ok
      end
    end

    defp maybe_insert_pool_members(_resource, [], _subject), do: :ok

    defp maybe_insert_pool_members(resource, to_add, subject) do
      entries =
        Enum.map(to_add, fn device_id ->
          %{
            account_id: resource.account_id,
            resource_id: resource.id,
            device_id: device_id,
            device_type: :client,
            id: Ecto.UUID.generate()
          }
        end)

      case Safe.scoped(subject)
           |> Safe.insert_all(StaticDevicePoolMember, entries,
             on_conflict: :nothing,
             conflict_target: [:account_id, :resource_id, :device_id]
           ) do
        {:error, reason} -> {:error, reason}
        {_, _} -> :ok
      end
    end
  end

  defmodule Database.ListQuery do
    import Ecto.Query
    import Portal.Repo.Query

    def cursor_fields do
      [
        {:resources, :asc, :name},
        {:resources, :asc, :id}
      ]
    end

    def preloads, do: []

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name_or_address,
          title: "Name or Address",
          type: {:string, :websearch},
          fun: &filter_by_name_fts_or_address/2
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
  end
end
