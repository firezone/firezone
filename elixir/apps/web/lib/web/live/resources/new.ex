defmodule Web.Resources.New do
  use Web, :live_view

  alias Domain.Gateways
  alias Domain.Resources
  alias Web.ResourceForm

  def mount(_params, _session, socket) do
    {:ok, gateway_groups} = Gateways.list_groups(socket.assigns.subject)

    connections =
      Enum.map(gateway_groups, fn group ->
        %{
          "enabled" => false,
          "gateway_group_id" => group.id,
          "gateway_group_name" => group.name_prefix
        }
      end)

    form =
      %{ResourceForm.default_attrs() | "connections" => connections}
      |> ResourceForm.new_resource_form()
      |> to_form()

    {:ok, assign(socket, form: form)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/resources/new"}>Add Resource</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Add Resource
      </:title>
    </.header>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Resource details</h2>
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
          <hr />

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
            <.button phx-disable-with="Creating Resource..." class="w-full">
              Create Resource
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </section>
    """
  end

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
      case Resources.create_resource(
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
