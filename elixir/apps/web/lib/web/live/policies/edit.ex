defmodule Web.Policies.Edit do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Resources, Actors, Policies, Auth}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource],
             filter: [deleted?: false]
           ) do
      # TODO: unify this dropdown and the one we use for live table filters
      resources = Resources.all_resources!(socket.assigns.subject, preload: [:gateway_groups])
      # TODO: unify this dropdown and the one we use for live table filters
      actor_groups = Actors.all_groups!(socket.assigns.subject, preload: :provider)
      providers = Auth.all_active_providers_for_account!(socket.assigns.account)

      form =
        policy
        |> Policies.change_policy(%{}, socket.assigns.subject)
        |> to_form()

      socket =
        assign(socket,
          page_title: "Edit Policy #{policy.id}",
          timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
          policy: policy,
          form: form,
          resources: resources,
          actor_groups: actor_groups,
          providers: providers
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <.policy_name policy={@policy} />
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= @page_title %></:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Edit Policy details</h2>
          <.form for={@form} class="space-y-4 lg:space-y-6" phx-submit="submit" phx-change="validate">
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset class="flex flex-col gap-2">
                <.input
                  field={@form[:actor_group_id]}
                  label="Group"
                  type="group_select"
                  options={Web.Groups.Components.select_options(@actor_groups)}
                  value={@form[:actor_group_id].value}
                  required
                />

                <% resource_id =
                  @form[:resource_id].value ||
                    (length(@resources) > 0 and Enum.at(@resources, 0).id) %>

                <.input
                  field={@form[:resource_id]}
                  label="Resource"
                  type="group_select"
                  options={resource_options(@resources, @account)}
                  value={resource_id}
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

            <.submit_button phx-disable-with="Updating Policy...">
              Save
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("validate", %{"policy" => params}, socket) do
    params = map_condition_params(params, empty_values: :drop)

    changeset =
      Policies.change_policy(socket.assigns.policy, params, socket.assigns.subject)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params = map_condition_params(params, empty_values: :drop)

    params =
      if Domain.Accounts.policy_conditions_enabled?(socket.assigns.account) do
        params
      else
        Map.delete(params, "conditions")
      end

    case Policies.update_or_replace_policy(socket.assigns.policy, params, socket.assigns.subject) do
      {:updated, updated_policy} ->
        {:noreply,
         push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies/#{updated_policy}")}

      {:replaced, _replaced_policy, created_policy} ->
        {:noreply,
         push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies/#{created_policy}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
