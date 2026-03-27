# credo:disable-for-this-file Credo.Check.Warning.CrossModuleDatabaseCall
defmodule PortalWeb.Resources.Edit do
  use PortalWeb, :live_view
  import PortalWeb.Resources.Components
  alias __MODULE__.Database

  def mount(%{"id" => id} = params, _session, socket) do
    resource = Database.get_resource!(id, socket.assigns.subject)
    sites = Database.all_sites(socket.assigns.subject)

    client_to_client_enabled? =
      Database.client_to_client_enabled?(socket.assigns.account) or
        resource.type == :static_device_pool

    form = change_resource(resource, socket.assigns.subject) |> to_form()
    selected_clients = resource.static_pool_members |> Enum.map(& &1.client)

    socket =
      assign(
        socket,
        resource: resource,
        sites: sites,
        client_to_client_enabled?: client_to_client_enabled?,
        selected_clients: selected_clients,
        client_search_results: nil,
        client_search: "",
        form: form,
        params: Map.take(params, ["site_id"]),
        page_title: "Edit #{resource.name}"
      )

    {:ok, socket}
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
              <ul class={"grid w-full gap-6 #{if @client_to_client_enabled?, do: "md:grid-cols-4", else: "md:grid-cols-3"}"}>
                <li class="flex flex-col">
                  <.input
                    id="resource-type--dns"
                    type="radio_button_group"
                    field={@form[:type]}
                    value="dns"
                    checked={to_string(@form[:type].value) == "dns"}
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
                    checked={to_string(@form[:type].value) == "ip"}
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
                    checked={to_string(@form[:type].value) == "cidr"}
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
                    checked={to_string(@form[:type].value) == "static_device_pool"}
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

            <div :if={
              @resource.type != :internet and to_string(@form[:type].value) != "static_device_pool"
            }>
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

            <div :if={
              @resource.type != :internet and to_string(@form[:type].value) != "static_device_pool"
            }>
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

            <div :if={to_string(@form[:type].value) == "static_device_pool"}>
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
              :if={
                is_nil(@params["site_id"]) and to_string(@form[:type].value) != "static_device_pool"
              }
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

  def handle_event("submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> map_filters_form_attrs(socket.assigns.account)
      |> maybe_update_site_id(socket.assigns.params)

    changeset = change_resource(socket.assigns.resource, attrs, socket.assigns.subject)

    case Database.update_resource(
           changeset,
           socket.assigns.selected_clients,
           socket.assigns.subject
         ) do
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
    if attrs["type"] == "static_device_pool" do
      Map.delete(attrs, "site_id")
    else
      maybe_update_site_id_for_non_static_pool(attrs, params)
    end
  end

  defp maybe_update_site_id_for_non_static_pool(attrs, params) do
    if site_id = params["site_id"] do
      Map.put(attrs, "site_id", site_id)
    else
      attrs
    end
  end

  defp change_resource(resource, attrs \\ %{}, _subject) do
    update_fields = ~w[address address_description name type ip_stack site_id]a

    required_fields =
      if attrs["type"] == "static_device_pool" do
        ~w[name type]a
      else
        ~w[name type site_id]a
      end

    resource
    |> Ecto.Changeset.cast(attrs, update_fields)
    |> Ecto.Changeset.validate_required(required_fields)
    |> Portal.Resource.changeset()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, Resource}
    alias PortalWeb.Resources.Components

    defdelegate client_to_client_enabled?(account), to: Components.Database
    defdelegate all_sites(subject), to: Components.Database
    defdelegate get_client(client_id, subject), to: Components.Database
    defdelegate search_clients(search_term, subject, selected_clients), to: Components.Database

    def get_resource!(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> preload([:site, static_pool_members: :client])
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def update_resource(changeset, selected_clients, subject) do
      changeset =
        Components.Database.validate_static_device_pool_feature_enabled(
          changeset,
          subject.account
        )

      with {:ok, selected_clients} <-
             Components.Database.validate_selected_clients(selected_clients, subject),
           {:ok, resource} <- Safe.scoped(changeset, subject) |> Safe.update(),
           :ok <-
             Components.Database.sync_static_pool_members(resource, selected_clients, subject) do
        {:ok, resource}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, :invalid_clients} ->
          {:error,
           Ecto.Changeset.add_error(changeset, :name, "one or more selected clients are invalid")}

        {:error, :unauthorized} ->
          {:error,
           Ecto.Changeset.add_error(
             changeset,
             :name,
             "you are not authorized to perform this action"
           )}
      end
    end
  end
end
