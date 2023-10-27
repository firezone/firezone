defmodule Web.Sites.Resources.New do
  use Web, :live_view
  import Web.Resources.Components
  alias Domain.{Gateways, Resources}

  def mount(%{"gateway_group_id" => gateway_group_id}, _session, socket) do
    with {:ok, gateway_group} <-
           Gateways.fetch_group_by_id(gateway_group_id, socket.assigns.subject) do
      changeset = Resources.new_resource(socket.assigns.account)

      {:ok, assign(socket, gateway_group: gateway_group),
       temporary_assigns: [
         gateway_groups: [],
         form: to_form(changeset)
       ]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway_group}"}>
        <%= @gateway_group.name_prefix %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway_group}?#resources"}>Resources</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway_group}/resources/new"}>
        Add Resource
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Add Resource
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Resource details</h2>
          <.form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="change">
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Name this resource"
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

            <.filters_form form={@form[:filters]} />

            <.submit_button phx-disable-with="Creating Resource...">
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
      |> map_filters_form_attrs()
      |> Map.put("connections", [%{gateway_group_id: socket.assigns.gateway_group.id}])

    changeset =
      Resources.new_resource(socket.assigns.account, attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> map_filters_form_attrs()
      |> Map.put("connections", [%{gateway_group_id: socket.assigns.gateway_group.id}])

    case Resources.create_resource(attrs, socket.assigns.subject) do
      {:ok, resource} ->
        {:noreply,
         push_navigate(socket,
           to:
             ~p"/#{socket.assigns.account}/sites/#{socket.assigns.gateway_group}/resources/#{resource}"
         )}

      {:error, changeset} ->
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
