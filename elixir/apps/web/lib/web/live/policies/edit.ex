defmodule Web.Policies.Edit do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Policies, Auth}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id_or_persistent_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource],
             filter: [deleted?: false]
           ) do
      providers = Auth.all_active_providers_for_account!(socket.assigns.account)

      form =
        policy
        |> Policies.change_policy(%{}, socket.assigns.subject)
        |> to_form()

      socket =
        assign(socket,
          page_title: "Edit Policy #{policy.id}",
          timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
          providers: providers,
          policy: policy,
          selected_resource: policy.resource,
          form: form
        )

      {:ok, socket}
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
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <legend class="mb-4 text-xl text-neutral-900">Details</legend>

          <.form for={@form} phx-submit="submit" phx-change="validate">
            <.base_error form={@form} field={:base} />

            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset class="flex flex-col gap-2">
                <.live_component
                  module={Web.Components.FormComponents.SelectWithGroups}
                  id="policy_actor_group_id"
                  label="Group"
                  placeholder="Select Actor Group"
                  field={@form[:actor_group_id]}
                  fetch_option_callback={&Web.Groups.Components.fetch_group_option(&1, @subject)}
                  list_options_callback={&Web.Groups.Components.list_group_options(&1, @subject)}
                  value={@form[:actor_group_id].value}
                  required
                >
                  <:options_group :let={options_group}>
                    {options_group}
                  </:options_group>

                  <:option :let={group}>
                    {group.name}
                  </:option>

                  <:no_options :let={name}>
                    <.error data-validation-error-for={name}>
                      <span>
                        You have no groups to create policies for. You can create a group <.link
                          navigate={~p"/#{@account}/groups/new"}
                          class={[link_style()]}
                        >here</.link>.
                      </span>
                    </.error>
                  </:no_options>

                  <:no_search_results>
                    No groups found. Try a different search query or create a new one <.link
                      navigate={~p"/#{@account}/groups/new"}
                      class={link_style()}
                    >here</.link>.
                  </:no_search_results>
                </.live_component>

                <.live_component
                  module={Web.Components.FormComponents.SelectWithGroups}
                  id="policy_resource_id"
                  label="Resource"
                  placeholder="Select Resource"
                  field={@form[:resource_id]}
                  fetch_option_callback={
                    &Web.Resources.Components.fetch_resource_option(&1, @subject)
                  }
                  list_options_callback={
                    &Web.Resources.Components.list_resource_options(&1, @subject)
                  }
                  on_change={&on_resource_change/1}
                  value={@form[:resource_id].value}
                  required
                >
                  <:options_group :let={group}>
                    {group}
                  </:options_group>

                  <:option :let={resource}>
                    <%= if resource.type == :internet do %>
                      Internet
                      <span :if={not Domain.Accounts.internet_resource_enabled?(@account)}>
                        - <span class="text-red-800">upgrade to unlock</span>
                      </span>
                    <% else %>
                      {resource.name}
                    <% end %>

                    <span :if={resource.gateway_groups == []} class="text-red-800">
                      (not connected to any Site)
                    </span>
                    <span
                      :if={length(resource.gateway_groups) > 0}
                      class="text-neutral-500 inline-flex"
                    >
                      (<.resource_gateway_groups gateway_groups={resource.gateway_groups} />)
                    </span>
                  </:option>

                  <:no_options :let={name}>
                    <.error data-validation-error-for={name}>
                      <span>
                        You have no resources to create policies for. You can create a resource <.link
                          navigate={~p"/#{@account}/resources/new"}
                          class={[link_style()]}
                        >here</.link>.
                      </span>
                    </.error>
                  </:no_options>

                  <:no_search_results>
                    No Resources found. Try a different search query or create a new one <.link
                      navigate={~p"/#{@account}/resources/new"}
                      class={link_style()}
                    >here</.link>.
                  </:no_search_results>
                </.live_component>

                <.input
                  field={@form[:description]}
                  label="Description"
                  type="textarea"
                  placeholder="Enter an optional reason for creating this policy here."
                  phx-debounce="300"
                />
              </fieldset>

              <.conditions_form
                :if={not is_nil(@selected_resource)}
                form={@form}
                account={@account}
                timezone={@timezone}
                providers={@providers}
                selected_resource={@selected_resource}
              />

              <.options_form
                :if={not is_nil(@selected_resource)}
                form={@form}
                account={@account}
                selected_resource={@selected_resource}
              />
            </div>

            <div class="flex justify-end">
              <.submit_button phx-disable-with="Updating Policy...">
                Save
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def on_resource_change({_id, _name, resource}) do
    send(self(), {:change_resource, resource})
  end

  def handle_info({:change_resource, resource}, socket) do
    {:noreply, assign(socket, selected_resource: resource)}
  end

  def handle_event("validate", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    changeset =
      Policies.change_policy(socket.assigns.policy, params, socket.assigns.subject)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

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
