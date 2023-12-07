defmodule Web.Policies.Edit do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.Policies

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource]
           ),
         nil <- policy.deleted_at do
      form = to_form(Policies.Policy.Changeset.update(policy, %{}))
      socket = assign(socket, policy: policy, page_title: "Edit Policy", form: form)
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
        <%= @page_title %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= "#{@page_title}: #{@policy.id}" %></:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">Edit Policy details</h2>
          <.simple_form
            for={@form}
            class="space-y-4 lg:space-y-6"
            phx-submit="submit"
            phx-change="validate"
          >
            <.input
              field={@form[:description]}
              type="textarea"
              label="Policy Description"
              placeholder="Enter a policy description here"
              phx-debounce="300"
            />
            <:actions>
              <.button phx-disable-with="Updating Policy..." class="w-full">
                Update Policy
              </.button>
            </:actions>
          </.simple_form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("validate", %{"policy" => policy_params}, socket) do
    changeset =
      Policies.Policy.Changeset.update(socket.assigns.policy, policy_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"policy" => policy_params}, socket) do
    with {:ok, policy} <-
           Policies.update_policy(socket.assigns.policy, policy_params, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies/#{policy}")}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
