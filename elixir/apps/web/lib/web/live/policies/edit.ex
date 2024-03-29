defmodule Web.Policies.Edit do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.Policies

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id(id, socket.assigns.subject,
             preload: [:actor_group, :resource],
             filter: [deleted?: false]
           ) do
      form = to_form(Policies.Policy.Changeset.update(policy, %{}))

      socket =
        assign(socket,
          page_title: "Edit Policy #{policy.id}",
          policy: policy,
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
              <.input
                field={@form[:description]}
                type="textarea"
                label="Policy Description"
                placeholder="Enter a policy description here"
                phx-debounce="300"
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
    changeset =
      Policies.Policy.Changeset.update(socket.assigns.policy, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    with {:ok, policy} <-
           Policies.update_policy(socket.assigns.policy, params, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies/#{policy}")}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
