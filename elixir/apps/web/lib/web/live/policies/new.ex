defmodule Web.Policies.New do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Policies, Auth}

  def mount(params, _session, socket) do
    providers = Auth.all_active_providers_for_account!(socket.assigns.account)

    form =
      Policies.new_policy(%{}, socket.assigns.subject)
      |> to_form()

    socket =
      assign(socket,
        page_title: "New Policy",
        timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
        providers: providers,
        params: Map.take(params, ["site_id"]),
        selected_resource: nil,
        enforced_resource_id: params["resource_id"],
        enforced_actor_group_id: params["actor_group_id"],
        form: form
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/new"}>Add Policy</.breadcrumb>
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
                  value={@enforced_actor_group_id || @form[:actor_group_id].value}
                  disabled={not is_nil(@enforced_actor_group_id)}
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
                  value={@enforced_resource_id || @form[:resource_id].value}
                  disabled={not is_nil(@enforced_resource_id)}
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

                      <span
                        :if={length(resource.gateway_groups) > 0}
                        class="text-neutral-500 inline-flex"
                      >
                        (<.resource_gateway_groups gateway_groups={resource.gateway_groups} />)
                      </span>
                    <% end %>

                    <span :if={resource.gateway_groups == []} class="text-red-800">
                      (not connected to any Site)
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

  def on_resource_change({_id, _name, resource}) do
    send(self(), {:change_resource, resource})
  end

  def handle_info({:change_resource, resource}, socket) do
    {:noreply, assign(socket, selected_resource: resource)}
  end

  def handle_event("validate", %{"policy" => params}, socket) do
    form =
      params
      |> maybe_enforce_resource_id(socket)
      |> maybe_enforce_actor_group_id(socket)
      |> map_condition_params(empty_values: :keep)
      |> maybe_drop_unsupported_conditions(socket)
      |> Policies.new_policy(socket.assigns.subject)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params =
      params
      |> maybe_enforce_resource_id(socket)
      |> maybe_enforce_actor_group_id(socket)
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    with {:ok, _policy} <- Policies.create_policy(params, socket.assigns.subject) do
      cond do
        site_id = socket.assigns.params["site_id"] ->
          # Created from Add Resource from Site
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}?#resources")}

        resource_id = socket.assigns.enforced_resource_id ->
          # Created from Add Resource from Resources
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources/#{resource_id}")}

        actor_group_id = socket.assigns.enforced_actor_group_id ->
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

  defp maybe_enforce_resource_id(attrs, socket) do
    if resource_id = socket.assigns.enforced_resource_id do
      Map.put(attrs, "resource_id", resource_id)
    else
      attrs
    end
  end

  defp maybe_enforce_actor_group_id(attrs, socket) do
    if actor_group_id = socket.assigns.enforced_actor_group_id do
      Map.put(attrs, "actor_group_id", actor_group_id)
    else
      attrs
    end
  end
end
