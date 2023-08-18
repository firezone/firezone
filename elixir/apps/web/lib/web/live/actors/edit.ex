defmodule Web.Actors.Edit do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: [:memberships]),
         {:ok, groups} <- Actors.list_groups(socket.assigns.subject) do
      changeset = Actors.change_actor(actor)
      {:ok, assign(socket, actor: actor, groups: groups, form: to_form(changeset))}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    attrs = map_memberships_attr(attrs)

    changeset =
      Actors.change_actor(socket.assigns.actor, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs = map_memberships_attr(attrs)

    with {:ok, actor} <-
           Actors.update_actor(socket.assigns.actor, attrs, socket.assigns.subject) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/actors/#{actor}")
      {:noreply, socket}
    else
      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permissions to perform this action.")}

      {:error, {:unauthorized, _context}} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permissions to perform this action.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp map_memberships_attr(attrs) do
    Map.update(attrs, "memberships", [], fn group_ids ->
      Enum.map(group_ids, fn group_id ->
        %{group_id: group_id}
      end)
    end)
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}"}>
        <%= @actor.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing <%= account_type_to_string(@actor.type) %>: <code><%= @actor.name %></code>
      </:title>
    </.header>
    <!-- Update User -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit User Details</h2>
        <.flash kind={:error} flash={@flash} />
        <.actor_form
          subject={@subject}
          form={@form}
          type={@actor.type}
          actor={@actor}
          groups={@groups}
        />
      </div>
    </section>
    """
  end

  attr :type, :atom, required: true
  attr :subject, :any, required: true
  attr :actor, :any, default: %{memberships: []}, required: false
  attr :groups, :any, required: true
  attr :form, :any, required: true

  defp actor_form(%{type: type} = assigns) when type in [:account_admin_user, :account_user] do
    ~H"""
    <.form for={@form} phx-change={:change} phx-submit={:submit}>
      <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
        <div>
          <.input label="Name" field={@form[:name]} placeholder="Full Name" required />
        </div>
        <div :if={Domain.Auth.has_permission?(@subject, Actors.Authorizer.manage_actors_permission())}>
          <.input
            type="select"
            label="Role"
            field={@form[:type]}
            options={[
              {"User", :account_user},
              {"Admin", :account_admin_user}
            ]}
            placeholder="Role"
            required
          />
        </div>
        <div>
          <.input
            type="select"
            multiple={true}
            label="Groups"
            field={@form[:memberships]}
            value={Enum.map(@actor.memberships, fn membership -> membership.group_id end)}
            options={Enum.map(@groups, fn group -> {group.name, group.id} end)}
            placeholder="Groups"
          />
          <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
            Hold <kbd>Ctrl</kbd> (or <kbd>Command</kbd> on Mac) to select or unselect multiple groups.
          </p>
        </div>
      </div>
      <.submit_button>
        Save
      </.submit_button>
    </.form>
    """
  end

  defp actor_form(%{type: type} = assigns) when type in [:service_account] do
    ~H"""
    <.form for={@form} phx-change={:change} phx-submit={:submit}>
      <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
        <div>
          <.input label="Name" field={@form[:name]} placeholder="Full Name" required />
        </div>
      </div>
      <div>
        <.input
          type="select"
          multiple={true}
          label="Groups"
          field={@form[:memberships]}
          value={Enum.map(@actor.memberships, fn membership -> membership.group_id end)}
          options={Enum.map(@groups, fn group -> {group.name, group.id} end)}
          placeholder="Groups"
        />
      </div>
      <.submit_button>
        Save
      </.submit_button>
    </.form>
    """
  end
end
