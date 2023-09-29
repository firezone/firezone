defmodule Web.Groups.Show do
  use Web, :live_view
  import Web.Groups.Components
  import Web.Actors.Components
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Actors.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               provider: [],
               actors: [identities: [:provider]],
               created_by_identity: [:actor]
             ]
           ) do
      {:ok, assign(socket, group: group)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _group} = Actors.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/groups")}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing Group <code><%= @group.name %></code>
      </:title>
      <:actions>
        <.edit_button
          :if={not Actors.group_synced?(@group)}
          navigate={~p"/#{@account}/groups/#{@group}/edit"}
        >
          Edit Group
        </.edit_button>
      </:actions>
    </.header>
    <!-- Group Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="group">
        <.vertical_table_row>
          <:label>Name</:label>
          <:value><%= @group.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Source</:label>
          <:value>
            <.source account={@account} group={@group} />
          </:value>
        </.vertical_table_row>
      </.vertical_table>
      <!-- Actors Table -->
      <.header>
        <:title>
          Actors
        </:title>
        <:actions>
          <.edit_button
            :if={not Actors.group_synced?(@group)}
            navigate={~p"/#{@account}/groups/#{@group}/edit_actors"}
          >
            Edit Actors
          </.edit_button>
        </:actions>
      </.header>
      <div class="relative overflow-x-auto">
        <.table id="actors" rows={@group.actors}>
          <:col :let={actor} label="ACTOR">
            <.actor_name_and_role account={@account} actor={actor} />
          </:col>
          <:col :let={actor} label="IDENTITIES">
            <.identity_identifier
              :for={identity <- actor.identities}
              account={@account}
              identity={identity}
            />
          </:col>
        </.table>
      </div>
    </div>

    <.header :if={is_nil(@group.provider_id)}>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this group and all related policies?"
        >
          Delete Group
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
