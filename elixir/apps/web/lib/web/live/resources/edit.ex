defmodule Web.Resources.Edit do
  use Web, :live_view
  import Web.Resources.Components
  alias Domain.{Accounts, Gateways, Resources}

  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, resource} <-
           Resources.fetch_resource_by_id(id, socket.assigns.subject,
             preload: :gateway_groups,
             filter: [
               deleted?: false
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
        <%= @resource.name %>
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
          <h2 class="mb-4 text-xl text-neutral-900">Edit Resource details</h2>

          <.form for={@form} phx-change={:change} phx-submit={:submit} class="space-y-4 lg:space-y-6">
            <.input
              :if={@resource.type != :internet}
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Name this resource"
              required
            />

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

    case Resources.update_or_replace_resource(
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

      {:replaced, updated_resource, created_resource} ->
        socket =
          put_flash(
            socket,
            :info,
            "New version of resource #{resource.name} is created successfully."
          )

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
