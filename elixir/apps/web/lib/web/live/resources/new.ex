defmodule Web.Resources.New do
  use Web, :live_view
  import Web.Resources.Components
  alias Domain.{Accounts, Gateways, Resources}

  def mount(params, _session, socket) do
    gateway_groups = Gateways.all_groups!(socket.assigns.subject)
    changeset = Resources.new_resource(socket.assigns.account)

    socket =
      assign(
        socket,
        gateway_groups: gateway_groups,
        address_description_changed?: false,
        name_changed?: false,
        form: to_form(changeset),
        params: Map.take(params, ["site_id"]),
        page_title: "New Resource"
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/new"}>Add Resource</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>{@page_title}</:title>

      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <legend class="text-xl mb-4">Details</legend>
          <.form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="change">
            <div>
              <p class="mb-2 text-sm text-neutral-900">
                Type
              </p>
              <ul class="grid w-full gap-6 md:grid-cols-3">
                <li>
                  <.input
                    id="resource-type--dns"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="dns"
                    checked={@form[:type].value == :dns}
                    required
                  />
                  <label for="resource-type--dns" class={~w[
                    inline-flex items-center justify-between w-full
                    p-5 text-gray-500 bg-white border border-gray-200
                    rounded cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="block">
                      <div class="w-full font-semibold mb-3">
                        <.icon name="hero-globe-alt" class="w-5 h-5 mr-1" /> DNS
                      </div>
                      <div class="w-full text-sm">
                        Manage access to an application or service by DNS address.
                      </div>
                    </div>
                  </label>
                </li>
                <li>
                  <.input
                    id="resource-type--ip"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="ip"
                    checked={@form[:type].value == :ip}
                    required
                  />
                  <label for="resource-type--ip" class={~w[
                    inline-flex items-center justify-between w-full
                    p-5 text-gray-500 bg-white border border-gray-200
                    rounded cursor-pointer peer-checked:border-accent-600
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="block">
                      <div class="w-full font-semibold mb-3">
                        <.icon name="hero-server" class="w-5 h-5 mr-1" /> IP
                      </div>
                      <div class="w-full text-sm">
                        Manage access to a specific host by IP address.
                      </div>
                    </div>
                  </label>
                </li>
                <li>
                  <.input
                    id="resource-type--cidr"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="cidr"
                    checked={@form[:type].value == :cidr}
                    required
                  />
                  <label for="resource-type--cidr" class={~w[
                    inline-flex items-center justify-between w-full
                    p-5 text-gray-500 bg-white border border-gray-200
                    rounded cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="block">
                      <div class="w-full font-semibold mb-3">
                        <.icon name="hero-server-stack" class="w-5 h-5 mr-1" /> CIDR
                      </div>
                      <div class="w-full text-sm">
                        Manage access to a network, VPC or subnet by CIDR address.
                      </div>
                    </div>
                  </label>
                </li>
              </ul>
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
                    true -> "First select a type above"
                  end
                }
                class={is_nil(@form[:type].value) && "cursor-not-allowed"}
                disabled={is_nil(@form[:type].value)}
                required
              />

              <p
                :if={
                  @form[:type].value == :dns and
                    is_binary(@form[:address].value) and
                    @form[:address].value
                    |> String.codepoints()
                    |> Resources.map_resource_address() == :drop
                }
                class="flex items-center gap-2 text-sm leading-6 text-accent-600 mt-2 w-full"
              >
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                This is an advanced address format. This Resource will be available to Clients and Gateways v1.2.0 and higher only.
              </p>
              <div :if={@form[:type].value == :dns}>
                <div class="mt-2 text-xs text-neutral-500">
                  Wildcard matching is supported:
                </div>
                <div class="mt-2 text-xs text-neutral-500">
                  <code class="ml-2 px-0.5 font-semibold">**.c.com</code>
                  matches any level of subdomains (e.g. <code class="px-0.5 font-semibold">foo.c.com</code>,
                  <code class="px-0.5 font-semibold">bar.foo.c.com</code>
                  and <code class="px-0.5 font-semibold">c.com</code>).<br />
                  <code class="ml-2 px-0.5 font-semibold">*.c.com</code>
                  matches zero or single-level subdomains (e.g.
                  <code class="px-0.5 font-semibold">foo.c.com</code>
                  and <code class="px-0.5 font-semibold">c.com</code>
                  but not <code class="px-0.5 font-semibold">bar.foo.c.com</code>). <br />
                  <code class="ml-2 px-0.5 font-semibold">us-east?.c.com</code>
                  matches a single character (e.g. <code class="px-0.5 font-semibold">us-east1.c.com</code>).
                </div>
              </div>
              <div :if={@form[:type].value == :ip} class="mt-2 text-xs text-neutral-500">
                IPv4 and IPv6 addresses are supported.
              </div>
              <div :if={@form[:type].value == :cidr} class="mt-2 text-xs text-neutral-500">
                IPv4 and IPv6 CIDR ranges are supported.
              </div>
            </div>

            <div>
              <.input
                field={@form[:address_description]}
                type="text"
                label="Address Description"
                placeholder="Enter a description or URL"
              />
              <p class="mt-2 text-xs text-neutral-500">
                Optional description or URL to show in Clients to help users access this Resource.
              </p>
            </div>

            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Name this resource"
              required
            />

            <.filters_form account={@account} form={@form[:filters]} />

            <.connections_form
              :if={is_nil(@params["site_id"])}
              multiple={Accounts.multi_site_resources_enabled?(@account)}
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
      |> map_filters_form_attrs(socket.assigns.account)
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
      |> map_filters_form_attrs(socket.assigns.account)
      |> map_connections_form_attrs()
      |> maybe_put_connections(socket.assigns.params)

    case Resources.create_resource(attrs, socket.assigns.subject) do
      {:ok, resource} ->
        socket = put_flash(socket, :info, "Resource #{resource.name} created successfully.")

        if site_id = socket.assigns.params["site_id"] do
          {:noreply,
           socket
           |> push_navigate(
             to:
               ~p"/#{socket.assigns.account}/policies/new?resource_id=#{resource}&site_id=#{site_id}"
           )}
        else
          {:noreply,
           socket
           |> push_navigate(
             to: ~p"/#{socket.assigns.account}/policies/new?resource_id=#{resource}"
           )}
        end

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
