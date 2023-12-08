defmodule Web.Policies.New do
  use Web, :live_view
  alias Domain.{Resources, Actors, Policies}

  def mount(params, _session, socket) do
    with {:ok, resources} <-
           Resources.list_resources(socket.assigns.subject, preload: [:gateway_groups]),
         {:ok, actor_groups} <- Actors.list_groups(socket.assigns.subject) do
      form = to_form(Policies.new_policy(%{}, socket.assigns.subject))

      socket =
        assign(socket,
          resources: resources,
          actor_groups: actor_groups,
          params: Map.take(params, ["site_id"]),
          resource_id: params["resource_id"],
          page_title: "Add Policy",
          form: form
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
      <.breadcrumb path={~p"/#{@account}/policies/new"}><%= @page_title %></.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        <%= @page_title %>
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">Policy details</h2>
          <.simple_form for={@form} phx-submit="submit" phx-change="validate">
            <.base_error form={@form} field={:base} />
            <.input
              field={@form[:actor_group_id]}
              label="Group"
              type="select"
              options={Enum.map(@actor_groups, fn g -> [key: g.name, value: g.id] end)}
              value={@form[:actor_group_id].value}
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
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
              placeholder="Enter a reason for creating a policy here"
              phx-debounce="300"
            />
            <:actions>
              <.button phx-disable-with="Creating Policy..." class="w-full">
                Create Policy
              </.button>
            </:actions>
          </.simple_form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("validate", %{"policy" => policy_params}, socket) do
    form =
      policy_params
      |> put_default_policy_params(socket)
      |> Policies.new_policy(socket.assigns.subject)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"policy" => policy_params}, socket) do
    policy_params = put_default_policy_params(policy_params, socket)

    with {:ok, policy} <- Policies.create_policy(policy_params, socket.assigns.subject) do
      if site_id = socket.assigns.params["site_id"] do
        {:noreply,
         push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}?#resources")}
      else
        {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies/#{policy}")}
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        form = to_form(changeset)
        {:noreply, assign(socket, form: form)}
    end
  end

  defp put_default_policy_params(attrs, socket) do
    if resource_id = socket.assigns.resource_id do
      Map.put(attrs, "resource_id", resource_id)
    else
      attrs
    end
  end
end
