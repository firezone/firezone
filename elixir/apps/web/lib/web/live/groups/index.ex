defmodule Web.Groups.Index do
  use Web, :live_view
  import Web.Groups.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    with {:ok, groups} <-
           Actors.list_groups(socket.assigns.subject,
             preload: [:provider, created_by_identity: [:actor]]
           ) do
      {:ok, assign(socket, groups: groups)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
    </.breadcrumbs>

    <.header>
      <:title>
        All groups
      </:title>
      <:actions>
        <.add_button navigate={~p"/#{@account}/groups/new"}>
          Add a new group
        </.add_button>
      </:actions>
    </.header>
    <!-- Groups Table -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <!--<.resource_filter />-->
      <.table id="groups" rows={@groups} row_id={&"user-#{&1.id}"}>
        <:col :let={group} label="NAME" sortable="false">
          <.link
            :if={not Actors.group_synced?(group)}
            navigate={~p"/#{@account}/groups/#{group.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= group.name %>
          </.link>
          <span :if={Actors.group_synced?(group)}>
            <%= group.name %>
          </span>
          <span :if={Actors.group_deleted?(group.deleted_at)} class="text-xs text-gray-100">
            (deleted)
          </span>
        </:col>
        <:col :let={group} label="SOURCE" sortable="false">
          <.source group={group} />
        </:col>
      </.table>
      <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/groups"} />-->
    </div>
    """
  end
end
