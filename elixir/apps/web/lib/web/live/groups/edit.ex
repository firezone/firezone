defmodule Web.Groups.Edit do
  use Web, :live_view
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Actors.fetch_group_by_id(id, socket.assigns.subject, preload: [:memberships]),
         nil <- group.deleted_at,
         false <- Actors.group_synced?(group) do
      changeset = Actors.change_group(group)
      {:ok, assign(socket, group: group, form: to_form(changeset))}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Group: <code><%= @group.name %></code>
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">Edit group details</h2>
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input label="Name" field={@form[:name]} placeholder="Full Name" required />
              </div>
            </div>
            <.submit_button>
              Save
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Actors.change_group(socket.assigns.group, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    with {:ok, group} <-
           Actors.update_group(socket.assigns.group, attrs, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups/#{group}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
