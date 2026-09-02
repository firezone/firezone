defmodule PortalWeb.Resources.Components do
  use PortalWeb, :component_library

  import PortalWeb.Policies.Components,
    only: [
      grant_condition_card: 1,
      available_conditions: 1,
      condition_type_label: 1,
      flow_log_uploads_toggle: 1
    ]

  import PortalWeb.Devices.Components,
    only: [
      device_status_badge: 1,
      device_verified_badge: 1,
      device_os: 1
    ]

  alias __MODULE__.Database
  alias Portal.Presence

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

  def nil_site_label(%{type: :static_device_pool}), do: "No Site Needed"
  def nil_site_label(_resource), do: "No Site Associated"

  def map_filters_form_attrs(attrs) do
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

    assigns = Map.put(assigns, :forms_by_protocol, forms_by_protocol)

    ~H"""
    <fieldset class="flex flex-col gap-2">
      <div class="mb-1 flex items-center justify-between">
        <legend class="text-xl">Traffic Restriction</legend>
      </div>

      <p class="text-sm text-neutral-500">
        Restrict access to the specified protocols and ports. By default, <strong>all</strong>
        protocols and ports are accessible.
      </p>

      <div class="mt-4">
        <div class="flex items-top mb-4">
          <.input type="hidden" name={"#{@form.name}[tcp][protocol]"} value="tcp" />
          <div class="mt-2.5 w-24" phx-update="ignore" id="tcp-filter-checkbox">
            <.toggle
              id="tcp-filter-toggle"
              title="Restrict traffic to TCP traffic"
              name={"#{@form.name}[tcp][enabled]"}
              value="true"
              checked={Map.has_key?(@forms_by_protocol, :tcp)}
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
              disabled={!Map.has_key?(@forms_by_protocol, :tcp)}
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
            <.toggle
              id="udp-filter-toggle"
              name={"#{@form.name}[udp][enabled]"}
              value="true"
              checked={Map.has_key?(@forms_by_protocol, :udp)}
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
              disabled={!Map.has_key?(@forms_by_protocol, :udp)}
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
            <.toggle
              id="icmp-filter-toggle"
              title="Allow ICMP echo requests/replies"
              name={"#{@form.name}[icmp][enabled]"}
              value="true"
              checked={Map.has_key?(@forms_by_protocol, :icmp)}
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

  attr :form, :any, required: true
  attr :resource, :any, default: nil

  def resource_type_picker(assigns) do
    ~H"""
    <div :if={is_nil(@resource) || @resource.type != :internet}>
      <span class="block text-xs font-medium text-body mb-1.5">
        Type <span class="text-error">*</span>
      </span>
      <ul class="grid w-full gap-3 grid-cols-4">
        <li>
          <.input
            id="resource-form-type--dns"
            type="radio_button_group"
            field={@form[:type]}
            value="dns"
            checked={to_string(@form[:type].value) == "dns"}
            required
          />
          <label
            for="resource-form-type--dns"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="ri-global-line" class="w-4 h-4 mr-1" /> DNS
              </div>
              <div class="w-full text-[10px]">
                By DNS address
              </div>
            </div>
          </label>
        </li>
        <li>
          <.input
            id="resource-form-type--ip"
            type="radio_button_group"
            field={@form[:type]}
            value="ip"
            checked={to_string(@form[:type].value) == "ip"}
            required
          />
          <label
            for="resource-form-type--ip"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="ri-server-line" class="w-4 h-4 mr-1" /> IP
              </div>
              <div class="w-full text-[10px]">
                By IP address
              </div>
            </div>
          </label>
        </li>
        <li>
          <.input
            id="resource-form-type--cidr"
            type="radio_button_group"
            field={@form[:type]}
            value="cidr"
            checked={to_string(@form[:type].value) == "cidr"}
            required
          />
          <label
            for="resource-form-type--cidr"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="ri-server-line" class="w-4 h-4 mr-1" /> CIDR
              </div>
              <div class="w-full text-[10px]">
                By CIDR range
              </div>
            </div>
          </label>
        </li>
        <li>
          <.input
            id="resource-form-type--static-device-pool"
            type="radio_button_group"
            field={@form[:type]}
            value="static_device_pool"
            checked={to_string(@form[:type].value) == "static_device_pool"}
            required
          />
          <label
            for="resource-form-type--static-device-pool"
            class="inline-flex items-center justify-between w-full p-3 text-body bg-surface border border-border rounded cursor-pointer peer-checked:border-brand peer-checked:text-brand hover:text-heading hover:bg-raised transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs flex items-center">
                <.icon name="ri-computer-line" class="w-4 h-4 mr-1" /> Device Pool
                <span class="ml-1.5 px-1 py-px rounded text-[9px] font-semibold tracking-wider bg-brand-muted text-brand">
                  NEW
                </span>
              </div>
              <div class="w-full text-[10px]">
                Peer-to-peer, no Site
              </div>
            </div>
          </label>
        </li>
      </ul>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :resource, :any, default: nil

  def resource_core_fields(assigns) do
    ~H"""
    <div>
      <label
        for={@form[:name].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Name <span class="text-error">*</span>
      </label>
      <.input
        field={@form[:name]}
        type="text"
        placeholder="Name this resource"
        phx-debounce="300"
        required
      />
    </div>

    <div :if={
      (is_nil(@resource) || @resource.type != :internet) &&
        to_string(@form[:type].value) != "static_device_pool"
    }>
      <label
        for={@form[:address].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Address <span class="text-error">*</span>
      </label>
      <.input
        field={@form[:address]}
        autocomplete="off"
        placeholder={
          cond do
            to_string(@form[:type].value) == "dns" -> "gitlab.company.com"
            to_string(@form[:type].value) == "cidr" -> "10.0.0.0/24"
            to_string(@form[:type].value) == "ip" -> "10.3.2.1"
            true -> "First select a type above"
          end
        }
        disabled={is_nil(@form[:type].value)}
        phx-debounce="300"
        required
        class="font-mono"
      />
    </div>

    <div :if={
      (is_nil(@resource) || @resource.type != :internet) &&
        to_string(@form[:type].value) != "static_device_pool"
    }>
      <label
        for={@form[:address_description].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Address Description <span class="text-muted font-normal">(optional)</span>
      </label>
      <.input
        field={@form[:address_description]}
        type="text"
        placeholder="Enter a description or URL"
        phx-debounce="300"
      />
      <p class="mt-1 text-xs text-subtle">
        Optional description or URL shown in Clients.
      </p>
    </div>
    """
  end

  attr :selected_devices, :list, required: true
  attr :device_search_results, :any, default: nil
  attr :device_search, :string, default: ""

  def resource_device_pool_section(assigns) do
    ~H"""
    <div>
      <span class="block text-xs font-medium text-body mb-1.5">
        Devices <span class="text-muted font-normal">(optional)</span>
      </span>
      <p class="mb-2 text-xs text-subtle">
        Select devices to include in this pool.
      </p>
      <.device_picker
        selected_devices={@selected_devices}
        device_search={@device_search}
        device_search_results={@device_search_results}
      />
    </div>
    """
  end

  attr :form, :any, required: true

  def resource_dns_ip_stack_section(assigns) do
    ~H"""
    <div>
      <%!-- Hidden radio inputs for form submission --%>
      <.input
        id="resource-form-ip-stack--dual"
        type="radio_button_group"
        field={@form[:ip_stack]}
        value="dual"
        checked={"#{@form[:ip_stack].value}" == "" or "#{@form[:ip_stack].value}" == "dual"}
      />
      <.input
        id="resource-form-ip-stack--ipv4"
        type="radio_button_group"
        field={@form[:ip_stack]}
        value="ipv4_only"
        checked={"#{@form[:ip_stack].value}" == "ipv4_only"}
      />
      <.input
        id="resource-form-ip-stack--ipv6"
        type="radio_button_group"
        field={@form[:ip_stack]}
        value="ipv6_only"
        checked={"#{@form[:ip_stack].value}" == "ipv6_only"}
      />
      <span class="block text-xs font-medium text-body mb-1.5">
        IP Stack
      </span>
      <div class="inline-flex rounded border border-border overflow-hidden">
        <label
          for="resource-form-ip-stack--dual"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-border first:border-l-0 cursor-pointer",
            if(
              "#{@form[:ip_stack].value}" == "" or "#{@form[:ip_stack].value}" == "dual",
              do: "bg-brand text-white",
              else:
                "bg-surface text-body hover:text-heading"
            )
          ]}
        >
          Both
        </label>
        <label
          for="resource-form-ip-stack--ipv4"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-border first:border-l-0 cursor-pointer",
            if(
              "#{@form[:ip_stack].value}" == "ipv4_only",
              do: "bg-brand text-white",
              else:
                "bg-surface text-body hover:text-heading"
            )
          ]}
        >
          IPv4
        </label>
        <label
          for="resource-form-ip-stack--ipv6"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-border first:border-l-0 cursor-pointer",
            if(
              "#{@form[:ip_stack].value}" == "ipv6_only",
              do: "bg-brand text-white",
              else:
                "bg-surface text-body hover:text-heading"
            )
          ]}
        >
          IPv6
        </label>
      </div>
      <p class="mt-1.5 text-xs text-body leading-snug">
        {case "#{@form[:ip_stack].value}" do
          "ipv4_only" ->
            "Resolves only A records. Clients connect over IPv4."

          "ipv6_only" ->
            "Resolves only AAAA records. Clients connect over IPv6."

          _ ->
            "Resolves A and AAAA records. Clients connect over IPv4 or IPv6, whichever is available. We recommend setting this to IPv4-only if you experience connectivity issues."
        end}
      </p>
    </div>
    """
  end

  attr :resource, :any, default: nil
  attr :form, :any, required: true
  attr :active_protocols, :list, default: []
  attr :filters_dropdown_open, :boolean, default: false
  attr :filter_ports, :map, default: %{}
  attr :filter_errors, :map, default: %{}

  def resource_traffic_restrictions_section(assigns) do
    ~H"""
    <div :if={is_nil(@resource) || @resource.type != :internet}>
      <div class="flex items-center justify-between mb-2">
        <span class="block text-xs font-medium text-body">
          Traffic Restrictions <span class="font-normal text-subtle">(optional)</span>
        </span>
        <div class="relative">
          <.button
            type="button"
            phx-click="toggle_resource_filters_dropdown"
            size="xs"
            icon="ri-add-line"
          >
             Add protocol
            <.icon name="ri-arrow-down-s-line" class="w-3 h-3" />
          </.button>
          <div
            :if={@filters_dropdown_open}
            phx-click-away="close_resource_filters_dropdown"
            class="absolute right-0 top-full mt-1 z-20 bg-elevated border border-border rounded shadow-md min-w-[120px]"
          >
            <button
              :if={:tcp not in @active_protocols}
              type="button"
              phx-click="add_resource_filter"
              phx-value-protocol="tcp"
              class="flex items-center w-full px-3 py-2 text-xs text-heading hover:bg-raised transition-colors"
            >
              TCP
            </button>
            <button
              :if={:udp not in @active_protocols}
              type="button"
              phx-click="add_resource_filter"
              phx-value-protocol="udp"
              class="flex items-center w-full px-3 py-2 text-xs text-heading hover:bg-raised transition-colors"
            >
              UDP
            </button>
            <button
              :if={:icmp not in @active_protocols}
              type="button"
              phx-click="add_resource_filter"
              phx-value-protocol="icmp"
              class="flex items-center w-full px-3 py-2 text-xs text-heading hover:bg-raised transition-colors"
            >
              ICMP
            </button>
            <div
              :if={
                :tcp in @active_protocols and :udp in @active_protocols and :icmp in @active_protocols
              }
              class="px-3 py-2 text-xs text-subtle"
            >
              All protocols added
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@active_protocols == []}
        class="flex items-center justify-center rounded border border-dashed border-border-strong px-4 py-5 text-xs text-subtle"
      >
        No restrictions — All protocols/ports permitted
      </div>

      <div :if={@active_protocols != []} class="flex flex-col gap-2">
        <div
          :for={protocol <- @active_protocols}
          class="flex items-center gap-2 rounded border border-border bg-surface px-3 py-2"
        >
          <input type="hidden" name={"resource[filters][#{protocol}][enabled]"} value="true" />
          <input
            type="hidden"
            name={"resource[filters][#{protocol}][protocol]"}
            value={"#{protocol}"}
          />
          <span class="w-10 shrink-0 text-xs font-medium text-heading uppercase">
            {protocol}
          </span>
          <div :if={protocol != :icmp} class="flex-1">
            <input
              type="text"
              name={"resource[filters][#{protocol}][ports]"}
              value={Map.get(@filter_ports, protocol, "")}
              placeholder="All ports"
              class={[
                "w-full px-3 py-2 text-sm rounded-md border font-mono bg-input text-heading placeholder:text-muted outline-none transition-colors focus:ring-1 focus:ring-border-focus/30",
                if(Map.has_key?(@filter_errors, protocol),
                  do: "border-error focus:border-error",
                  else: "border-input-border focus:border-border-focus"
                )
              ]}
            />
            <p
              :if={Map.has_key?(@filter_errors, protocol)}
              class="mt-1 text-xs text-error"
            >
              {Map.get(@filter_errors, protocol)}
            </p>
          </div>
          <span
            :if={protocol == :icmp}
            class="flex-1 text-xs text-subtle italic"
          >
            echo request/reply
          </span>
          <button
            type="button"
            phx-click="remove_resource_filter"
            phx-value-protocol={"#{protocol}"}
            class="shrink-0 text-subtle hover:text-heading transition-colors"
            aria-label={"Remove #{protocol} filter"}
          >
            <.icon name="ri-close-line" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :sites, :list, required: true

  def resource_site_selector(assigns) do
    ~H"""
    <div :if={to_string(@form[:type].value) != "static_device_pool"}>
      <label
        for={@form[:site_id].id}
        class="block text-xs font-medium text-body mb-1.5"
      >
        Site <span class="text-error">*</span>
      </label>
      <.input
        field={@form[:site_id]}
        type="select"
        options={Enum.map(@sites, fn s -> {s.name, s.id} end)}
        prompt="Select a Site"
        required
      />
    </div>
    """
  end

  attr :selected_devices, :list, required: true
  attr :device_search_results, :any, default: nil
  attr :device_search, :string, default: ""

  def device_picker(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="relative mb-2" phx-click-away="blur_device_search">
        <.icon
          name="ri-search-line"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-subtle pointer-events-none"
        />
        <input
          type="text"
          name="device_search"
          value={@device_search}
          placeholder="Search devices to add…"
          phx-change="search_device"
          phx-debounce="300"
          phx-focus="focus_device_search"
          autocomplete="off"
          data-1p-ignore
          class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-border bg-raised text-heading placeholder:text-muted outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors"
        />
      </div>

      <ul :if={@selected_devices != []} class="space-y-1 mb-1">
        <li :for={device <- @selected_devices}>
          <div class="flex items-center gap-3 px-3 py-2.5 rounded-lg border border-brand bg-brand-muted">
            <div class="flex items-center justify-center w-7 h-7 rounded-full bg-raised border border-border shrink-0">
              <.icon name="ri-computer-line" class="w-4 h-4 text-brand" />
            </div>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-brand truncate">{device.name}</p>
              <p class="text-[10px] text-subtle truncate">{device_details(device)}</p>
            </div>
            <button
              type="button"
              phx-click="remove_device"
              phx-value-device_id={device.id}
              class="shrink-0 flex items-center justify-center w-5 h-5 rounded text-brand/50 hover:text-brand transition-colors"
              aria-label="Remove device"
            >
              <.icon name="ri-close-line" class="w-3.5 h-3.5" />
            </button>
          </div>
        </li>
      </ul>

      <ul :if={@device_search_results != nil && @device_search_results != []} class="space-y-1">
        <li :for={device <- @device_search_results}>
          <button
            type="button"
            phx-click="add_device"
            phx-value-device_id={device.id}
            class="flex items-center gap-3 px-3 py-2.5 w-full rounded-lg border border-border bg-raised hover:border-border-emphasis hover:bg-surface cursor-pointer transition-colors"
          >
            <div class="flex items-center justify-center w-7 h-7 rounded-full bg-raised border border-border shrink-0">
              <.icon name="ri-computer-line" class="w-4 h-4 text-subtle" />
            </div>
            <div class="flex-1 min-w-0 text-left">
              <p class="text-sm font-medium text-heading truncate">{device.name}</p>
              <p class="text-[10px] text-subtle truncate">{device_details(device)}</p>
            </div>
            <span class={[
              "w-1.5 h-1.5 rounded-full shrink-0",
              if(device.online?, do: "bg-success", else: "bg-neutral-status")
            ]} />
          </button>
        </li>
      </ul>

      <div
        :if={@device_search_results == []}
        class="flex items-center justify-center h-16 text-xs text-subtle"
      >
        No devices found
      </div>

      <div
        :if={@selected_devices == [] && is_nil(@device_search_results)}
        class="flex items-center justify-center h-12 text-xs text-subtle"
      >
        Search above to add devices
      </div>
    </div>
    """
  end

  defp device_details(device) do
    [
      Portal.Types.INET.to_string(device.ipv4),
      Portal.Types.INET.to_string(device.ipv6),
      device.device_serial,
      device.device_uuid,
      device.id
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

  attr :open, :boolean, required: true
  slot :inner_block, required: true

  def panel_shell(assigns) do
    ~H"""
    <div
      id="resource-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-elevated border-l border-border-strong",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@open, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :account, :any, required: true
  attr :resource, :any, default: nil
  attr :panel_view, :atom, required: true
  attr :form_state, :map, required: true

  def resource_form_panel(assigns) do
    assigns = assign(assigns, assigns.form_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-heading">
            {if @panel_view == :new_form, do: "Add Resource", else: "Edit Resource"}
          </h2>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="cancel_resource_form" />
        </div>
      </div>
      <.form
        id="resource-form"
        for={@resource_form}
        phx-submit="submit_resource_form"
        phx-change="change_resource_form"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <.resource_type_picker form={@resource_form} resource={@resource} />

          <.resource_core_fields form={@resource_form} resource={@resource} />

          <.resource_device_pool_section
            :if={to_string(@resource_form[:type].value) == "static_device_pool"}
            selected_devices={@resource_form_selected_devices}
            device_search={@resource_form_device_search}
            device_search_results={@resource_form_device_search_results}
          />

          <.resource_dns_ip_stack_section
            :if={"#{@resource_form[:type].value}" == "dns"}
            form={@resource_form}
          />

          <.resource_traffic_restrictions_section
            resource={@resource}
            form={@resource_form}
            active_protocols={@resource_form_active_protocols}
            filters_dropdown_open={@resource_form_filters_dropdown_open}
            filter_ports={@filter_ports}
            filter_errors={@filter_errors}
          />

          <.resource_site_selector form={@resource_form} sites={@resource_form_sites} />
        </div>

        <.panel_footer>
          <.panel_footer_button type="button" phx-click="cancel_resource_form">
            Cancel
          </.panel_footer_button>
          <.panel_footer_button type="submit" style="primary">
            {if @panel_view == :new_form, do: "Create Resource", else: "Save Changes"}
          </.panel_footer_button>
        </.panel_footer>
      </.form>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :resource, :any, required: true
  attr :pool_member_ids, :list, default: []
  attr :pool_devices, :list, default: []
  attr :devices_expanded_id, :string, default: nil
  attr :online_device_ids, :any, default: %MapSet{}
  attr :presence_tick, :integer, default: 0
  attr :groups, :list, default: []
  attr :policy_authorizations, :list, default: []
  attr :policy_authorizations_page, :integer, default: 1
  attr :policy_authorizations_has_next, :boolean, default: false
  attr :policy_authorizations_expanded_id, :string, default: nil
  attr :panel_view, :atom, required: true
  attr :tab, :atom, default: :groups
  attr :grant_state, :map, required: true
  attr :ui_state, :map, required: true

  def resource_details_panel(assigns) do
    assigns = assign(assigns, assigns.ui_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 py-4 border-b border-border bg-elevated">
        <div class="flex items-center gap-4">
          <%!-- Left: name + status + address --%>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <h2 class="text-sm font-semibold text-heading truncate">
                {@resource.name}
              </h2>
              <.resource_status_badge
                resource={@resource}
                presence_tick={@presence_tick}
                pool_member_ids={@pool_member_ids}
                online_device_ids={@online_device_ids}
              />
            </div>
            <p
              :if={@resource.type != :internet}
              class="font-mono text-xs text-subtle mt-0.5 truncate"
            >
              {@resource.address}
            </p>
          </div>
          <%!-- Right: actions --%>
          <div class="flex items-center gap-1.5 shrink-0">
            <.button
              :if={not @confirm_delete_resource && @resource.type != :internet}
              phx-click="open_edit_form"
              size="sm"
              icon="ri-pencil-line"
            >
              Edit
            </.button>
            <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
          </div>
        </div>
      </div>
      <div class="flex flex-1 min-h-0 divide-x divide-border">
        <div class="flex-1 flex flex-col overflow-hidden">
          <.resource_tabs
            resource={@resource}
            tab={@tab}
            groups_count={length(@groups)}
            devices_count={length(@pool_devices)}
            panel_view={@panel_view}
          />
          <.resource_devices_tab
            :if={@tab == :devices}
            account={@account}
            devices={@pool_devices}
            online_device_ids={@online_device_ids}
            presence_tick={@presence_tick}
            expanded_id={@devices_expanded_id}
          />
          <.resource_access_list
            :if={@tab == :groups && @panel_view == :list}
            account={@account}
            groups={@groups}
            ui_state={@ui_state}
          />
          <.resource_grant_form
            :if={@tab == :groups && @panel_view == :grant_form}
            account={@account}
            resource={@resource}
            grant_state={@grant_state}
          />
          <.resource_policy_authorizations_tab
            :if={@tab == :authorizations}
            policy_authorizations={@policy_authorizations}
            page={@policy_authorizations_page}
            has_next={@policy_authorizations_has_next}
            expanded_id={@policy_authorizations_expanded_id}
            account={@account}
            resource={@resource}
          />
        </div>
        <.resource_sidebar
          account={@account}
          resource={@resource}
          presence_tick={@presence_tick}
          ui_state={@ui_state}
        />
      </div>
    </div>
    """
  end

  attr :resource, :any, required: true
  attr :tab, :atom, required: true
  attr :groups_count, :integer, default: 0
  attr :devices_count, :integer, default: 0
  attr :panel_view, :atom, required: true

  def resource_tabs(assigns) do
    ~H"""
    <div
      role="tablist"
      class="flex items-end gap-0 px-5 border-b border-border bg-raised shrink-0"
    >
      <button
        :if={@resource.type == :static_device_pool}
        role="tab"
        aria-selected={@tab == :devices}
        phx-click="switch_resource_tab"
        phx-value-tab="devices"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :devices,
            do: "border-brand text-brand",
            else: "border-transparent text-body hover:text-heading"
          )
        ]}
      >
        Pool Members
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :devices,
            do: "bg-brand-muted text-brand",
            else: "bg-raised text-subtle"
          )
        ]}>
          {@devices_count}
        </span>
      </button>
      <button
        role="tab"
        aria-selected={@tab == :groups}
        phx-click="switch_resource_tab"
        phx-value-tab="groups"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :groups,
            do: "border-brand text-brand",
            else: "border-transparent text-body hover:text-heading"
          )
        ]}
      >
        Groups
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :groups,
            do: "bg-brand-muted text-brand",
            else: "bg-raised text-subtle"
          )
        ]}>
          {@groups_count}
        </span>
      </button>
      <button
        role="tab"
        aria-selected={@tab == :authorizations}
        phx-click="switch_resource_tab"
        phx-value-tab="authorizations"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :authorizations,
            do: "border-brand text-brand",
            else: "border-transparent text-body hover:text-heading"
          )
        ]}
      >
        Authorizations
      </button>
      <div :if={@tab == :groups && @panel_view == :list} class="ml-auto pb-2 flex items-center">
        <.button phx-click="open_grant_form" size="xs" icon="ri-add-line">
          Grant access
        </.button>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :devices, :list, default: []
  attr :online_device_ids, :any, default: %MapSet{}
  attr :presence_tick, :integer, default: 0
  attr :expanded_id, :string, default: nil

  def resource_devices_tab(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <div
        :if={@devices == []}
        class="flex flex-col items-center justify-center h-full gap-2 px-6 text-center"
      >
        <.icon name="ri-error-warning-line" class="w-8 h-8 text-warning" />
        <p class="text-sm font-medium text-heading">No devices in this pool</p>
        <p class="text-xs text-subtle max-w-sm">
          An empty pool has nothing to connect to, so any Policy granting access to it has no
          effect. Edit this Resource to add devices.
        </p>
      </div>
      <div :if={@devices != []} class="flex-1 overflow-y-auto">
        <table class="w-full text-xs">
          <thead class="sticky top-0 bg-surface z-10">
            <tr class="border-b border-border text-subtle">
              <th class="text-left px-4 py-2 font-medium">Name</th>
              <th class="text-left px-4 py-2 font-medium">Owner</th>
              <th class="text-left px-4 py-2 font-medium">Tunnel IPv4</th>
              <th class="text-left px-4 py-2 font-medium">Status</th>
              <th class="w-6"></th>
            </tr>
          </thead>
          <tbody>
            <%= for device <- @devices do %>
              <tr
                phx-click="toggle_pool_device_row"
                phx-keydown="toggle_pool_device_row"
                phx-key="Enter"
                phx-value-id={device.id}
                tabindex="0"
                class="border-b border-border hover:bg-raised cursor-pointer focus:outline-none focus:bg-raised"
              >
                <td class="px-4 py-2 text-heading">
                  <div class="flex items-center gap-1.5">
                    <span class="truncate">{device.name}</span>
                    <.device_verified_badge device={device} />
                  </div>
                </td>
                <td class="px-4 py-2 text-body">
                  {if device.actor, do: device.actor.name, else: "—"}
                </td>
                <td class="px-4 py-2 text-subtle font-mono">
                  <.copy
                    id={"pool-member-#{device.id}-ipv4"}
                    class="flex items-center gap-1.5"
                  >
                    {device.ipv4}
                  </.copy>
                </td>
                <td class="px-4 py-2">
                  <.device_status_badge
                    device={device}
                    online?={MapSet.member?(@online_device_ids, device.id)}
                  />
                </td>
                <td class="px-4 py-2 text-subtle">
                  <.icon
                    name={
                      if @expanded_id == device.id,
                        do: "ri-arrow-up-s-line",
                        else: "ri-arrow-down-s-line"
                    }
                    class="w-4 h-4"
                  />
                </td>
              </tr>
              <tr :if={@expanded_id == device.id} class="border-b border-border bg-raised">
                <td colspan="5" class="px-4 py-3">
                  <div class="grid grid-cols-2 gap-x-8 gap-y-3 text-xs">
                    <div :if={device.actor}>
                      <p class="text-subtle font-medium mb-1">Owner</p>
                      <.link
                        navigate={~p"/#{@account}/actors/#{device.actor.id}"}
                        class="text-brand hover:underline"
                      >
                        {device.actor.name}
                      </.link>
                      <p :if={device.actor.email} class="text-subtle mt-0.5">
                        {device.actor.email}
                      </p>
                    </div>
                    <div :if={device.last_seen_at}>
                      <p class="text-subtle font-medium mb-1">Operating System</p>
                      <.device_os device={device} />
                    </div>
                    <div>
                      <p class="text-subtle font-medium mb-1">Tunnel IPv4</p>
                      <.copy
                        id={"pool-member-#{device.id}-detail-ipv4"}
                        class="flex items-center gap-1.5 text-heading font-mono"
                      >
                        {device.ipv4}
                      </.copy>
                    </div>
                    <div>
                      <p class="text-subtle font-medium mb-1">Tunnel IPv6</p>
                      <.copy
                        id={"pool-member-#{device.id}-detail-ipv6"}
                        class="flex items-start gap-1.5 text-heading font-mono break-all"
                      >
                        {device.ipv6}
                      </.copy>
                    </div>
                    <div :if={device.last_seen_at}>
                      <p class="text-subtle font-medium mb-1">Last Seen</p>
                      <p class="text-heading">
                        <.relative_datetime datetime={device.last_seen_at} />
                      </p>
                    </div>
                    <div :if={device.device_serial}>
                      <p class="text-subtle font-medium mb-1">Serial Number</p>
                      <p class="text-heading font-mono">{device.device_serial}</p>
                    </div>
                    <div>
                      <p class="text-subtle font-medium mb-1">Device</p>
                      <.link
                        navigate={~p"/#{@account}/devices/#{device.id}"}
                        class="text-brand hover:underline font-mono break-all"
                      >
                        {device.id}
                      </.link>
                    </div>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :groups, :list, default: []
  attr :ui_state, :map, required: true

  def resource_access_list(assigns) do
    assigns = assign(assigns, assigns.ui_state)

    ~H"""
    <div class="flex-1 overflow-y-auto">
      <ul>
        <li
          :for={row <- @groups}
          class={[
            "border-b border-border transition-colors",
            if(@group_actions_open_id == row.group.id, do: "relative z-20", else: "")
          ]}
        >
          <div
            :if={@confirm_remove_group_id == row.group.id}
            class="flex items-center justify-between gap-2 px-4 py-2.5 bg-raised"
          >
            <span class="text-xs text-body truncate">
              Remove <span class="font-medium text-heading">{row.group.name}</span>'s access?
              <span class="block text-subtle">
                All group members will immediately lose access.
              </span>
            </span>
            <div class="flex items-center gap-1.5 shrink-0">
              <.button type="button" phx-click="cancel_remove_group" size="xs">
                Cancel
              </.button>
              <.button
                type="button"
                phx-click="remove_group_access"
                phx-value-group_id={row.group.id}
                style="danger"
                size="xs"
              >
                Remove
              </.button>
            </div>
          </div>
          <div
            :if={@confirm_remove_group_id != row.group.id}
            class="flex items-center gap-1 pr-4 hover:bg-raised group/item"
          >
            <.link
              navigate={~p"/#{@account}/groups/#{row.group.id}"}
              class={[
                "flex items-center gap-3 px-5 py-3 flex-1 min-w-0",
                row.policy_is_disabled && "opacity-50 hover:opacity-75"
              ]}
            >
              <.provider_icon provider={provider_type_from_group(row)} size="sm" variant="circle" />
              <div class="flex-1 min-w-0 flex items-center gap-2">
                <p class="text-sm font-medium text-heading group-hover/item:text-brand transition-colors truncate">
                  {row.group.name}
                </p>
                <span
                  :if={row.policy_is_disabled}
                  class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-neutral-status-light text-subtle"
                >
                  disabled
                </span>
              </div>
            </.link>
            <div class="relative shrink-0">
              <button
                type="button"
                phx-click="toggle_group_actions"
                phx-value-group_id={row.group.id}
                class="flex items-center justify-center w-6 h-6 rounded text-subtle hover:text-heading hover:bg-surface transition-colors"
                title="More actions"
              >
                <.icon name="ri-more-2-line" class="w-3.5 h-3.5" />
              </button>
              <div
                :if={@group_actions_open_id == row.group.id}
                phx-click-away="close_group_actions"
                class="absolute right-0 top-full mt-1 w-40 rounded-md border border-border bg-elevated shadow-lg z-10 py-1"
              >
                <button
                  :if={!row.policy_is_disabled}
                  type="button"
                  phx-click="disable_policy"
                  phx-value-group_id={row.group.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-body hover:text-heading hover:bg-raised transition-colors"
                >
                  <.icon name="ri-pause-line" class="w-3.5 h-3.5 shrink-0" /> Disable Access
                </button>
                <button
                  :if={row.policy_is_disabled}
                  type="button"
                  phx-click="enable_policy"
                  phx-value-group_id={row.group.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-body hover:text-heading hover:bg-raised transition-colors"
                >
                  <.icon name="ri-play-line" class="w-3.5 h-3.5 shrink-0" /> Enable Access
                </button>
                <button
                  type="button"
                  phx-click="confirm_remove_group"
                  phx-value-group_id={row.group.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-error hover:bg-raised transition-colors"
                >
                  <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Remove access
                </button>
              </div>
            </div>
          </div>
        </li>
      </ul>
      <div
        :if={@groups == []}
        class="flex items-center justify-center h-32 text-sm text-subtle"
      >
        No groups have access yet.
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :resource, :any, required: true
  attr :grant_state, :map, required: true

  def resource_grant_form(assigns) do
    assigns = assign(assigns, assigns.grant_state)

    assigns =
      assign(
        assigns,
        :policy_conditions_enabled?,
        Portal.Account.policy_conditions_enabled?(assigns.account)
      )

    assigns =
      assign(assigns, :conditions_state, %{
        timezone: assigns.timezone,
        location_search: assigns.location_search,
        location_operator: assigns.location_operator,
        location_values: assigns.location_values,
        ip_range_operator: assigns.ip_range_operator,
        ip_range_values: assigns.ip_range_values,
        ip_range_input: assigns.ip_range_input,
        auth_provider_operator: assigns.auth_provider_operator,
        auth_provider_values: assigns.auth_provider_values,
        tod_values: assigns.tod_values,
        tod_adding: assigns.tod_adding?,
        tod_pending: assigns.tod_pending,
        tod_pending_error: assigns.tod_pending_error
      })

    ~H"""
    <div class="flex items-center justify-between px-5 py-2.5 border-b border-border bg-raised shrink-0">
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="close_grant_form"
          class="flex items-center justify-center w-5 h-5 rounded text-subtle hover:text-heading hover:bg-surface transition-colors"
          title="Back to group list"
        >
          <.icon name="ri-arrow-left-s-line" class="w-3.5 h-3.5" />
        </button>
        <span class="text-xs font-semibold text-heading">Grant access</span>
      </div>
    </div>
    <.form
      for={@grant_form}
      phx-submit="submit_grant"
      id="grant-form"
      class="flex-1 flex flex-col overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto">
        <div class="px-5 py-4 space-y-5">
          <div>
            <label class="block text-xs font-medium text-body mb-2">
              Groups <span class="text-error">*</span>
            </label>
            <% filtered_available =
              @available_groups
              |> Enum.reject(&(&1.group.id in @grant_selected_group_ids))
              |> then(fn groups ->
                if @grant_search == "" do
                  groups
                else
                  Enum.filter(groups, fn row ->
                    String.contains?(
                      String.downcase(row.group.name),
                      String.downcase(@grant_search)
                    )
                  end)
                end
              end)

            selected_groups =
              Enum.filter(@available_groups, &(&1.group.id in @grant_selected_group_ids)) %>
            <div class="flex gap-2 h-52">
              <div class="flex-1 flex flex-col min-w-0 rounded border border-border overflow-hidden">
                <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-border bg-raised shrink-0">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-subtle">
                    Available
                  </span>
                  <span class="text-[10px] text-muted">
                    {length(filtered_available)}
                  </span>
                </div>
                <div class="px-2 pt-1.5 shrink-0">
                  <div class="relative">
                    <.icon
                      name="ri-search-line"
                      class="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-subtle pointer-events-none"
                    />
                    <input
                      type="text"
                      placeholder="Search…"
                      value={@grant_search}
                      phx-keyup="search_grant_groups"
                      phx-debounce="200"
                      class="w-full pl-6 pr-2 py-1 text-xs rounded border border-border bg-surface text-heading placeholder:text-muted outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors"
                    />
                  </div>
                </div>
                <ul class="flex-1 overflow-y-auto px-2 py-1.5 space-y-0.5">
                  <li :for={row <- filtered_available}>
                    <button
                      type="button"
                      phx-click="toggle_grant_group"
                      phx-value-group_id={row.group.id}
                      class="flex items-center gap-2 px-2 py-1.5 w-full rounded text-left transition-colors hover:bg-surface cursor-pointer"
                    >
                      <.provider_icon provider={provider_type_from_group(row)} size="xs" variant="circle" />
                      <span class="text-xs text-heading truncate">
                        {row.group.name}
                      </span>
                    </button>
                  </li>
                  <li
                    :if={@available_groups == []}
                    class="flex items-center justify-center h-16 text-xs text-subtle"
                  >
                    All groups already have access.
                  </li>
                  <li
                    :if={@available_groups != [] && filtered_available == []}
                    class="flex items-center justify-center h-12 text-xs text-subtle"
                  >
                    No groups match.
                  </li>
                </ul>
              </div>
              <div class="flex-1 flex flex-col min-w-0 rounded border border-border overflow-hidden">
                <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-border bg-raised shrink-0">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-subtle">
                    Selected
                  </span>
                  <span class="text-[10px] font-medium text-muted">
                    {length(@grant_selected_group_ids)}
                  </span>
                </div>
                <ul class="flex-1 overflow-y-auto px-2 py-1.5 space-y-0.5">
                  <li :for={row <- selected_groups}>
                    <button
                      type="button"
                      phx-click="toggle_grant_group"
                      phx-value-group_id={row.group.id}
                      class="flex items-center gap-2 px-2 py-1.5 w-full rounded text-left hover:bg-surface transition-colors cursor-pointer group"
                    >
                      <.provider_icon provider={provider_type_from_group(row)} size="xs" variant="circle" />
                      <span class="flex-1 text-xs text-heading truncate">
                        {row.group.name}
                      </span>
                      <.icon
                        name="ri-close-line"
                        class="w-3.5 h-3.5 text-subtle opacity-0 group-hover:opacity-100 shrink-0 transition-opacity"
                      />
                    </button>
                  </li>
                  <li
                    :if={selected_groups == []}
                    class="flex items-center justify-center h-16 text-xs text-subtle"
                  >
                    No groups selected.
                  </li>
                </ul>
              </div>
            </div>
          </div>
          <div class="border-t border-border pt-4">
            <div class="flex items-center justify-between mb-3">
              <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
                Conditions
                <span class="ml-1 font-normal normal-case tracking-normal text-muted">
                  (optional)
                </span>
              </h4>
              <div
                :if={
                  @policy_conditions_enabled? and
                    available_conditions(@resource) -- @active_conditions != []
                }
                class="relative"
              >
                <button
                  type="button"
                  phx-click="toggle_conditions_dropdown"
                  class="flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-2.5 h-2.5" /> Add condition
                </button>
                <div :if={@conditions_dropdown_open}>
                  <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
                  <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-border-strong bg-elevated shadow-lg py-1 overflow-hidden">
                    <button
                      :for={type <- available_conditions(@resource) -- @active_conditions}
                      type="button"
                      phx-click="add_condition"
                      phx-value-type={type}
                      class="w-full text-left px-3 py-1.5 text-xs text-body hover:text-heading hover:bg-raised transition-colors"
                    >
                      {condition_type_label(type)}
                    </button>
                  </div>
                </div>
              </div>
            </div>
            <%= if @policy_conditions_enabled? == false do %>
              <.upgrade_locked_section
                id="resource-grant-conditions-locked-container"
                account={@account}
                message="Upgrade your plan to unlock policy conditions."
                description="Add policy restrictions like IP ranges, identity providers, and time windows."
              >
                <p class="text-xs text-muted text-center py-4 rounded-lg border border-dashed border-border">
                  No conditions — access is unrestricted
                </p>
              </.upgrade_locked_section>
            <% else %>
              <p
                :if={@active_conditions == []}
                class="text-xs text-muted text-center py-4 rounded-lg border border-dashed border-border"
              >
                No conditions — access is unrestricted
              </p>
              <div :if={@active_conditions != []} class="space-y-2">
                <.grant_condition_card
                  :for={type <- @active_conditions}
                  type={type}
                  providers={@providers}
                  conditions_state={@conditions_state}
                />
              </div>
            <% end %>
          </div>
          <div class="border-t border-border pt-4">
            <.flow_log_uploads_toggle
              form={@grant_form}
              internet_resource?={@resource.type == :internet}
            />
          </div>
        </div>
      </div>
      <div
        :if={@grant_form && @grant_form.errors != []}
        class="px-5 py-2 text-xs text-error"
      >
        <p :for={{_field, {msg, _}} <- @grant_form.errors}>{msg}</p>
      </div>
      <.panel_footer>
        <.panel_footer_button type="button" phx-click="close_grant_form">
          Cancel
        </.panel_footer_button>
        <.panel_footer_button
          type="submit"
          style="primary"
          disabled={@grant_selected_group_ids == []}
        >
          Grant access
        </.panel_footer_button>
      </.panel_footer>
    </.form>
    """
  end

  attr :policy_authorizations, :list, default: []
  attr :page, :integer, default: 1
  attr :has_next, :boolean, default: false
  attr :expanded_id, :string, default: nil
  attr :account, :any, required: true
  attr :resource, :any, required: true

  def resource_policy_authorizations_tab(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <.authorization_flow_logs_notice account={@account} />
      <div
        :if={@policy_authorizations == []}
        class="flex flex-1 flex-col items-center justify-center gap-2 text-subtle"
      >
        <.icon name="ri-shield-check-line" class="w-8 h-8" />
        <p class="text-sm">No recent policy authorizations</p>
      </div>
      <div :if={@policy_authorizations != []} class="flex-1 flex flex-col overflow-hidden">
        <div class="flex-1 overflow-y-auto">
          <table class="w-full text-xs">
            <thead class="sticky top-0 bg-surface z-10">
              <tr class="border-b border-border text-subtle">
                <th class="text-left px-4 py-2 font-medium">Actor</th>
                <th class="text-left px-4 py-2 font-medium">Group</th>
                <th class="text-left px-4 py-2 font-medium">Authorized</th>
                <th class="text-left px-4 py-2 font-medium">Expires</th>
                <th class="w-6"></th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @policy_authorizations do %>
                <tr
                  phx-click="toggle_policy_authorization_row"
                  phx-keydown="toggle_policy_authorization_row"
                  phx-key="Enter"
                  phx-value-id={row.authorization.id}
                  tabindex="0"
                  class="border-b border-border hover:bg-raised cursor-pointer focus:outline-none focus:bg-raised"
                >
                  <td class="px-4 py-2 text-heading">
                    {if row.actor, do: row.actor.name, else: "—"}
                  </td>
                  <td class="px-4 py-2 text-body">
                    {if row.group, do: row.group.name, else: "(deleted group)"}
                  </td>
                  <td class="px-4 py-2 text-subtle">
                    <.relative_datetime datetime={row.authorization.inserted_at} />
                  </td>
                  <td class="px-4 py-2 text-subtle">
                    <.relative_datetime datetime={row.authorization.expires_at} />
                  </td>
                  <td class="px-4 py-2 text-subtle">
                    <.icon
                      name={
                        if @expanded_id == row.authorization.id,
                          do: "ri-arrow-up-s-line",
                          else: "ri-arrow-down-s-line"
                      }
                      class="w-4 h-4"
                    />
                  </td>
                </tr>
                <tr
                  :if={@expanded_id == row.authorization.id}
                  class="border-b border-border bg-raised"
                >
                  <td colspan="5" class="px-4 py-3">
                    <div class="grid grid-cols-2 gap-x-8 gap-y-2 text-xs">
                      <div>
                        <p class="text-subtle font-medium mb-1">
                          {case row.initiating_device && row.initiating_device.type do
                            :gateway -> "Initiator (Gateway)"
                            :client -> "Initiator (Device)"
                            _ -> "Initiator"
                          end}
                        </p>
                        <p class="text-heading">
                          {if row.initiating_device, do: row.initiating_device.name, else: "—"}
                        </p>
                        <p class="text-subtle font-mono mt-0.5">
                          {if row.authorization.initiator_remote_ip,
                            do: Portal.Types.INET.to_string(row.authorization.initiator_remote_ip),
                            else: "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-subtle font-medium mb-1">
                          {case row.receiving_device && row.receiving_device.type do
                            :gateway -> "Receiver (Gateway)"
                            :client -> "Receiver (Device)"
                            _ -> "Receiver"
                          end}
                        </p>
                        <p class="text-heading">
                          {if row.receiving_device, do: row.receiving_device.name, else: "—"}
                        </p>
                        <p class="text-subtle font-mono mt-0.5">
                          {if row.authorization.receiver_remote_ip,
                            do: Portal.Types.INET.to_string(row.authorization.receiver_remote_ip),
                            else: "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-subtle font-medium mb-1">Owner</p>
                        <p class="text-heading">
                          {if row.actor, do: row.actor.name, else: "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-subtle font-medium mb-1">Policy</p>
                        <.link
                          navigate={~p"/#{@account}/policies/#{row.authorization.policy_id}"}
                          class="text-brand hover:underline"
                        >
                          {if row.group, do: row.group.name, else: "Everyone"} → {@resource.name}
                        </.link>
                      </div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <div class="flex items-center justify-between px-4 py-2 border-t border-border shrink-0">
          <button
            phx-click="change_policy_authorizations_page"
            phx-value-page={@page - 1}
            disabled={@page == 1}
            class="flex items-center gap-1 text-xs transition-colors disabled:text-muted disabled:cursor-not-allowed text-body hover:enabled:text-heading"
          >
            <.icon name="ri-arrow-left-s-line" class="w-4 h-4" /> Previous
          </button>
          <span class="text-xs text-subtle">Page {@page}</span>
          <button
            phx-click="change_policy_authorizations_page"
            phx-value-page={@page + 1}
            disabled={not @has_next}
            class="flex items-center gap-1 text-xs transition-colors disabled:text-muted disabled:cursor-not-allowed text-body hover:enabled:text-heading"
          >
            Next <.icon name="ri-arrow-right-s-line" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :resource, :any, required: true
  attr :presence_tick, :integer, default: 0
  attr :ui_state, :map, required: true

  def resource_sidebar(assigns) do
    assigns = assign(assigns, assigns.ui_state)

    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
          Details
        </h3>
        <dl class="space-y-2.5">
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Resource ID</dt>
            <dd class="font-mono text-[11px] text-body break-all">
              {@resource.id}
            </dd>
          </div>
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Type</dt>
            <dd>
              <span class={type_badge_class(@resource.type)}>
                {resource_type_label(@resource.type)}
              </span>
            </dd>
          </div>
          <div :if={@resource.type == :dns}>
            <dt class="text-[10px] text-subtle mb-0.5">IP Stack</dt>
            <dd class="text-xs text-body">
              {case @resource.ip_stack do
                :dual -> "Dual-stack (A + AAAA)"
                :ipv4_only -> "IPv4 only (A)"
                :ipv6_only -> "IPv6 only (AAAA)"
                _ -> "Dual-stack (A + AAAA)"
              end}
            </dd>
          </div>
          <div :if={@resource.type not in [:internet, :static_device_pool]}>
            <dt class="text-[10px] text-subtle mb-0.5">Address</dt>
            <dd class="font-mono text-xs text-heading font-medium break-all">
              {@resource.address}
            </dd>
          </div>
          <div :if={@resource.type == :static_device_pool}>
            <dt class="text-[10px] text-subtle mb-0.5">Address</dt>
            <dd class="text-xs italic text-muted">Multiple Addresses</dd>
          </div>
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Description</dt>
            <dd class={[
              "text-xs",
              if(@resource.address_description,
                do: "text-body",
                else: "text-muted italic"
              )
            ]}>
              {@resource.address_description || "No Address Description"}
            </dd>
          </div>
        </dl>
      </section>
      <div :if={@resource.type != :internet} class="border-t border-border"></div>
      <section :if={@resource.type != :internet}>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
          Traffic Restrictions
        </h3>
        <p
          :if={@resource.filters == []}
          class="text-xs text-muted italic"
        >
          None — all protocols/ports permitted
        </p>
        <ul :if={@resource.filters != []} class="space-y-1">
          <li
            :for={filter <- @resource.filters}
            class="text-xs font-mono text-body"
          >
            {format_filter(filter)}
          </li>
        </ul>
      </section>
      <div class="border-t border-border"></div>
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
          Infrastructure
        </h3>
        <dl class="space-y-2.5">
          <div>
            <dt class="text-[10px] text-subtle mb-1">Site</dt>
            <%= if @resource.site do %>
              <dd class="flex items-center gap-1.5 flex-wrap">
                <.link
                  navigate={~p"/#{@account}/sites/#{@resource.site}"}
                  class="text-xs underline font-medium text-body hover:text-heading transition-colors"
                >
                  {@resource.site.name}
                </.link>
                <span
                  :if={resource_online?(@resource, @presence_tick)}
                  class="relative flex items-center justify-center w-1.5 h-1.5"
                >
                  <span class="absolute inline-flex rounded-full opacity-60 animate-ping w-1.5 h-1.5 bg-success">
                  </span>
                  <span class="relative inline-flex rounded-full w-1.5 h-1.5 bg-success">
                  </span>
                </span>
              </dd>
            <% else %>
              <dd class="text-xs italic text-muted">{nil_site_label(@resource)}</dd>
            <% end %>
          </div>
        </dl>
      </section>
      <div class="border-t border-border"></div>
      <section :if={@resource.type != :internet}>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error/60 mb-3">
          Danger Zone
        </h3>
        <button
          :if={not @confirm_delete_resource}
          type="button"
          phx-click="confirm_delete_resource"
          class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
        >
          <.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete resource
        </button>
        <div
          :if={@confirm_delete_resource}
          class="px-3 py-2.5 rounded border border-error/20 bg-error-light"
        >
          <p class="text-xs font-medium text-error mb-1">
            Delete this resource?
          </p>
          <p class="text-xs text-error/70 mb-3">
            All Policies associated with this Resource will also be deleted and all devices will immediately lose access.
          </p>
          <div class="flex items-center gap-1.5">
            <.button type="button" phx-click="cancel_delete_resource" size="xs">
              Cancel
            </.button>
            <.button type="button" phx-click="delete_resource" style="danger" size="xs">
              Delete
            </.button>
          </div>
        </div>
      </section>
    </div>
    """
  end

  @spec format_filter(map()) :: String.t()
  def format_filter(%{protocol: :icmp}), do: "ICMP: Allowed"

  def format_filter(%{protocol: protocol, ports: []}),
    do: "#{String.upcase("#{protocol}")}: All ports"

  def format_filter(%{protocol: protocol, ports: ports}),
    do: "#{String.upcase("#{protocol}")}: #{Enum.join(ports, ", ")}"

  @spec to_grant_form(Portal.Resource.t()) :: Phoenix.HTML.Form.t()
  def to_grant_form(resource) do
    %Portal.Policy{flow_log_uploads_enabled: resource.type != :internet}
    |> Ecto.Changeset.change()
    |> to_form(as: :policy)
  end

  @spec resource_online?(map(), integer()) :: boolean()
  def resource_online?(resource, _presence_tick \\ 0)
  def resource_online?(%{site_id: nil}, _presence_tick), do: false

  def resource_online?(%{site_id: site_id}, _presence_tick) do
    Presence.Gateways.Site.list(site_id) |> map_size() > 0
  end

  @spec resource_status(map(), integer()) :: :online | :offline
  def resource_status(resource, presence_tick \\ 0) do
    if resource_online?(resource, presence_tick), do: :online, else: :offline
  end

  attr :resource, :any, required: true
  attr :presence_tick, :integer, default: 0
  attr :pool_member_ids, :list, default: []
  attr :online_device_ids, :any, default: %MapSet{}

  def resource_status_badge(%{resource: %{type: :static_device_pool}} = assigns) do
    online = Enum.count(assigns.pool_member_ids, &MapSet.member?(assigns.online_device_ids, &1))
    assigns = assign(assigns, online: online, total: length(assigns.pool_member_ids))

    ~H"""
    <.status_badge :if={@total == 0} style={:warning}>
      No devices
    </.status_badge>
    <.status_badge :if={@total > 0} style={if @online > 0, do: :success, else: :neutral}>
      {@online} / {@total} online
    </.status_badge>
    """
  end

  def resource_status_badge(assigns) do
    assigns = assign(assigns, :online?, resource_online?(assigns.resource, assigns.presence_tick))

    ~H"""
    <.status_badge style={if @online?, do: :success, else: :neutral}>
      {if @online?, do: "Online", else: "Offline"}
    </.status_badge>
    """
  end

  @spec resource_type_label(atom()) :: String.t()
  def resource_type_label(:dns), do: "DNS"
  def resource_type_label(:ip), do: "IP"
  def resource_type_label(:cidr), do: "CIDR"
  def resource_type_label(:internet), do: "Internet"
  def resource_type_label(:static_device_pool), do: "Device Pool"
  def resource_type_label(type), do: to_string(type)

  @spec type_badge_class(atom()) :: String.t()
  def type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-dns text-badge-dns-text"

  def type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-ip text-badge-ip-text"

  def type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-cidr text-badge-cidr-text"

  def type_badge_class(:internet),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium trcking-wider uppercase bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  def type_badge_class(:static_device_pool),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-device-pool text-badge-device-pool-text"

  def type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-raised text-body"

  defmodule Database do
    import Ecto.Query
    alias Portal.{Device, Resource, Safe, StaticDevicePoolMember}

    @device_identifier_fields ~w[
      firezone_id
      device_serial
      device_uuid
      identifier_for_vendor
      firebase_installation_id
      last_attested_device_serial
      last_attested_device_uuid
      last_attested_mdm_device_id
    ]a

    def get_resource!(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def list_resources(subject, opts \\ []) do
      from(r in Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list(Database.ListQuery, opts)
    end

    def all_sites(subject) do
      from(s in Portal.Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def get_device(device_id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> where([devices: d], d.id == ^device_id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def search_devices(search_term, _subject, _selected_devices) when search_term in [nil, ""],
      do: nil

    def search_devices(search_term, subject, selected_devices) do
      selected_ids = Enum.map(selected_devices, & &1.id)
      online_ids = Portal.Presence.Clients.online_client_ids(subject.account.id)
      pattern = "%#{search_term}%"

      query =
        from(d in Device, as: :devices)
        |> where([devices: d], d.type == :client)
        |> join(:inner, [devices: d], a in assoc(d, :actor),
          on: a.account_id == d.account_id,
          as: :actors
        )
        |> where([devices: d], d.id not in ^selected_ids)
        |> where(^device_search_filter(pattern))
        |> order_by([devices: d], desc: d.id in ^online_ids)
        |> limit(10)

      case query |> Safe.scoped(subject) |> Safe.all() do
        {:error, _} ->
          []

        devices ->
          Enum.map(devices, &%{&1 | online?: &1.id in online_ids})
      end
    end

    defp device_search_filter(pattern) do
      dynamic(
        [devices: d, actors: a],
        ilike(d.name, ^pattern) or
          ilike(a.name, ^pattern) or
          ilike(coalesce(a.email, ""), ^pattern) or
          ilike(type(d.id, :string), ^pattern) or
          ilike(type(d.ipv4, :string), ^pattern) or
          ilike(type(d.ipv6, :string), ^pattern) or
          ^device_identifier_filter(pattern)
      )
    end

    defp device_identifier_filter(pattern) do
      Enum.reduce(@device_identifier_fields, dynamic(false), fn field, dyn ->
        dynamic([devices: d], ^dyn or ilike(coalesce(field(d, ^field), ""), ^pattern))
      end)
    end

    def validate_selected_devices([], _subject), do: {:ok, []}

    def validate_selected_devices(selected_devices, subject) do
      ids =
        selected_devices
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> where([devices: d], d.id in ^ids)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} ->
          {:error, :invalid_devices}

        devices when length(devices) == length(ids) ->
          {:ok, devices}

        _ ->
          {:error, :invalid_devices}
      end
    end

    def sync_static_pool_members(
          %Portal.Resource{type: :static_device_pool} = resource,
          devices,
          subject
        ) do
      selected_device_ids = devices |> Enum.map(& &1.id) |> Enum.uniq()

      existing_device_ids =
        from(m in StaticDevicePoolMember,
          where: m.resource_id == ^resource.id,
          select: m.device_id
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> case do
          {:error, _} -> []
          ids -> ids
        end

      to_remove = existing_device_ids -- selected_device_ids
      to_add = selected_device_ids -- existing_device_ids

      with :ok <- maybe_delete_pool_members(resource, to_remove, subject),
           :ok <- maybe_insert_pool_members(resource, to_add, subject) do
        :ok
      end
    end

    def sync_static_pool_members(%Portal.Resource{} = resource, _devices, subject) do
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
