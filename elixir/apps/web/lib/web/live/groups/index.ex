defmodule Web.Groups.Index do
  use Web, :live_view
  import Web.Groups.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    with {:ok, groups} <-
           Actors.list_groups(socket.assigns.subject,
             preload: [:provider, created_by_identity: [:actor]]
           ),
         {:ok, group_actors} <- Actors.peek_group_actors(groups, 3, socket.assigns.subject) do
      {:ok, socket,
       temporary_assigns: [
         page_title: "Groups",
         groups: groups,
         group_actors: group_actors
       ]}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}><%= @page_title %></.breadcrumb>
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
      <div :if={Enum.empty?(@groups)} class="text-center align-middle pb-8 pt-4">
        <h3 class="mt-2 text-lg font-semibold text-gray-900">There are no groups to display.</h3>

        <div class="mt-6">
          <.add_button navigate={~p"/#{@account}/groups/new"} class="inline-flex items-center">
            Add a new group
          </.add_button>
          <span class="font-semibold px-2 mb-4">or</span>
          <.add_button
            navigate={~p"/#{@account}/settings/identity_providers"}
            class="inline-flex items-center"
          >
            Sync groups from an IdP
          </.add_button>
        </div>
      </div>
      <!--<.resource_filter />-->
      <.table :if={not Enum.empty?(@groups)} id="groups" rows={@groups} row_id={&"user-#{&1.id}"}>
        <:col :let={group} label="NAME" sortable="false">
          <.link
            navigate={~p"/#{@account}/groups/#{group.id}"}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
            <%= group.name %>
          </.link>

          <span :if={Actors.group_deleted?(group)} class="text-xs text-gray-100">
            (deleted)
          </span>
        </:col>
        <:col :let={group} label="ACTORS" sortable="false">
          <.peek peek={Map.fetch!(@group_actors, group.id)}>
            <:empty>
              None
            </:empty>

            <:separator>
              <span class="pr-1">,</span>
            </:separator>

            <:item :let={actor}>
              <.link
                navigate={~p"/#{@account}/actors/#{actor}"}
                class={["font-medium text-blue-600 dark:text-blue-500 hover:underline"]}
              >
                <%= actor.name %>
              </.link>
            </:item>

            <:tail :let={count}>
              <span class="pl-1">
                and <%= count %> more.
              </span>
            </:tail>
          </.peek>
        </:col>
        <:col :let={group} label="SOURCE" sortable="false">
          <.source account={@account} group={group} />
        </:col>
      </.table>
      <!--<.paginator page={3} total_pages={100} collection_base_path={~p"/#{@account}/groups"} />-->
    </div>
    """
  end
end
