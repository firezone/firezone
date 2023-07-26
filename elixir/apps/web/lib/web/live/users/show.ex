defmodule Web.Users.Show do
  use Web, :live_view

  alias Domain.Actors

  def mount(%{"id" => id} = _params, _session, socket) do
    {:ok, actor} =
      Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: [identities: [:provider]])

    {:ok, assign(socket, actor: actor)}
  end

  defp account_type_to_string(type) do
    case type do
      :account_admin_user -> "Admin"
      :account_user -> "User"
      :service_account -> "Service Account"
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Users</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}"}>
        <%= @actor.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing User: <code><%= @actor.name %></code>
      </:title>
      <:actions>
        <.edit_button navigate={~p"/#{@account}/actors/#{@actor.id}/edit"}>
          Edit user
        </.edit_button>
      </:actions>
    </.header>
    <!-- User Details -->
    <div class="bg-white dark:bg-gray-800 overflow-hidden lg:w-3/4 mb-4">
      <h5 class="bg-slate-200 p-4 text-2xl font-bold text-gray-900 dark:text-white">User Info</h5>
      <.vertical_table>
        <.vertical_table_row label_width="w-1/5">
          <:label>Name</:label>
          <:value><%= @actor.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Source</:label>
          <:value>TODO: Manually created by Jamil Bou Kheir on May 3rd, 2023.</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Role</:label>
          <:value>
            <%= account_type_to_string(@actor.type) %>
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Groups</:label>
          <:value>TODO: Groups Here</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Active</:label>
          <:value>TODO: Last Active Here</:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    <div class="bg-white dark:bg-gray-800 overflow-hidden lg:w-3/4">
      <h5 class="p-4 text-2xl font-bold bg-slate-200 text-gray-900 dark:text-white">
        Authentication Identities
      </h5>
      <.identity :for={identity <- @actor.identities} class="mb-4">
        <:provider><%= identity.provider.name %></:provider>
        <:identity><%= identity.provider_identifier %></:identity>
        <:last_auth><%= identity.last_seen_at %></:last_auth>
      </.identity>
    </div>
    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button>
          Delete user
        </.delete_button>
      </:actions>
    </.header>
    """
  end

  attr :rest, :global

  slot :provider
  slot :identity
  slot :last_auth

  def identity(assigns) do
    ~H"""
    <div {@rest}>
      <.vertical_table class="table-fixed">
        <.vertical_table_row label_width="w-1/5">
          <:label>Provider</:label>
          <:value><%= render_slot(@provider) %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Identity</:label>
          <:value><%= render_slot(@identity) %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Authentication</:label>
          <:value><%= render_slot(@last_auth) %></:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    """
  end
end
