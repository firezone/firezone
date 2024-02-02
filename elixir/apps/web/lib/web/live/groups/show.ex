defmodule Web.Groups.Show do
  use Web, :live_view
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
      socket = assign(socket, group: group, page_title: "Group #{group.name}")
      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Group: <code><%= @group.name %></code>
        <span :if={not is_nil(@group.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@group.deleted_at)}>
        <.edit_button
          :if={Actors.group_editable?(@group)}
          navigate={~p"/#{@account}/groups/#{@group}/edit"}
        >
          Edit Group
        </.edit_button>
      </:action>
      <:content>
        <.flash :if={Actors.group_managed?(@group)} kind={:info}>
          This group is managed by Firezone and cannot be edited.
        </.flash>
        <.flash :if={Actors.group_synced?(@group)} kind={:info}>
          This group is synced from an external source and cannot be edited.
        </.flash>

        <.vertical_table id="group">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @group.name %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value><.created_by account={@account} schema={@group} /></:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Actors</:title>
      <:action :if={is_nil(@group.deleted_at)}>
        <.edit_button
          :if={not Actors.group_synced?(@group) and not Actors.group_managed?(@group)}
          navigate={~p"/#{@account}/groups/#{@group}/edit_actors"}
        >
          Edit Actors
        </.edit_button>
      </:action>
      <:content>
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
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div :if={not Actors.group_synced?(@group)} class="w-auto">
                <div class="pb-4">
                  There are no actors in this group.
                </div>
                <.edit_button
                  :if={not Actors.group_synced?(@group) and not Actors.group_managed?(@group)}
                  navigate={~p"/#{@account}/groups/#{@group}/edit_actors"}
                >
                  Edit Actors
                </.edit_button>
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@group.deleted_at) and Actors.group_editable?(@group)}>
      <:action>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this group and all related policies?"
        >
          Delete Group
        </.delete_button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_event("delete", _params, socket) do
    {:ok, _group} = Actors.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups")}
  end
end
