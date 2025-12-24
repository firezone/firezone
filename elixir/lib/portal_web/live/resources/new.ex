defmodule PortalWeb.Resources.New do
  use Web, :live_view
  import PortalWeb.Resources.Components
  alias __MODULE__.DB

  def mount(params, _session, socket) do
    sites = DB.all_sites(socket.assigns.subject)
    changeset = DB.new_resource(socket.assigns.account)

    socket =
      assign(
        socket,
        sites: sites,
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
                phx-debounce="300"
                required
              />

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
                <div class="mt-2 text-xs text-neutral-500">
                  The search domain can be <.link
                    href={~p"/#{@account}/settings/dns"}
                    class={link_style()}
                  >configured in settings</.link>.
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
                phx-debounce="300"
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
              phx-debounce="300"
              required
            />

            <.ip_stack_form :if={"#{@form[:type].value}" == "dns"} form={@form} />

            <.filters_form account={@account} form={@form[:filters]} />

            <.site_form
              :if={is_nil(@params["site_id"])}
              form={@form}
              sites={@sites}
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
      |> maybe_put_site_id(socket.assigns.params)

    changeset =
      DB.new_resource(socket.assigns.account, attrs)
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
      |> maybe_put_site_id(socket.assigns.params)

    case DB.create_resource(attrs, socket.assigns.subject) do
      {:ok, resource} ->
        socket = put_flash(socket, :success, "Resource #{resource.name} created successfully")

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

  defp maybe_put_site_id(attrs, params) do
    if site_id = params["site_id"] do
      Map.put(attrs, "site_id", site_id)
    else
      attrs
    end
  end

  defmodule DB do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Safe, Resource}

    def all_sites(subject) do
      from(g in Portal.Site, as: :sites)
      |> where([sites: s], s.managed_by != :system)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    # TODO: Keep all changeset logic out of the DB module
    def new_resource(account, attrs \\ %{}) do
      %Resource{}
      |> cast(attrs, [:name, :address, :address_description, :type, :ip_stack, :site_id])
      |> validate_required([:name, :address])
      |> put_change(:account_id, account.id)
      |> Resource.changeset()
    end

    def create_resource(attrs, subject) do
      changeset =
        new_resource(subject.account, attrs)
        |> validate_required([:site_id])

      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end
  end
end
