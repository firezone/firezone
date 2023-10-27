defmodule Web.Sites.Resources.Edit do
  use Web, :live_view
  import Web.Resources.Components
  alias Domain.Gateways
  alias Domain.Resources

  def mount(%{"gateway_group_id" => gateway_group_id, "id" => id}, _session, socket) do
    with {:ok, gateway_group} <-
           Gateways.fetch_group_by_id(gateway_group_id, socket.assigns.subject),
         {:ok, resource} <-
           Resources.fetch_resource_by_id(id, socket.assigns.subject, preload: [:connections]) do
      form =
        Resources.change_resource(resource, socket.assigns.subject)
        |> to_form()

      {:ok, assign(socket, resource: resource, form: form),
       temporary_assigns: [
         gateway_group: gateway_group
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
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway_group}/resources/#{@resource}"}>
        <%= @resource.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway_group}/resources/#{@resource}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Resource
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit Resource details</h2>

          <.form for={@form} phx-change={:change} phx-submit={:submit} class="space-y-4 lg:space-y-6">
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Name this resource"
              required
            />

            <.filters_form form={@form[:filters]} />

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
      |> map_filters_form_attrs()
      |> Map.delete("connections")

    changeset =
      Resources.change_resource(socket.assigns.resource, attrs, socket.assigns.subject)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"resource" => attrs}, socket) do
    attrs =
      attrs
      |> map_filters_form_attrs()
      |> Map.delete("connections")

    case Resources.update_resource(socket.assigns.resource, attrs, socket.assigns.subject) do
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
