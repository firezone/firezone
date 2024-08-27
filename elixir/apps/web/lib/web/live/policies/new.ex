defmodule Web.Policies.New do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Resources, Actors, Policies, Auth}

  @resource_types %{
    internet: %{index: 1, label: nil},
    dns: %{index: 2, label: "DNS"},
    ip: %{index: 3, label: "IP"},
    cidr: %{index: 4, label: "CIDR"}
  }

  def mount(params, _session, socket) do
    # TODO: unify this dropdown and the one we use for live table filters
    resources = Resources.all_resources!(socket.assigns.subject, preload: [:gateway_groups])
    # TODO: unify this dropdown and the one we use for live table filters
    actor_groups = Actors.all_groups!(socket.assigns.subject, preload: :provider)
    providers = Auth.all_active_providers_for_account!(socket.assigns.account)
    form = to_form(Policies.new_policy(%{}, socket.assigns.subject))

    socket =
      assign(socket,
        resources: resources,
        actor_groups: actor_groups,
        providers: providers,
        params: Map.take(params, ["site_id"]),
        resource_id: params["resource_id"],
        actor_group_id: params["actor_group_id"],
        page_title: "New Policy",
        timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
        form: form
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/new"}>Add Policy</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title><%= @page_title %></:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Policy details</h2>
          <div
            :if={@actor_groups == []}
            class={[
              "p-4 text-sm flash-error",
              "text-red-800 bg-red-50"
            ]}
            role="alert"
          >
            <p class="text-sm leading-6">
              <.icon name="hero-exclamation-circle-mini" class="h-4 w-4" />
              You have no groups to create policies for. You can create a group <.link
                navigate={~p"/#{@account}/groups/new"}
                class={link_style()}
              >here</.link>.
            </p>
          </div>

          <.form :if={@actor_groups != []} for={@form} phx-submit="submit" phx-change="validate">
            <.base_error form={@form} field={:base} />
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset class="flex flex-col gap-2">
                <.input
                  field={@form[:actor_group_id]}
                  label="Group"
                  type="group_select"
                  options={Web.Groups.Components.select_options(@actor_groups)}
                  value={@actor_group_id || @form[:actor_group_id].value}
                  disabled={not is_nil(@actor_group_id)}
                  required
                />

                <% resource_id =
                  @resource_id ||
                    @form[:resource_id].value ||
                    (length(@resources) > 0 and Enum.at(@resources, 0).id) %>

                <.input
                  field={@form[:resource_id]}
                  label="Resource"
                  type="group_select"
                  options={to_options(@resources, @account)}
                  value={resource_id}
                  disabled={not is_nil(@resource_id)}
                  required
                />

                <% resource = Enum.find(@resources, &(&1.id == resource_id)) %>

                <p
                  :if={not is_nil(resource) and length(resource.connections) == 0}
                  class="flex items-center gap-2 text-sm leading-6 text-orange-600 mt-2 w-full"
                  data-validation-error-for="policy[resource_id]"
                >
                  <.icon name="hero-exclamation-triangle-mini" class="h-4 w-4" />
                  This Resource isn't linked to any Sites, so Clients won't be able to access it.
                </p>

                <.input
                  field={@form[:description]}
                  label="Description"
                  type="textarea"
                  placeholder="Enter an optional reason for creating this policy here."
                  phx-debounce="300"
                />
              </fieldset>

              <.conditions_form
                :if={is_nil(resource) or resource.type != :internet}
                form={@form}
                account={@account}
                timezone={@timezone}
                providers={@providers}
              />

              <.options_form
                :if={not is_nil(resource) and resource.type == :internet}
                form={@form}
                account={@account}
                timezone={@timezone}
                providers={@providers}
              />
            </div>

            <div class="flex justify-end">
              <.submit_button phx-disable-with="Creating Policy..." class="w-full">
                Create Policy
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  defp to_options(resources, account) do
    resources
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {type, _} ->
      Map.fetch!(@resource_types, type) |> Map.fetch!(:index)
    end)
    |> Enum.map(fn {type, resources} ->
      options =
        resources
        |> Enum.sort_by(fn resource -> resource.name end)
        |> Enum.map(&resource_option(&1, account))

      label = Map.fetch!(@resource_types, type) |> Map.fetch!(:label)

      {label, options}
    end)
  end

  defp resource_option(%{type: :internet} = resource, account) do
    gateway_group_names = resource.gateway_groups |> Enum.map(& &1.name)

    if Domain.Accounts.internet_resource_enabled?(account) do
      [
        key: "Internet - #{Enum.join(gateway_group_names, ",")}",
        value: resource.id
      ]
    else
      [
        key: "Internet - upgrade to unlock",
        value: resource.id,
        disabled: true
      ]
    end
  end

  defp resource_option(resource, _account) do
    gateway_group_names = resource.gateway_groups |> Enum.map(& &1.name)

    [
      key: "#{resource.name} - #{Enum.join(gateway_group_names, ",")}",
      value: resource.id
    ]
  end

  def handle_event("validate", %{"policy" => params}, socket) do
    form =
      params
      |> put_default_params(socket)
      |> map_condition_params(empty_values: :keep)
      |> Policies.new_policy(socket.assigns.subject)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params =
      params
      |> put_default_params(socket)
      |> map_condition_params(empty_values: :drop)

    params =
      if Domain.Accounts.policy_conditions_enabled?(socket.assigns.account) do
        params
      else
        Map.delete(params, "conditions")
      end

    with {:ok, _policy} <- Policies.create_policy(params, socket.assigns.subject) do
      cond do
        site_id = socket.assigns.params["site_id"] ->
          # Created from Add Resource from Site
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}?#resources")}

        resource_id = socket.assigns.resource_id ->
          # Created from Add Resource from Resources
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources/#{resource_id}")}

        actor_group_id = socket.assigns.actor_group_id ->
          # Created from Add Policy from Actor Group
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups/#{actor_group_id}")}

        true ->
          # Created from Add Policy from Policies
          {:noreply,
           socket
           |> put_flash(:info, "Policy created successfully.")
           |> push_navigate(to: ~p"/#{socket.assigns.account}/policies")}
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  defp put_default_params(attrs, socket) do
    if resource_id = socket.assigns.resource_id do
      Map.put(attrs, "resource_id", resource_id)
    else
      attrs
    end
  end
end
