defmodule Web.Resources.Edit do
  use Web, :live_view

  alias Domain.Gateways
  alias Domain.Resources
  alias Web.ResourceForm

  def mount(%{"id" => id}, _session, socket) do
    {:ok, resource} =
      Resources.fetch_resource_by_id(id, socket.assigns.subject, preload: :gateway_groups)

    {:ok, gateway_groups} = Gateways.list_groups(socket.assigns.subject)

    resource_form = Web.ResourceForm.from_domain(resource, gateway_groups)
    socket = assign(socket, form: to_form(resource_form), resource: resource)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/#{@resource.id}"}>
        <%= @resource.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/#{@resource.id}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Edit Resource
      </:title>
    </.header>
    <!-- Edit Resource -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit Resource details</h2>
        <.simple_form
          for={@form}
          class="space-y-4 lg:space-y-6"
          phx-submit="submit"
          phx-change="validate"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            placeholder="Name this Resource"
            required
            phx-debounce="300"
          />
          <.input
            field={@form[:address]}
            autocomplete="off"
            type="text"
            label="Address"
            placeholder="Enter IP address, CIDR, or DNS name"
            required
            phx-debounce="300"
          />

          <fieldset class="flex flex-col gap-2">
            <legend class="mb-2">Traffic Restriction</legend>
            <div class="">
              <.inputs_for :let={filter} field={@form[:filters]}>
                <.filter field={filter} />
              </.inputs_for>
            </div>
          </fieldset>

          <hr />

          <fieldset class="flex flex-col gap-2">
            <legend class="mb-2">Gateway Instance Groups</legend>
            <div class="">
              <.inputs_for :let={gateway} field={@form[:connections]}>
                <.gateway field={gateway} />
              </.inputs_for>
            </div>
          </fieldset>

          <:actions>
            <.button phx-disable-with="Updating Resource..." class="w-full">
              Update Resource
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </section>
    """
  end

  # TODO: Move this in to the resource/components.ex components module
  def filter(assigns) do
    ~H"""
    <div class="items-center flex flex-row h-16">
      <div class="flex-none w-32">
        <.input
          type="checkbox"
          field={@field[:enabled]}
          label={ResourceForm.display_name(@field[:protocol].value)}
          checked={@field[:enabled].value}
        />
        <.input type="hidden" field={@field[:protocol]} />
      </div>
      <div class="flex-grow">
        <.input
          :if={@field[:protocol].value in ["tcp", "udp"]}
          field={@field[:ports]}
          placeholder="Enter port range(s)"
          phx-debounce="300"
        />
        <.input :if={@field[:protocol].value in ["all", "icmp"]} type="hidden" field={@field[:ports]} />
      </div>
    </div>
    """
  end

  # TODO: Move this in to the resource/components.ex components module
  def gateway(assigns) do
    ~H"""
    <.input type="hidden" field={@field[:gateway_group_id]} />
    <div class="flex gap-4 items-end py-4 text-sm border-b">
      <div class="w-8">
        <.input type="checkbox" field={@field[:enabled]} />
      </div>
      <div class="w-64 no-grow text-gray-500">
        <.input type="hidden" field={@field[:gateway_group_name]} />
        <p><%= @field[:gateway_group_name].value %></p>
      </div>
      <div>
        <.badge type="success">TODO: Online</.badge>
      </div>
    </div>
    """
  end

  def handle_event("validate", %{"resource_form" => attrs}, socket) do
    changeset =
      ResourceForm.new_resource_form(attrs)
      |> Map.put(:action, :validate)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  def handle_event("submit", %{"resource_form" => attrs}, socket) do
    with {:ok, valid_form} <- ResourceForm.validate(attrs) do
      case Resources.update_resource(
             socket.assigns.resource,
             ResourceForm.to_domain_attrs(valid_form),
             socket.assigns.subject
           ) do
        {:ok, resource} ->
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources/#{resource.id}")}

        {:error, changeset} ->
          form_changeset = ResourceForm.map_errors(attrs, changeset) |> Map.put(:action, :insert)
          {:noreply, assign(socket, form: to_form(form_changeset))}
      end
    else
      {:error, changeset} ->
        socket = assign(socket, form: to_form(changeset))
        {:noreply, socket}
    end
  end
end
