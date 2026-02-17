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
          <.link navigate={~p"/#{@account}/settings/account"} class="text-sm text-primary-500">
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="remix-lock-line" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
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

  attr :form, :any, required: true
  attr :resource, :any, default: nil
  attr :client_to_client_enabled, :boolean, default: false

  def resource_type_picker(assigns) do
    ~H"""
    <div :if={is_nil(@resource) || @resource.type != :internet}>
      <span class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
        Type <span class="text-[var(--status-error)]">*</span>
      </span>
      <ul class={"grid w-full gap-3 #{if @client_to_client_enabled, do: "grid-cols-4", else: "grid-cols-3"}"}>
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="remix-global-line" class="w-4 h-4 mr-1" /> DNS
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="remix-server-line" class="w-4 h-4 mr-1" /> IP
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="remix-server-line" class="w-4 h-4 mr-1" /> CIDR
              </div>
              <div class="w-full text-[10px]">
                By CIDR range
              </div>
            </div>
          </label>
        </li>
        <li :if={@client_to_client_enabled}>
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
            class="inline-flex items-center justify-between w-full p-3 text-[var(--text-secondary)] bg-[var(--surface)] border border-[var(--border)] rounded cursor-pointer peer-checked:border-[var(--brand)] peer-checked:text-[var(--brand)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          >
            <div class="block">
              <div class="w-full font-semibold mb-1 text-xs">
                <.icon name="remix-computer-line" class="w-4 h-4 mr-1" /> Device Pool
              </div>
              <div class="w-full text-[10px]">
                Direct client access
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
    <div :if={
      (is_nil(@resource) || @resource.type != :internet) &&
        to_string(@form[:type].value) != "static_device_pool"
    }>
      <label
        for={@form[:address].id}
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Address <span class="text-[var(--status-error)]">*</span>
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
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Address Description <span class="text-[var(--text-muted)] font-normal">(optional)</span>
      </label>
      <.input
        field={@form[:address_description]}
        type="text"
        placeholder="Enter a description or URL"
        phx-debounce="300"
      />
      <p class="mt-1 text-xs text-[var(--text-tertiary)]">
        Optional description or URL shown in Clients.
      </p>
    </div>

    <div>
      <label
        for={@form[:name].id}
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Name <span class="text-[var(--status-error)]">*</span>
      </label>
      <.input
        field={@form[:name]}
        type="text"
        placeholder="Name this resource"
        phx-debounce="300"
        required
      />
    </div>
    """
  end

  attr :selected_clients, :list, required: true
  attr :client_search_results, :any, default: nil
  attr :client_search, :string, default: ""

  def resource_device_pool_section(assigns) do
    ~H"""
    <div>
      <span class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
        Devices <span class="text-[var(--text-muted)] font-normal">(optional)</span>
      </span>
      <p class="mb-2 text-xs text-[var(--text-tertiary)]">
        Select clients to include in this pool.
      </p>
      <.client_picker
        selected_clients={@selected_clients}
        client_search={@client_search}
        client_search_results={@client_search_results}
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
      <span class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
        IP Stack
      </span>
      <div class="inline-flex rounded border border-[var(--border)] overflow-hidden">
        <label
          for="resource-form-ip-stack--dual"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-[var(--border)] first:border-l-0 cursor-pointer",
            if(
              "#{@form[:ip_stack].value}" == "" or "#{@form[:ip_stack].value}" == "dual",
              do: "bg-[var(--brand)] text-white",
              else:
                "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          Both
        </label>
        <label
          for="resource-form-ip-stack--ipv4"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-[var(--border)] first:border-l-0 cursor-pointer",
            if(
              "#{@form[:ip_stack].value}" == "ipv4_only",
              do: "bg-[var(--brand)] text-white",
              else:
                "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          IPv4
        </label>
        <label
          for="resource-form-ip-stack--ipv6"
          class={[
            "px-4 py-1.5 text-xs transition-colors border-l border-[var(--border)] first:border-l-0 cursor-pointer",
            if(
              "#{@form[:ip_stack].value}" == "ipv6_only",
              do: "bg-[var(--brand)] text-white",
              else:
                "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          IPv6
        </label>
      </div>
      <p class="mt-1.5 text-xs text-[var(--text-secondary)] leading-snug">
        {case "#{@form[:ip_stack].value}" do
          "ipv4_only" ->
            "Resolves only A records — clients connect over IPv4."

          "ipv6_only" ->
            "Resolves only AAAA records — clients connect over IPv6."

          _ ->
            "Resolves A and AAAA records — clients connect over IPv4 or IPv6, whichever is available."
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

  def resource_traffic_restrictions_section(assigns) do
    ~H"""
    <div :if={
      (is_nil(@resource) || @resource.type != :internet) &&
        to_string(@form[:type].value) != "static_device_pool"
    }>
      <div class="flex items-center justify-between mb-2">
        <span class="block text-xs font-medium text-[var(--text-secondary)]">
          Traffic Restrictions <span class="font-normal text-[var(--text-tertiary)]">(optional)</span>
        </span>
        <div class="relative">
          <button
            type="button"
            phx-click="toggle_resource_filters_dropdown"
            class="inline-flex items-center gap-1 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] border border-[var(--border)] rounded px-2 py-1 bg-[var(--surface)] hover:bg-[var(--surface-raised)] transition-colors"
          >
            <.icon name="remix-add-line" class="w-3 h-3" /> Add protocol
            <.icon name="remix-arrow-down-s-line" class="w-3 h-3" />
          </button>
          <div
            :if={@filters_dropdown_open}
            phx-click-away="close_resource_filters_dropdown"
            class="absolute right-0 top-full mt-1 z-20 bg-[var(--surface-overlay)] border border-[var(--border)] rounded shadow-md min-w-[120px]"
          >
            <button
              :if={:tcp not in @active_protocols}
              type="button"
              phx-click="add_resource_filter"
              phx-value-protocol="tcp"
              class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            >
              TCP
            </button>
            <button
              :if={:udp not in @active_protocols}
              type="button"
              phx-click="add_resource_filter"
              phx-value-protocol="udp"
              class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            >
              UDP
            </button>
            <button
              :if={:icmp not in @active_protocols}
              type="button"
              phx-click="add_resource_filter"
              phx-value-protocol="icmp"
              class="flex items-center w-full px-3 py-2 text-xs text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            >
              ICMP
            </button>
            <div
              :if={
                :tcp in @active_protocols and :udp in @active_protocols and :icmp in @active_protocols
              }
              class="px-3 py-2 text-xs text-[var(--text-tertiary)]"
            >
              All protocols added
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@active_protocols == []}
        class="flex items-center justify-center rounded border border-dashed border-[var(--border)] px-4 py-5 text-xs text-[var(--text-tertiary)]"
      >
        No restrictions — all traffic is permitted
      </div>

      <div :if={@active_protocols != []} class="flex flex-col gap-2">
        <div
          :for={protocol <- @active_protocols}
          class="flex items-center gap-2 rounded border border-[var(--border)] bg-[var(--surface)] px-3 py-2"
        >
          <input type="hidden" name={"resource[filters][#{protocol}][enabled]"} value="true" />
          <input
            type="hidden"
            name={"resource[filters][#{protocol}][protocol]"}
            value={"#{protocol}"}
          />
          <span class="w-10 shrink-0 text-xs font-medium text-[var(--text-primary)] uppercase">
            {protocol}
          </span>
          <div :if={protocol != :icmp} class="flex-1">
            <input
              type="text"
              name={"resource[filters][#{protocol}][ports]"}
              value={Map.get(@filter_ports, protocol, "")}
              placeholder="All ports"
              class="w-full px-3 py-2 text-sm rounded-md border font-mono bg-[var(--control-bg)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none transition-colors border-[var(--control-border)] focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30"
            />
          </div>
          <span
            :if={protocol == :icmp}
            class="flex-1 text-xs text-[var(--text-tertiary)] italic"
          >
            echo request/reply
          </span>
          <button
            type="button"
            phx-click="remove_resource_filter"
            phx-value-protocol={"#{protocol}"}
            class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
            aria-label={"Remove #{protocol} filter"}
          >
            <.icon name="remix-close-line" class="w-3.5 h-3.5" />
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
        class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
      >
        Site <span class="text-[var(--status-error)]">*</span>
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

  attr :selected_clients, :list, required: true
  attr :client_search_results, :any, default: nil
  attr :client_search, :string, default: ""

  def client_picker(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="relative mb-2" phx-click-away="blur_client_search">
        <.icon
          name="remix-search-line"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-[var(--text-tertiary)] pointer-events-none"
        />
        <input
          type="text"
          name="client_search"
          value={@client_search}
          placeholder="Search clients to add…"
          phx-change="search_client"
          phx-debounce="300"
          phx-focus="focus_client_search"
          autocomplete="off"
          data-1p-ignore
          class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-[var(--border)] bg-[var(--surface-raised)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors"
        />
      </div>

      <ul :if={@selected_clients != []} class="space-y-1 mb-1">
        <li :for={client <- @selected_clients}>
          <div class="flex items-center gap-3 px-3 py-2.5 rounded-lg border border-[var(--brand)] bg-[var(--brand-muted)]">
            <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
              <.icon name="remix-computer-line" class="w-4 h-4 text-[var(--brand)]" />
            </div>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-[var(--brand)] truncate">{client.name}</p>
              <p class="text-[10px] text-[var(--text-tertiary)] truncate">{client_details(client)}</p>
            </div>
            <button
              type="button"
              phx-click="remove_client"
              phx-value-client_id={client.id}
              class="shrink-0 flex items-center justify-center w-5 h-5 rounded text-[var(--brand)]/50 hover:text-[var(--brand)] transition-colors"
              aria-label="Remove client"
            >
              <.icon name="remix-close-line" class="w-3.5 h-3.5" />
            </button>
          </div>
        </li>
      </ul>

      <ul :if={@client_search_results != nil && @client_search_results != []} class="space-y-1">
        <li :for={client <- @client_search_results}>
          <button
            type="button"
            phx-click="add_client"
            phx-value-client_id={client.id}
            class="flex items-center gap-3 px-3 py-2.5 w-full rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)] cursor-pointer transition-colors"
          >
            <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
              <.icon name="remix-computer-line" class="w-4 h-4 text-[var(--text-tertiary)]" />
            </div>
            <div class="flex-1 min-w-0 text-left">
              <p class="text-sm font-medium text-[var(--text-primary)] truncate">{client.name}</p>
              <p class="text-[10px] text-[var(--text-tertiary)] truncate">{client_details(client)}</p>
            </div>
            <span class={[
              "w-1.5 h-1.5 rounded-full shrink-0",
              if(client.online?, do: "bg-[var(--status-active)]", else: "bg-[var(--status-neutral)]")
            ]} />
          </button>
        </li>
      </ul>

      <div
        :if={@client_search_results == []}
        class="flex items-center justify-center h-16 text-xs text-[var(--text-tertiary)]"
      >
        No clients found
      </div>

      <div
        :if={@selected_clients == [] && is_nil(@client_search_results)}
        class="flex items-center justify-center h-12 text-xs text-[var(--text-tertiary)]"
      >
        Search above to add devices
      </div>
    </div>
    """
  end

  defp client_details(client) do
    [
      client.ipv4_address && Portal.Types.INET.to_string(client.ipv4_address.address),
      client.ipv6_address && Portal.Types.INET.to_string(client.ipv6_address.address),
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
    alias Portal.{Features, Safe, Resource, StaticDevicePoolMember}

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
      from(c in Portal.Client, as: :clients)
      |> where([clients: c], c.id == ^client_id)
      |> preload([:ipv4_address, :ipv6_address])
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def search_clients(search_term, _subject, _selected_clients) when search_term in [nil, ""],
      do: nil

    def search_clients(search_term, subject, selected_clients) do
      selected_ids = Enum.map(selected_clients, & &1.id)
      pattern = "%#{search_term}%"

      query =
        from(c in Portal.Client, as: :clients)
        |> join(:inner, [clients: c], a in assoc(c, :actor), as: :actors)
        |> join(:left, [clients: c], ipv4 in assoc(c, :ipv4_address), as: :ipv4)
        |> join(:left, [clients: c], ipv6 in assoc(c, :ipv6_address), as: :ipv6)
        |> where([clients: c], c.id not in ^selected_ids)
        |> where(^client_search_filter(pattern))
        |> preload([:ipv4_address, :ipv6_address])
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
        [clients: c, actors: a, ipv4: ipv4, ipv6: ipv6],
        ilike(c.name, ^pattern) or
          ilike(a.name, ^pattern) or
          ilike(coalesce(a.email, ""), ^pattern) or
          ilike(type(c.id, :string), ^pattern) or
          ilike(coalesce(c.external_id, ""), ^pattern) or
          ilike(coalesce(c.device_serial, ""), ^pattern) or
          ilike(coalesce(c.device_uuid, ""), ^pattern) or
          ilike(coalesce(c.identifier_for_vendor, ""), ^pattern) or
          ilike(coalesce(c.firebase_installation_id, ""), ^pattern) or
          ilike(type(ipv4.address, :string), ^pattern) or
          ilike(type(ipv6.address, :string), ^pattern)
      )
    end

    def validate_selected_clients([], _subject), do: {:ok, []}

    def validate_selected_clients(selected_clients, subject) do
      ids =
        selected_clients
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      from(c in Portal.Client, as: :clients)
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
          select: m.client_id
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
             where: m.resource_id == ^resource.id and m.client_id in ^to_remove
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
        Enum.map(to_add, fn client_id ->
          %{
            account_id: resource.account_id,
            resource_id: resource.id,
            client_id: client_id,
            id: Ecto.UUID.generate()
          }
        end)

      case Safe.scoped(subject)
           |> Safe.insert_all(StaticDevicePoolMember, entries,
             on_conflict: :nothing,
             conflict_target: [:account_id, :resource_id, :client_id]
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
