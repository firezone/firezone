defmodule Web.Resources.New do
  use Web, :live_view
  import Web.Resources.Components
  alias Domain.{Gateways, Resources, Config}

  def mount(params, _session, socket) do
    with {:ok, gateway_groups} <- Gateways.list_groups(socket.assigns.subject) do
      changeset = Resources.new_resource(socket.assigns.account)

      socket =
        assign(
          socket,
          gateway_groups: gateway_groups,
          address_description_changed?: false,
          name_changed?: false,
          form: to_form(changeset),
          params: Map.take(params, ["site_id"]),
          traffic_filters_enabled?: Config.traffic_filters_enabled?(),
          page_title: "New Resource"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/new"}>Add Resource</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Add Resource
      </:title>

      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Resource details</h2>
          <.form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="change">
            <div>
              <label for="resource_type" class="block mb-2 text-sm text-neutral-900">
                Type
              </label>
              <div class="flex text-sm leading-6 text-zinc-600">
                <div class="flex items-center me-4">
                  <.input
                    id="resource-type--dns"
                    type="radio"
                    field={@form[:type]}
                    value="dns"
                    label="DNS"
                    checked={@form[:type].value == :dns}
                    required
                  />
                </div>
                <div class="flex items-center me-4">
                  <.input
                    id="resource-type--ip"
                    type="radio"
                    field={@form[:type]}
                    value="ip"
                    label="IP"
                    checked={@form[:type].value == :ip}
                    required
                  />
                </div>
                <div class="flex items-center me-4">
                  <.input
                    id="resource-type--cidr"
                    type="radio"
                    field={@form[:type]}
                    value="cidr"
                    label="CIDR"
                    checked={@form[:type].value == :cidr}
                    required
                  />
                </div>
              </div>
            </div>

            <div>
              <.input
                field={@form[:address]}
                autocomplete="off"
                label="Address"
                placeholder={
                  cond do
                    @form[:type].value == :dns -> "gitlab.company.com"
                    @form[:type].value == :cidr -> "10.0.0.0/24"
                    @form[:type].value == :ip -> "10.3.2.1"
                    true -> "Please select a Type from the options first"
                  end
                }
                disabled={is_nil(@form[:type].value)}
                required
              />
              <p :if={@form[:type].value == :dns} class="mt-2 text-xs text-neutral-500">
                Wildcards are supported:<br />
                <code class="ml-2 px-0.5 font-semibold">*.c.com</code>
                will match recursively (<code class="px-0.5 font-semibold">b.c.com</code> and <code class="px-0.5 font-semibold">a.b.c.com</code>).<br />
                <code class="ml-2 px-0.5 font-semibold">?.c.com</code>
                will match top-level subdomains only (<code class="px-0.5 font-semibold">b.c.com</code>).
              </p>
              <p :if={@form[:type].value == :ip} class="mt-2 text-xs text-neutral-500">
                IPv4 and IPv6 addresses are supported.
              </p>
              <p :if={@form[:type].value == :cidr} class="mt-2 text-xs text-neutral-500">
                IPv4 and IPv6 CIDR ranges are supported.
              </p>
            </div>

            <div>
              <.input
                field={@form[:address_description]}
                type="text"
                label="Address Description"
                placeholder={@form[:address].value || "http://example.com/"}
                required
              />
              <p class="mt-2 text-xs text-neutral-500">
                This will be displayed in client applications to assist users in understanding how to access the resource.
              </p>
            </div>

            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Name this resource"
              required
            />

            <.filters_form :if={@traffic_filters_enabled?} form={@form[:filters]} />

            <.connections_form
              :if={is_nil(@params["site_id"])}
              form={@form[:connections]}
              account={@account}
              gateway_groups={@gateway_groups}
            />

            <.submit_button phx-disable-with="Creating Resource...">
              Save
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"resource" => attrs} = payload, socket) do
    name_changed? =
      socket.assigns.name_changed? ||
        payload["_target"] == ["resource", "name"]

    address_description_changed? =
      socket.assigns.address_description_changed? ||
        payload["_target"] == ["resource", "address_description"]

    attrs =
      attrs
      |> maybe_put_default_name(name_changed?)
      |> maybe_put_default_address_description(address_description_changed?)
      |> map_filters_form_attrs()
      |> map_connections_form_attrs()
      |> maybe_put_connections(socket.assigns.params)

    changeset =
      Resources.new_resource(socket.assigns.account, attrs)
      |> Map.put(:action, :validate)

    socket =
      assign(socket,
        form: to_form(changeset),
        name_changed?: name_changed?,
        address_description_changed?: address_description_changed?
      )

    {:noreply, socket}
  end

  def handle_event("submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> maybe_put_default_name()
      |> maybe_put_default_address_description()
      |> map_filters_form_attrs()
      |> map_connections_form_attrs()
      |> maybe_put_connections(socket.assigns.params)

    case Resources.create_resource(attrs, socket.assigns.subject) do
      {:ok, resource} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/#{socket.assigns.account}/resources/#{resource}?#{socket.assigns.params}"
         )}

      {:error, changeset} ->
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp maybe_put_default_name(attrs, name_changed? \\ true)

  defp maybe_put_default_name(attrs, true) do
    attrs
  end

  defp maybe_put_default_name(attrs, false) do
    Map.put(attrs, "name", attrs["address"])
  end

  defp maybe_put_default_address_description(attrs, address_description_changed? \\ true)

  defp maybe_put_default_address_description(
         %{"type" => "dns", "address" => address} = attrs,
         false
       )
       when is_binary(address) do
    Map.put(attrs, "address_description", "http://#{address}/")
  end

  defp maybe_put_default_address_description(
         %{"type" => "ip", "address" => address} = attrs,
         false
       )
       when is_binary(address) do
    Map.put(attrs, "address_description", "http://#{address}/")
  end

  defp maybe_put_default_address_description(attrs, false) do
    Map.put(attrs, "address_description", "")
  end

  defp maybe_put_default_address_description(attrs, true) do
    attrs
  end

  defp maybe_put_connections(attrs, params) do
    if site_id = params["site_id"] do
      Map.put(attrs, "connections", %{
        "#{site_id}" => %{"gateway_group_id" => site_id, "enabled" => "true"}
      })
    else
      attrs
    end
  end
end
