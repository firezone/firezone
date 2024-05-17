defmodule Web.Policies.New do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Resources, Actors, Policies, Auth}

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
      <:title>
        Add Policy
      </:title>
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

                <.input
                  field={@form[:resource_id]}
                  label="Resource"
                  type="select"
                  options={
                    Enum.map(@resources, fn resource ->
                      group_names = resource.gateway_groups |> Enum.map(& &1.name)

                      [
                        key: "#{resource.name} - #{Enum.join(group_names, ",")}",
                        value: resource.id
                      ]
                    end)
                  }
                  value={@resource_id || @form[:resource_id].value}
                  disabled={not is_nil(@resource_id)}
                  required
                />
              </fieldset>

              <fieldset class="flex flex-col gap-2">
                <div class="mb-1 flex items-center justify-between">
                  <legend>Constraints</legend>
                </div>

                <p class="text-sm text-neutral-500">
                  Restrict access to the Resource based on Client IP address, location region, or other.
                </p>

                <.inputs_for :let={constraint} field={@form[:constraints]}>
                  <input type="hidden" name="policy[constraints_order][]" value={constraint.index} />

                  <div class="flex flex-initial space-x-2">
                    <.constraint_form providers={@providers} constraint={constraint} />

                    <div class="block mt-2 ml-2">
                      <label class="cursor-pointer">
                        <input
                          type="checkbox"
                          name="policy[constraints_delete][]"
                          value={constraint.index}
                          class="hidden"
                        /> <.icon name="hero-x-mark" />
                      </label>
                    </div>
                  </div>
                </.inputs_for>

                <div>
                  <label class={[
                    button_style("info"),
                    button_size("md"),
                    "w-1/4",
                    "cursor-pointer"
                  ]}>
                    <input type="checkbox" name="policy[constraints_order][]" class="hidden" />
                    <.icon name="hero-plus" class={icon_size("md")} /> Add Constraint
                  </label>
                </div>
              </fieldset>

              <.input
                field={@form[:description]}
                type="textarea"
                label="Description"
                placeholder="Optionally, enter a reason for creating a policy here."
                phx-debounce="300"
              />
            </div>

            <.submit_button phx-disable-with="Creating Policy..." class="w-full">
              Create Policy
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("validate", %{"_target" => target, "policy" => params}, socket) do
    form =
      params
      |> put_default_params(socket)
      |> map_constraint_params()
      |> Policies.new_policy(socket.assigns.subject)
      |> to_form(form_opts(target))

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params =
      params
      |> put_default_params(socket)
      |> map_constraint_params()

    with {:ok, policy} <- Policies.create_policy(params, socket.assigns.subject) do
      if site_id = socket.assigns.params["site_id"] do
        {:noreply,
         push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}?#resources")}
      else
        {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies/#{policy}")}
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :save))}
    end
  end

  defp form_opts(["policy", "constraints_order"]), do: []
  defp form_opts(_), do: [action: :validate]

  defp put_default_params(attrs, socket) do
    if resource_id = socket.assigns.resource_id do
      Map.put(attrs, "resource_id", resource_id)
    else
      attrs
    end
  end

  defp map_constraint_params(attrs) do
    Map.update(attrs, "constraints", nil, fn constraints ->
      for {index, constraint_attrs} <- constraints, into: %{} do
        {index, map_constraint_values(constraint_attrs)}
      end
    end)
  end

  defp map_constraint_values(%{"operator" => "is_in_day_of_week_time_ranges"} = constraint_attrs) do
    Map.update(constraint_attrs, "values", [], fn values ->
      Enum.map(values, fn {dow, time_ranges} ->
        "#{dow}/#{time_ranges}"
      end)
    end)
  end

  defp map_constraint_values(constraint_attrs) do
    Map.update(constraint_attrs, "values", [], fn
      values when is_list(values) ->
        values

      values when is_map(values) ->
        values |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

      values ->
        String.split(values, ",")
    end)
  end
end
