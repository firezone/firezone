defmodule Web.Actors.Show do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Auth
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [
               identities: [:provider, created_by_identity: [:actor]],
               groups: []
             ]
           ) do
      {:ok, assign(socket, actor: actor)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("delete", _params, socket) do
    with {:ok, _group} <- Actors.delete_actor(socket.assigns.actor, socket.assigns.subject) do
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/actors")}
    else
      {:error, :cant_delete_the_last_admin} ->
        {:noreply, put_flash(socket, :error, "You can't delete the last admin of an account.")}
    end
  end

  def handle_event("delete_identity", %{"id" => id}, socket) do
    {:ok, identity} = Auth.fetch_identity_by_id(id, socket.assigns.subject)
    {:ok, _identity} = Auth.delete_identity(identity, socket.assigns.subject)

    {:ok, actor} =
      Actors.fetch_actor_by_id(socket.assigns.actor.id, socket.assigns.subject,
        preload: [
          identities: [:provider, created_by_identity: [:actor]],
          groups: []
        ]
      )

    {:noreply, assign(socket, actor: actor)}
  end

  defp last_seen_at(identities) do
    identities
    |> Enum.reject(&is_nil(&1.last_seen_at))
    |> Enum.max_by(& &1.last_seen_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      identity -> identity.last_seen_at
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}"}>
        <%= @actor.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing <%= account_type_to_string(@actor.type) %>: <code><%= @actor.name %></code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/actors/#{@actor}/edit"}>
          Edit <%= account_type_to_string(@actor.type) %>
        </.edit_button>
      </:actions>
    </.header>
    <!-- User Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden lg:w-3/4 mb-4">
      <.flash kind={:error} flash={@flash} />

      <h5 class="bg-slate-200 p-4 text-2xl font-bold text-gray-900 dark:text-white">User Info</h5>

      <.vertical_table>
        <.vertical_table_row label_class="w-1/5">
          <:label>Name</:label>
          <:value><%= @actor.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Role</:label>
          <:value>
            <%= account_type_to_string(@actor.type) %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Groups</:label>
          <:value>
            <span :for={group <- @actor.groups}>
              <.link navigate={~p"/#{@account}/groups/#{group.id}"}>
                <.badge>
                  <%= group.name %>
                </.badge>
              </.link>
            </span>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Signed In</:label>
          <:value><.relative_datetime datetime={last_seen_at(@actor.identities)} /></:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    <div class="bg-white dark:bg-gray-800 overflow-hidden lg:w-3/4">
      <h5 class="p-4 text-2xl font-bold bg-slate-200 text-gray-900 dark:text-white flex justify-between items-center">
        Authentication Identities
        <div class="inline-flex justify-between items-center space-x-2">
          <.add_button
            :if={@actor.type == :service_account}
            navigate={~p"/#{@account}/actors/#{@actor}/new_token"}
          >
            Create new token
          </.add_button>
          <.add_button
            :if={@actor.type != :service_account}
            navigate={~p"/#{@account}/actors/#{@actor}/new_identity"}
          >
            Create new identity
          </.add_button>
        </div>
      </h5>

      <.table id="actors" rows={@actor.identities} row_id={&"identity-#{&1.id}"}>
        <:col :let={identity} label="IDENTITY" sortable="false">
          <.identity_identifier identity={identity} />
        </:col>

        <:col :let={identity} label="CREATED" sortable="false">
          <.datetime datetime={identity.inserted_at} /> by <.owner schema={identity} />
        </:col>
        <:col :let={identity} label="LAST SIGNED IN" sortable="false">
          <.relative_datetime datetime={identity.last_seen_at} />
        </:col>
        <:action :let={identity}>
          <button
            phx-click="delete_identity"
            phx-value-id={identity.id}
            class="block w-full py-2 px-4 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Delete
          </button>
        </:action>
      </.table>
    </div>
    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this actor and all it's identities?"
        >
          Delete user
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
