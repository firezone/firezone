defmodule Web.Resources.Components do
  use Web, :component_library

  defp pretty_print_ports([]), do: ""
  defp pretty_print_ports(ports), do: Enum.join(ports, ", ")

  def map_filters_form_attrs(attrs) do
    attrs =
      if Domain.Config.traffic_filters_enabled?() do
        attrs
      else
        Map.put(attrs, "filters", %{"all" => %{"enabled" => "true", "protocol" => "all"}})
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

      if Map.has_key?(filters, "all") do
        %{"all" => %{"protocol" => "all"}}
      else
        filters
      end
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
      for form <- forms, into: %{} do
        %Phoenix.HTML.Form{params: params} = form
        id = Ecto.Changeset.apply_changes(form.source).protocol
        form_id = "#{parent_form.id}_#{field_name}_#{id}"
        new_params = Map.put(params, :protocol, id)
        new_hidden = [{:protocol, id} | form.hidden]
        new_form = %Phoenix.HTML.Form{form | id: form_id, params: new_params, hidden: new_hidden}
        {id, new_form}
      end

    assigns = Map.put(assigns, :forms_by_protocol, forms_by_protocol)

    ~H"""
    <fieldset class="flex flex-col gap-2">
      <legend class="mb-2">Traffic Restriction</legend>

      <div>
        <.input type="hidden" name={"#{@form.name}[all][protocol]"} value="all" />

        <div class="items-center flex flex-row h-16">
          <div class="flex-none w-32">
            <.input
              type="checkbox"
              field={@forms_by_protocol[:all]}
              name={"#{@form.name}[all][enabled]"}
              value={if Map.has_key?(@forms_by_protocol, :all), do: "true", else: "false"}
              label="Permit All"
            />
          </div>
        </div>
      </div>

      <div>
        <.input type="hidden" name={"#{@form.name}[icmp][protocol]"} value="icmp" />

        <div class="items-center flex flex-row h-16">
          <div class="flex-none w-32">
            <.input
              type="checkbox"
              field={@forms_by_protocol[:icmp]}
              name={"#{@form.name}[icmp][enabled]"}
              value={Map.has_key?(@forms_by_protocol, :icmp)}
              disabled={Map.has_key?(@forms_by_protocol, :all)}
              label="ICMP"
            />
          </div>
        </div>
      </div>

      <div>
        <.input type="hidden" name={"#{@form.name}[tcp][protocol]"} value="tcp" />

        <div class="items-center flex flex-row h-16">
          <div class="flex-none w-32">
            <.input
              type="checkbox"
              field={@forms_by_protocol[:tcp]}
              name={"#{@form.name}[tcp][enabled]"}
              value={Map.has_key?(@forms_by_protocol, :tcp)}
              disabled={Map.has_key?(@forms_by_protocol, :all)}
              label="TCP"
            />
          </div>

          <div class="flex-grow">
            <% ports = (@forms_by_protocol[:tcp] || %{ports: %{value: []}})[:ports] %>
            <.input
              type="text"
              field={ports}
              name={"#{@form.name}[tcp][ports]"}
              value={pretty_print_ports(ports.value)}
              disabled={Map.has_key?(@forms_by_protocol, :all)}
              placeholder="Enter comma-separated port range(s), eg. 433, 80, 90-99. Matches all ports if empty."
            />
          </div>
        </div>
      </div>

      <div>
        <.input type="hidden" name={"#{@form.name}[udp][protocol]"} value="udp" />

        <div class="items-center flex flex-row h-16">
          <div class="flex-none w-32">
            <.input
              type="checkbox"
              field={@forms_by_protocol[:udp]}
              name={"#{@form.name}[udp][enabled]"}
              value={Map.has_key?(@forms_by_protocol, :udp)}
              disabled={Map.has_key?(@forms_by_protocol, :all)}
              label="UDP"
            />
          </div>

          <div class="flex-grow">
            <% ports = (@forms_by_protocol[:udp] || %{ports: %{value: []}})[:ports] %>
            <.input
              type="text"
              field={ports}
              name={"#{@form.name}[udp][ports]"}
              value={pretty_print_ports(ports.value)}
              disabled={Map.has_key?(@forms_by_protocol, :all)}
              placeholder="Enter comma-separated port range(s), eg. 433, 80, 90-99. Matches all ports if empty."
            />
          </div>
        </div>
      </div>
    </fieldset>
    """
  end

  attr :form, :any, required: true

  def beta_filters_form(assigns) do
    ~H"""
    <.input type="hidden" name={"#{@form.name}[all][protocol]"} value="all" />
    <.input type="hidden" name={"#{@form.name}[all][enabled]"} value="true" />
    """
  end

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
  attr :rest, :global

  def connections_form(assigns) do
    assigns = assign(assigns, :errors, Enum.map(assigns.form.errors, &translate_error(&1)))

    ~H"""
    <fieldset class="flex flex-col gap-2" {@rest}>
      <legend class="mb-2">Sites</legend>

      <.error :for={msg <- @errors} data-validation-error-for="connections">
        <%= msg %>
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
              value={gateway_group.id in connected_gateway_group_ids}
            />
          </div>

          <div class="w-64 no-grow text-neutral-500">
            <.link
              navigate={~p"/#{@account}/sites/#{gateway_group}"}
              class="font-bold text-accent-600 hover:underline"
              target="_blank"
            >
              <%= gateway_group.name %>
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

      {id, _attrs} ->
        [id]
    end)
  end
end
