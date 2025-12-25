defmodule PortalWeb.Resources.Edit do
  use PortalWeb, :live_view
  import PortalWeb.Resources.Components
  alias __MODULE__.DB

  def mount(%{"id" => id} = params, _session, socket) do
    resource = DB.get_resource!(id, socket.assigns.subject)
    sites = DB.all_sites(socket.assigns.subject)
    form = change_resource(resource, socket.assigns.subject) |> to_form()

    socket =
      assign(
        socket,
        resource: resource,
        sites: sites,
        form: form,
        params: Map.take(params, ["site_id"]),
        page_title: "Edit #{resource.name}"
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
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
                phx-debounce="300"
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
                <div class="mt-2 text-xs text-neutral-500">
                  The search domain can be <.link
                    href={~p"/#{@account}/settings/dns"}
                    class={link_style()}
                  >configured in settings</.link>.
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
                phx-debounce="300"
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
              phx-debounce="300"
              required
            />

            <.ip_stack_form :if={"#{@form[:type].value}" == "dns"} form={@form} />

            <.filters_form
              :if={@resource.type != :internet}
              account={@account}
              form={@form[:filters]}
            />

            <.site_form
              :if={is_nil(@params["site_id"])}
              form={@form}
              sites={@sites}
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
      |> maybe_update_site_id(socket.assigns.params)

    changeset =
      change_resource(socket.assigns.resource, attrs, socket.assigns.subject)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> map_filters_form_attrs(socket.assigns.account)
      |> maybe_update_site_id(socket.assigns.params)

    changeset = update_changeset(socket.assigns.resource, attrs, socket.assigns.subject)

    case DB.update_resource(changeset, socket.assigns.subject) do
      {:ok, resource} ->
        socket = put_flash(socket, :success, "Resource #{resource.name} updated successfully")

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

  defp maybe_update_site_id(attrs, params) do
    if site_id = params["site_id"] do
      Map.put(attrs, "site_id", site_id)
    else
      attrs
    end
  end

  defp change_resource(resource, attrs \\ %{}, subject) do
    update_fields = ~w[address address_description name type ip_stack site_id]a
    required_fields = ~w[name type site_id]a

    resource
    |> Ecto.Changeset.cast(attrs, update_fields)
    |> Ecto.Changeset.validate_required(required_fields)
    |> Portal.Resource.validate_address(subject.account)
    |> Portal.Resource.changeset()
  end

  defp update_changeset(resource, attrs, subject) do
    update_fields = ~w[address address_description name type ip_stack site_id]a
    required_fields = ~w[name type site_id]a

    resource
    |> Ecto.Changeset.cast(attrs, update_fields)
    |> Ecto.Changeset.validate_required(required_fields)
    |> Portal.Resource.validate_address(subject.account)
    |> Portal.Resource.changeset()
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Safe, Resource}

    def all_sites(subject) do
      from(s in Portal.Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def get_resource!(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> preload(:site)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_resource(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end
  end
end
