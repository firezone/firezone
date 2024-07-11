defmodule Web.Settings.IdentityProviders.OpenIDConnect.Show do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <-
           Auth.fetch_provider_by_id(provider_id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
           ) do
      socket =
        assign(socket,
          provider: provider,
          page_title: "Identity Provider #{provider.name}"
        )

      {:ok, socket}
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
        <span :if={not is_nil(@provider.disabled_at)} class="text-primary-600">(disabled)</span>
        <span :if={not is_nil(@provider.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.edit_button navigate={
          ~p"/#{@account}/settings/identity_providers/openid_connect/#{@provider}/edit"
        }>
          Edit
        </.edit_button>
      </:action>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.button
          :if={is_nil(@provider.disabled_at)}
          phx-click="disable"
          style="warning"
          icon="hero-lock-closed"
          data-confirm="Are you sure want to disable this provider? All users signed into this provider will be immediately signed out."
        >
          Disable
        </.button>
        <.button
          :if={not is_nil(@provider.disabled_at)}
          phx-click="enable"
          style="warning"
          icon="hero-lock-open"
          data-confirm="Are you sure want to enable this provider?"
        >
          Enable
        </.button>
      </:action>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.button
          style="primary"
          navigate={
            ~p"/#{@account.id}/settings/identity_providers/openid_connect/#{@provider}/redirect"
          }
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

        <div class="bg-white overflow-hidden">
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
              <:value>
                <span class="flex items-center gap-x-1">
                  <.provider_icon adapter={@provider.adapter} class="w-3.5 h-3.5" /> OpenID Connect
                </span>
              </:value>
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
    <.danger_zone :if={is_nil(@provider.deleted_at)}>
      <:action>
        <.button_with_confirmation
          id="delete_identity_provider"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Delete Identity Provider</:dialog_title>
          <:dialog_content>
            Are you sure want to delete this provider? This will remove
            <strong>all</strong> Actors and Groups associated with this provider.
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Identity Provider
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Identity Provider
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_event("delete", _params, socket) do
    {:ok, _provider} = Auth.delete_provider(socket.assigns.provider, socket.assigns.subject)

    {:noreply,
     push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/identity_providers")}
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
