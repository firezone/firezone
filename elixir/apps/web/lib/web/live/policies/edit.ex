defmodule Web.Policies.Edit do
  use Web, :live_view

  alias Domain.Policies

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <- Policies.fetch_policy_by_id(id, socket.assigns.subject) do
      {:ok,
       assign(socket,
         policy: policy,
         form: to_form(Policies.Policy.Changeset.update_changeset(policy, %{}))
       )}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <%= @policy.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Edit Policy <code><%= @policy.name %></code>
      </:title>
    </.header>
    <!-- Edit Policy -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit Policy details</h2>
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
          <:actions>
            <.button phx-disable-with="Updating Policy..." class="w-full">
              Update Policy
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </section>
    """
  end

  def handle_event("validate", %{"policy" => policy_params}, socket) do
    changeset =
      Policies.Policy.Changeset.update_changeset(socket.assigns.policy, policy_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"policy" => policy_params}, socket) do
    with {:ok, policy} <-
           Policies.update_policy(socket.assigns.policy, policy_params, socket.assigns.subject) do
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/policies/#{policy}")}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
