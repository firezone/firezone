defmodule Web.Resources.Edit do
  use Web, :live_view
  import Web.Resources.Components
  alias Domain.{Accounts, Gateways, Resources}

  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, resource} <-
           Resources.fetch_resource_by_id(id, socket.assigns.subject,
             preload: :gateway_groups,
             filter: [
               deleted?: false,
               type: ["cidr", "dns", "ip"]
             ]
           ) do
      gateway_groups = Gateways.all_groups!(socket.assigns.subject)
      form = Resources.change_resource(resource, socket.assigns.subject) |> to_form()

      socket =
        assign(
          socket,
          resource: resource,
          gateway_groups: gateway_groups,
          form: form,
          params: Map.take(params, ["site_id"]),
          page_title: "Edit #{resource.name}"
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
      <.breadcrumb path={~p"/#{@account}/resources/#{@resource.id}"}>
        {@resource.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/#{@resource.id}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Resource
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit} class="space-y-4 lg:space-y-6">
            <div :if={@resource.type != :internet}>
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
                    checked={to_string(@form[:type].value) == "dns"}
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
                    checked={to_string(@form[:type].value) == "ip"}
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
                    checked={to_string(@form[:type].value) == "cidr"}
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

            <div :if={@resource.type != :internet}>
              <.input
                field={@form[:address]}
                autocomplete="off"
                label="Address"
                placeholder={
                  cond do
                    to_string(@form[:type].value) == "dns" -> "gitlab.company.com"
                    to_string(@form[:type].value) == "cidr" -> "10.0.0.0/24"
                    to_string(@form[:type].value) == "ip" -> "10.3.2.1"
                    true -> "First select a type above"
                  end
                }
                class={is_nil(@form[:type].value) && "cursor-not-allowed"}
                disabled={is_nil(@form[:type].value)}
                required
              />

              <div :if={to_string(@form[:type].value) == "dns"}>
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
              <div :if={to_string(@form[:type].value) == "ip"} class="mt-2 text-xs text-neutral-500">
                IPv4 and IPv6 addresses are supported.
              </div>
              <div :if={to_string(@form[:type].value) == "cidr"} class="mt-2 text-xs text-neutral-500">
                IPv4 and IPv6 CIDR ranges are supported.
              </div>
            </div>

            <div :if={@resource.type != :internet}>
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
              :if={@resource.type != :internet}
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Name this resource"
              required
            />

            <.filters_form
              :if={@resource.type != :internet}
              account={@account}
              form={@form[:filters]}
            />

            <.connections_form
              :if={is_nil(@params["site_id"])}
              id="connections_form"
              multiple={Accounts.multi_site_resources_enabled?(@account)}
              form={@form[:connections]}
              account={@account}
              resource={@resource}
              gateway_groups={@gateway_groups}
            />

            <.submit_button phx-disable-with="Updating Resource...">
              Save
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> map_filters_form_attrs(socket.assigns.account)
      |> map_connections_form_attrs()
      |> maybe_delete_connections(socket.assigns.params)

    changeset =
      Resources.change_resource(socket.assigns.resource, attrs, socket.assigns.subject)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> map_filters_form_attrs(socket.assigns.account)
      |> map_connections_form_attrs()
      |> maybe_delete_connections(socket.assigns.params)

    case Resources.update_resource(
           socket.assigns.resource,
           attrs,
           socket.assigns.subject
         ) do
      {:updated, resource} ->
        socket = put_flash(socket, :info, "Resource #{resource.name} updated successfully.")

        if site_id = socket.assigns.params["site_id"] do
          {:noreply,
           push_navigate(socket,
             to: ~p"/#{socket.assigns.account}/sites/#{site_id}"
           )}
        else
          {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources")}
        end

      {:error, changeset} ->
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp maybe_delete_connections(attrs, params) do
    if params["site_id"] do
      Map.delete(attrs, "connections")
    else
      attrs
    end
  end
end
