defmodule Web.Settings.IdentityProviders.OpenIDConnect.Show do
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

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/openid_connect/#{@provider}"}>
        <%= @provider.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Identity Provider <code><%= @provider.name %></code>
      </:title>
      <:action>
        <.edit_button navigate={
          ~p"/#{@account}/settings/identity_providers/openid_connect/#{@provider}/edit"
        }>
          Edit
        </.edit_button>
      </:action>
      <!-- Wondering if these next two buttons can be combined? -->
      <:action>
        <.button :if={not is_nil(@provider.disabled_at)} phx-click="enable">
          Enable
        </.button>
      </:action>
      <:action>
        <.button
          :if={is_nil(@provider.disabled_at)}
          phx-click="disable"
          data-confirm="Are you sure want to disable this provider?"
        >
          Disable
        </.button>
      </:action>
      <:action>
        <.button
          style="primary"
          navigate={~p"/#{@account}/settings/identity_providers/openid_connect/#{@provider}/redirect"}
          icon="hero-arrow-path"
        >
          Reconnect
        </.button>
      </:action>
      <:content>
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
              <:label>Type</:label>
              <:value>OpenID Connect</:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Response Type</:label>
              <:value><%= @provider.adapter_config["response_type"] %></:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Scope</:label>
              <:value><%= @provider.adapter_config["scope"] %></:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Client ID</:label>
              <:value><%= @provider.adapter_config["client_id"] %></:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Discovery URL</:label>
              <:value>
                <a href={@provider.adapter_config["discovery_document_uri"]} target="_blank">
                  <%= @provider.adapter_config["discovery_document_uri"] %>
                  <.icon name="hero-arrow-top-right-on-square" class="relative bottom-1 w-3 h-3" />
                </a>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Created</:label>
              <:value>
                <.created_by account={@account} schema={@provider} />
              </:value>
            </.vertical_table_row>
          </.vertical_table>
        </div>
      </:content>
    </.section>
    <.section>
      <:title>
        Danger zone
      </:title>
      <:action>
        <.delete_button
          data-confirm="Are you sure want to delete this provider along with all related data?"
          phx-click="delete"
        >
          Delete Identity Provider
        </.delete_button>
      </:action>
      <:content></:content>
    </.section>
    """
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
end
