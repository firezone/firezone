defmodule Web.Resources.Components do
  use Web, :component_library
  alias Domain.Resources

  @resource_types %{
    internet: %{index: 1, label: nil},
    dns: %{index: 2, label: "DNS"},
    ip: %{index: 3, label: "IP"},
    cidr: %{index: 4, label: "CIDR"}
  }

  def fetch_resource_option(id, subject) do
    {:ok, resource} = Resources.fetch_resource_by_id_or_persistent_id(id, subject)
    {:ok, resource_option(resource)}
  end

  def list_resource_options(search_query_or_nil, subject) do
    filter =
      if search_query_or_nil != "" and search_query_or_nil != nil,
        do: [name_or_address: search_query_or_nil],
        else: []

    {:ok, resources, metadata} =
      Resources.list_resources(subject,
        preload: [:gateway_groups],
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
      if Domain.Accounts.traffic_filters_enabled?(account) do
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
        Domain.Accounts.traffic_filters_enabled?(assigns.account)
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
          <div class="mt-2.5 w-24">
            <.input
              title="Restrict traffic to TCP traffic"
              type="checkbox"
              field={@forms_by_protocol[:tcp]}
              name={"#{@form.name}[tcp][enabled]"}
              checked={Map.has_key?(@forms_by_protocol, :tcp)}
              value="true"
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
          <div class="mt-2.5 w-24">
            <.input
              type="checkbox"
              field={@forms_by_protocol[:udp]}
              name={"#{@form.name}[udp][enabled]"}
              checked={Map.has_key?(@forms_by_protocol, :udp)}
              value="true"
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

          <div class="mt-2.5 w-24">
            <.input
              title="Allow ICMP traffic"
              type="checkbox"
              field={@forms_by_protocol[:icmp]}
              name={"#{@form.name}[icmp][enabled]"}
              checked={Map.has_key?(@forms_by_protocol, :icmp)}
              value="true"
              disabled={!@traffic_filters_enabled?}
              label="ICMP"
            />
          </div>
        </div>
      </div>
    </fieldset>
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

  def map_connections_form_attrs(attrs) do
    Map.update(attrs, "connections", [], fn connections ->
      for {id, connection_attrs} <- connections,
          connection_attrs["enabled"] == "true",
          into: %{} do
        {id, connection_attrs}
      end
    end)
  end

  attr :form, :any, required: true
  attr :account, :any, required: true
  attr :gateway_groups, :list, required: true
  attr :resource, :any, default: nil
  attr :multiple, :boolean, required: true
  attr :rest, :global

  def connections_form(%{multiple: false} = assigns) do
    ~H"""
    <% connected_gateway_group_id = @form |> connected_gateway_group_ids() |> List.first() %>

    <.input type="hidden" name={"#{@form.name}[0][enabled]"} value="true" />
    <.input :if={@resource} type="hidden" name={"#{@form.name}[0][resource_id]"} value={@resource.id} />

    <.input
      type="select"
      label="Site"
      name={"#{@form.name}[0][gateway_group_id]"}
      options={
        Enum.map(@gateway_groups, fn gateway_group ->
          {gateway_group.name, gateway_group.id}
        end)
      }
      value={connected_gateway_group_id}
      placeholder="Select a Site"
      required
    />
    """
  end

  def connections_form(%{multiple: true} = assigns) do
    assigns = assign(assigns, :errors, Enum.map(assigns.form.errors, &translate_error(&1)))

    ~H"""
    <fieldset class="flex flex-col gap-2" {@rest}>
      <legend class="text-xl mb-4">Sites</legend>

      <p class="text-sm text-neutral-500">
        When multiple sites are selected, the client will automatically connect to the closest one based on its geographical location.
      </p>

      <.error :for={error <- @errors} data-validation-error-for="connections">
        {error}
      </.error>
      <div :for={gateway_group <- @gateway_groups}>
        <% connected_gateway_group_ids = connected_gateway_group_ids(@form) %>

        <.input
          type="hidden"
          name={"#{@form.name}[#{gateway_group.id}][gateway_group_id]"}
          value={gateway_group.id}
        />

        <.input
          :if={@resource}
          type="hidden"
          name={"#{@form.name}[#{gateway_group.id}][resource_id]"}
          value={@resource.id}
        />

        <div class="flex gap-4 items-end py-4 text-sm border-b">
          <div class="w-8">
            <.input
              type="checkbox"
              name={"#{@form.name}[#{gateway_group.id}][enabled]"}
              checked={gateway_group.id in connected_gateway_group_ids}
            />
          </div>

          <div class="w-64 no-grow text-neutral-500">
            <.link
              navigate={~p"/#{@account}/sites/#{gateway_group}"}
              class="font-medium text-accent-500 hover:underline"
              target="_blank"
            >
              {gateway_group.name}
            </.link>
          </div>
        </div>
      </div>
    </fieldset>
    """
  end

  def connected_gateway_group_ids(form) do
    Enum.flat_map(form.value, fn
      %Ecto.Changeset{action: :delete} ->
        []

      %Ecto.Changeset{action: :replace} ->
        []

      %Ecto.Changeset{} = changeset ->
        [Ecto.Changeset.apply_changes(changeset).gateway_group_id]

      %Domain.Resources.Connection{} = connection ->
        [connection.gateway_group_id]

      {_, %{"gateway_group_id" => id}} ->
        [id]
    end)
  end
end
