defmodule PortalWeb.Resources.Components do
  use PortalWeb, :component_library
  alias __MODULE__.DB

  @resource_types %{
    internet: %{index: 1, label: nil},
    dns: %{index: 2, label: "DNS"},
    ip: %{index: 3, label: "IP"},
    cidr: %{index: 4, label: "CIDR"}
  }

  def fetch_resource_option(id, subject) do
    resource = DB.get_resource!(id, subject)
    {:ok, resource_option(resource)}
  end

  def list_resource_options(search_query_or_nil, subject) do
    filter =
      if search_query_or_nil != "" and search_query_or_nil != nil,
        do: [name_or_address: search_query_or_nil],
        else: []

    {:ok, resources, metadata} =
      DB.list_resources(subject,
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
      for form <- forms, into: %{} do
        %Phoenix.HTML.Form{params: params} = form
        id = Ecto.Changeset.apply_changes(form.source).protocol
        form_id = "#{parent_form.id}_#{field_name}_#{id}"
        new_params = Map.put(params, :protocol, id)
        new_hidden = [{:protocol, id} | form.hidden]
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

  @known_recommendations %{
    "mongodb.net" => "ipv4_only"
  }

  defp ip_stack_recommendation(form) do
    if address = form[:address].value do
      @known_recommendations
      |> Enum.find_value(fn {key, value} ->
        if String.ends_with?(String.trim(address), key), do: value
      end)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Safe, Resource}

    def get_resource!(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def list_resources(subject, opts \\ []) do
      from(r in Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(DB.ListQuery, opts)
    end
  end

  defmodule DB.ListQuery do
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
