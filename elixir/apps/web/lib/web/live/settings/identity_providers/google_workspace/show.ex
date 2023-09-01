defmodule Web.Settings.IdentityProviders.GoogleWorkspace.Show do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <-
           Auth.fetch_provider_by_id(provider_id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
           ) do
      {:ok, assign(socket, provider: provider)}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _provider} = Auth.delete_provider(socket.assigns.provider, socket.assigns.subject)
    {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/settings/identity_providers")}
  end

  def handle_event("enable", _params, socket) do
    attrs = %{disabled_at: nil}
    {:ok, provider} = Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject)

    {:ok, provider} =
      Auth.fetch_provider_by_id(provider.id, socket.assigns.subject,
        preload: [created_by_identity: [:actor]]
      )

    {:noreply, assign(socket, provider: provider)}
  end

  def handle_event("disable", _params, socket) do
    attrs = %{disabled_at: DateTime.utc_now()}
    {:ok, provider} = Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject)

    {:ok, provider} =
      Auth.fetch_provider_by_id(provider.id, socket.assigns.subject,
        preload: [created_by_identity: [:actor]]
      )

    {:noreply, assign(socket, provider: provider)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>

      <.breadcrumb path={
        ~p"/#{@account}/settings/identity_providers/google_workspace//DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
      }>
        <%= @provider.name %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Viewing Identity Provider <code><%= @provider.name %></code>
      </:title>
      <:actions>
        <.edit_button navigate={
          ~p"/#{@account}/settings/identity_providers/google_workspace/#{@provider.id}/edit"
        }>
          Edit Identity Provider
        </.edit_button>
        <%= if @provider.adapter_state["status"] != "pending_access_token" do %>
          <.button :if={not is_nil(@provider.disabled_at)} phx-click="enable">
            Enable Identity Provider
          </.button>
          <.button
            :if={is_nil(@provider.disabled_at)}
            phx-click="disable"
            data-confirm="Are you sure want to disable this provider?"
          >
            Disable Identity Provider
          </.button>
        <% end %>
        <.button navigate={
          ~p"/#{@provider.account_id}/settings/identity_providers/google_workspace/#{@provider}/redirect"
        }>
          Reconnect Identity Provider
        </.button>
      </:actions>
    </.header>
    <!-- Identity Provider details -->
    <.header>
      <:title>Details</:title>
    </.header>

    <.flash_group flash={@flash} />

    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="provider">
        <.vertical_table_row>
          <:label>Name</:label>
          <:value><%= @provider.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Status</:label>
          <:value>
            <.status provider={@provider} />
          </:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Client ID</:label>
          <:value><%= @provider.adapter_config["client_id"] %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Created</:label>
          <:value>
            <.created_by schema={@provider} />
          </:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>

    <.header>
      <:title>
        Danger zone
      </:title>
      <:actions>
        <.delete_button
          data-confirm="Are you sure want to delete this provider along with all related data?"
          phx-click="delete"
        >
          Delete Identity Provider
        </.delete_button>
      </:actions>
    </.header>
    """
  end
end
