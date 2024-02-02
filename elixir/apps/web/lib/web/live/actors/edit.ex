defmodule Web.Actors.Edit do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: [:memberships]),
         nil <- actor.deleted_at,
         {:ok, groups} <- Actors.list_groups(socket.assigns.subject, preload: [:provider]) do
      changeset = Actors.change_actor(actor)

      groups = Enum.reject(groups, &Actors.group_synced?/1)

      socket =
        assign(socket,
          actor: actor,
          groups: groups,
          form: to_form(changeset),
          page_title: "Edit #{actor.name}"
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Edit <%= actor_type(@actor.type) %>: <code><%= @actor.name %></code>
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Edit User Details</h2>
          <.flash kind={:error} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.actor_form
                form={@form}
                type={@actor.type}
                actor={@actor}
                groups={@groups}
                subject={@subject}
              />
            </div>
            <.submit_button>Save</.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    attrs = map_actor_form_memberships_attr(attrs)

    changeset =
      Actors.change_actor(socket.assigns.actor, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs = map_actor_form_memberships_attr(attrs)

    with {:ok, actor} <- Actors.update_actor(socket.assigns.actor, attrs, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/actors/#{actor}")
      {:noreply, socket}
    else
      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permissions to perform this action.")}

      {:error, :cant_remove_admin_type} ->
        {:noreply, put_flash(socket, :error, "You may not demote the last admin.")}

      {:error, {:unauthorized, _context}} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permissions to perform this action.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
