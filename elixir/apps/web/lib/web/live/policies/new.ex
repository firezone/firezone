defmodule Web.Policies.New do
  use Web, :live_view

  alias Domain.{Resources, Actors, Policies}

  def mount(_params, _session, socket) do
    with {:ok, resources} <- Resources.list_resources(socket.assigns.subject),
         {:ok, actor_groups} <- Actors.list_groups(socket.assigns.subject) do
      form = to_form(Policies.Policy.Changeset.create_changeset(%{}, socket.assigns.subject))

      socket =
        assign(socket,
          resources: resources,
          actor_groups: actor_groups,
          form: form
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/new"}>Add Policy</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Add a new Policy
      </:title>
    </.header>
    <!-- Add Policy -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Policy details</h2>
        <.simple_form
          for={@form}
          class="space-y-4 lg:space-y-6"
          phx-submit="submit"
          phx-change="validate"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Policy Name"
            placeholder="Enter a Policy Name here"
            required
            phx-debounce="300"
          />
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
            options={Enum.map(@resources, fn r -> [key: r.name, value: r.id] end)}
            value={@form[:resource_id].value}
            required
          />
          <.base_error form={@form} field={:base} />
          <:actions>
            <.button phx-disable-with="Creating Policy..." class="w-full">
              Create Policy
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </section>
    """
  end

  def handle_event("validate", %{"policy" => policy_params}, socket) do
    form =
      Policies.Policy.Changeset.create_changeset(policy_params, socket.assigns.subject)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"policy" => policy_params}, socket) do
    with {:ok, policy} <- Policies.create_policy(policy_params, socket.assigns.subject) do
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/policies/#{policy}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        IO.inspect(changeset)
        form = to_form(changeset)
        {:noreply, assign(socket, form: form)}
    end
  end
end
