# credo:disable-for-this-file Credo.Check.Warning.CrossModuleDatabaseCall
defmodule PortalWeb.Resources.New do
  use PortalWeb, :live_view
  import PortalWeb.Resources.Components
  alias __MODULE__.Database

  def mount(params, _session, socket) do
    sites = Database.all_sites(socket.assigns.subject)
    changeset = Database.new_resource(socket.assigns.account)
    client_to_client_enabled? = Database.client_to_client_enabled?(socket.assigns.account)

    socket =
      assign(
        socket,
        sites: sites,
        selected_clients: [],
        client_search_results: nil,
        client_search: "",
        client_to_client_enabled?: client_to_client_enabled?,
        address_description_changed?: false,
        name_changed?: false,
        form: to_form(changeset),
        params: Map.take(params, ["site_id"]),
        page_title: "New Resource"
      )

    {:ok, socket}
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
              <ul class="grid w-full gap-6 md:grid-cols-4">
                <li class="flex flex-col">
                  <.input
                    id="resource-type--dns"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="dns"
                    checked={@form[:type].value == :dns}
                    required
                  />
                  <label for="resource-type--dns" class={~w[
                    flex flex-1 flex-col justify-between w-full
                    p-4 text-neutral-500 bg-white border border-neutral-200
                    rounded-sm cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="font-semibold mb-2 whitespace-nowrap">
                      <.icon name="hero-globe-alt" class="w-5 h-5 mr-1" /> DNS
                    </div>
                    <div class="text-sm">
                      Manage access to an application or service by DNS address.
                    </div>
                  </label>
                </li>
                <li class="flex flex-col">
                  <.input
                    id="resource-type--ip"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="ip"
                    checked={@form[:type].value == :ip}
                    required
                  />
                  <label for="resource-type--ip" class={~w[
                    flex flex-1 flex-col justify-between w-full
                    p-4 text-neutral-500 bg-white border border-neutral-200
                    rounded-sm cursor-pointer peer-checked:border-accent-600
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="font-semibold mb-2 whitespace-nowrap">
                      <.icon name="hero-server" class="w-5 h-5 mr-1" /> IP
                    </div>
                    <div class="text-sm">
                      Manage access to a specific host by IP address.
                    </div>
                  </label>
                </li>
                <li class="flex flex-col">
                  <.input
                    id="resource-type--cidr"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="cidr"
                    checked={@form[:type].value == :cidr}
                    required
                  />
                  <label for="resource-type--cidr" class={~w[
                    flex flex-1 flex-col justify-between w-full
                    p-4 text-neutral-500 bg-white border border-neutral-200
                    rounded-sm cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="font-semibold mb-2 whitespace-nowrap">
                      <.icon name="hero-server-stack" class="w-5 h-5 mr-1" /> CIDR
                    </div>
                    <div class="text-sm">
                      Manage access to a network, VPC or subnet by CIDR address.
                    </div>
                  </label>
                </li>
                <li :if={@client_to_client_enabled?} class="flex flex-col">
                  <.input
                    id="resource-type--static-device-pool"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="static_device_pool"
                    checked={@form[:type].value == :static_device_pool}
                    required
                  />
                  <label for="resource-type--static-device-pool" class={~w[
                    flex flex-1 flex-col justify-between w-full
                    p-4 text-neutral-500 bg-white border border-neutral-200
                    rounded-sm cursor-pointer peer-checked:border-accent-500
                    peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                  ]}>
                    <div class="font-semibold mb-2 whitespace-nowrap">
                      <.icon name="hero-computer-desktop" class="w-5 h-5 mr-1" /> Device Pool
                    </div>
                    <div class="text-sm">
                      Direct access to other Firezone devices without a Gateway.
                    </div>
                  </label>
                </li>
              </ul>
            </div>

            <div :if={@form[:type].value != :static_device_pool}>
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

            <div :if={@form[:type].value != :static_device_pool}>
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

            <div :if={@form[:type].value == :static_device_pool}>
              <legend class="text-xl mb-2">Devices</legend>
              <p class="text-sm text-neutral-500 mb-4">
                Select clients to include in this pool. Search by name, IPv4, IPv6, id, serial, UUID, and other identifiers.
              </p>
              <.client_picker
                selected_clients={@selected_clients}
                client_search={@client_search}
                client_search_results={@client_search_results}
              />
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
              :if={is_nil(@params["site_id"]) and @form[:type].value != :static_device_pool}
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
      Database.new_resource(socket.assigns.account, attrs)
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

    case Database.create_resource(attrs, socket.assigns.selected_clients, socket.assigns.subject) do
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

  def handle_event("focus_client_search", _params, socket) do
    results =
      Database.search_clients(
        socket.assigns.client_search,
        socket.assigns.subject,
        socket.assigns.selected_clients
      )

    {:noreply, assign(socket, client_search_results: results)}
  end

  def handle_event("blur_client_search", _params, socket) do
    {:noreply, assign(socket, client_search_results: nil)}
  end

  def handle_event("search_client", %{"client_search" => search}, socket) do
    results =
      Database.search_clients(search, socket.assigns.subject, socket.assigns.selected_clients)

    {:noreply,
     assign(socket,
       client_search: search,
       client_search_results: results
     )}
  end

  def handle_event("add_client", %{"client_id" => client_id}, socket) do
    case Database.get_client(client_id, socket.assigns.subject) do
      nil ->
        {:noreply, socket}

      client ->
        selected_clients = Enum.uniq_by([client | socket.assigns.selected_clients], & &1.id)

        {:noreply,
         assign(socket,
           selected_clients: selected_clients,
           client_search: "",
           client_search_results: nil
         )}
    end
  end

  def handle_event("remove_client", %{"client_id" => client_id}, socket) do
    selected_clients = Enum.reject(socket.assigns.selected_clients, &(&1.id == client_id))

    results =
      Database.search_clients(
        socket.assigns.client_search,
        socket.assigns.subject,
        selected_clients
      )

    {:noreply,
     assign(socket,
       selected_clients: selected_clients,
       client_search_results: results
     )}
  end

  defp maybe_put_default_name(attrs, name_changed? \\ true)

  defp maybe_put_default_name(attrs, true) do
    attrs
  end

  defp maybe_put_default_name(attrs, false) do
    Map.put(attrs, "name", attrs["address"])
  end

  defp maybe_put_site_id(attrs, params) do
    if attrs["type"] == "static_device_pool" do
      Map.delete(attrs, "site_id")
    else
      maybe_put_site_id_for_non_static_pool(attrs, params)
    end
  end

  defp maybe_put_site_id_for_non_static_pool(attrs, params) do
    if site_id = params["site_id"] do
      Map.put(attrs, "site_id", site_id)
    else
      attrs
    end
  end

  defmodule Database do
    import Ecto.Changeset
    alias Portal.{Safe, Resource}
    alias PortalWeb.Resources.Components

    defdelegate client_to_client_enabled?(account), to: Components.Database
    defdelegate all_sites(subject), to: Components.Database
    defdelegate get_client(client_id, subject), to: Components.Database
    defdelegate search_clients(search_term, subject, selected_clients), to: Components.Database

    # TODO: Keep all changeset logic out of the DB module
    def new_resource(account, attrs \\ %{}) do
      changeset =
        %Resource{account_id: account.id}
        |> cast(attrs, [:name, :address, :address_description, :type, :ip_stack, :site_id])
        |> Resource.changeset()

      if get_field(changeset, :type) == :static_device_pool do
        validate_required(changeset, [:name])
      else
        validate_required(changeset, [:name, :address])
      end
    end

    def create_resource(attrs, selected_clients, subject) do
      changeset =
        new_resource(subject.account, attrs)
        |> maybe_validate_required_fields()
        |> Components.Database.validate_static_device_pool_feature_enabled(subject.account)

      with {:ok, selected_clients} <-
             Components.Database.validate_selected_clients(selected_clients, subject),
           {:ok, resource} <- Safe.scoped(changeset, subject) |> Safe.insert(),
           :ok <-
             Components.Database.sync_static_pool_members(resource, selected_clients, subject) do
        {:ok, resource}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, :invalid_clients} ->
          {:error, add_error(changeset, :name, "one or more selected clients are invalid")}

        {:error, :unauthorized} ->
          {:error, add_error(changeset, :name, "you are not authorized to perform this action")}
      end
    end

    defp maybe_validate_required_fields(changeset) do
      if get_field(changeset, :type) == :static_device_pool do
        validate_required(changeset, [:name])
      else
        validate_required(changeset, [:site_id])
      end
    end
  end
end
