defmodule Web.Settings.IdentityProviders.JumpCloud.Show do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <-
           Auth.fetch_provider_by_id(provider_id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
           ),
         {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(socket.assigns.subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(socket.assigns.subject) do
      {:ok, maybe_workos_directory} = maybe_fetch_directory(provider)

      {:ok,
       assign(socket,
         provider: provider,
         identities_count_by_provider_id: identities_count_by_provider_id,
         groups_count_by_provider_id: groups_count_by_provider_id,
         workos_directory: maybe_workos_directory,
         page_title: "Identity Provider #{provider.name}"
       )}
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

      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/jumpcloud/#{@provider}"}>
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
          ~p"/#{@account}/settings/identity_providers/jumpcloud/#{@provider.id}/edit"
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
          data-confirm="Are you sure want to disable this provider? Users will no longer be able to sign in with this provider and directory sync will be paused."
        >
          Disable
        </.button>

        <%= if @provider.adapter_state["status"] != "pending_access_token" do %>
          <.button
            :if={not is_nil(@provider.disabled_at)}
            phx-click="enable"
            style="warning"
            icon="hero-lock-open"
            data-confirm="Are you sure want to enable this provider?"
          >
            Enable
          </.button>
        <% end %>
      </:action>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.button
          style="primary"
          navigate={~p"/#{@account.id}/settings/identity_providers/jumpcloud/#{@provider}/redirect"}
          icon="hero-arrow-path"
        >
          Reconnect
        </.button>
      </:action>
      <:help>
        Directory sync is enabled for this provider. Users and groups will be synced every 10
        minutes on average, but could take longer for very large organizations.
        <.website_link href="/kb/authenticate/directory-sync">
          Read more
        </.website_link>
        about directory sync.
      </:help>
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
              <:label>Sync Status</:label>
              <:value>
                <.sync_portal_button :if={show_setup_sync_button?(@provider, @workos_directory)}>
                  Setup Sync
                </.sync_portal_button>
                <div
                  :if={not show_setup_sync_button?(@provider, @workos_directory)}
                  class="lg:flex lg:gap-4"
                >
                  <.sync_status
                    account={@account}
                    provider={@provider}
                    identities_count_by_provider_id={@identities_count_by_provider_id}
                    groups_count_by_provider_id={@groups_count_by_provider_id}
                  />
                  <.sync_portal_button :if={provider_active?(@provider)}>
                    Edit Sync
                  </.sync_portal_button>
                  <div
                    :if={
                      (is_nil(@provider.last_synced_at) and not is_nil(@provider.last_sync_error)) or
                        not is_nil(@provider.sync_disabled_at) or
                        (@provider.last_syncs_failed > 3 and not is_nil(@provider.last_sync_error))
                    }
                    class="p-3 mt-2 border-l-4 border-red-500 bg-red-100 rounded-md"
                  >
                    <p class="font-medium text-red-700">
                      IdP provider reported an error during the last sync:
                    </p>
                    <div class="flex items-center mt-1">
                      <span class="text-red-500 font-mono"><%= @provider.last_sync_error %></span>
                    </div>
                  </div>
                </div>
              </:value>
            </.vertical_table_row>

            <.vertical_table_row>
              <:label>Client ID</:label>
              <:value><%= @provider.adapter_config["client_id"] %></:value>
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
        <.delete_button
          data-confirm="Are you sure want to delete this provider along with all related data?"
          phx-click="delete"
        >
          Delete Identity Provider
        </.delete_button>
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

  def handle_event("setup_sync", _params, socket) do
    account = socket.assigns.account
    provider = socket.assigns.provider

    return_url =
      url(~p"/#{account}/settings/identity_providers/jumpcloud/#{provider}")

    with {:ok, workos_portal} <-
           Domain.Auth.DirectorySync.WorkOS.create_portal_link(
             provider,
             return_url,
             socket.assigns.subject
           ) do
      {:noreply, redirect(socket, external: workos_portal.link)}
    end
  end

  attr :account, :any, required: true
  attr :provider, :any, required: true

  attr :workos_directory, :any, required: true

  def jumpcloud_sync_status(assigns) do
    ~H"""

    """
  end

  slot :inner_block

  defp sync_portal_button(assigns) do
    ~H"""
    <.button size="xs" phx-click="setup_sync">
      <%= render_slot(@inner_block) %>
    </.button>
    """
  end

  defp show_setup_sync_button?(provider, workos_directory) do
    provider_active?(provider) and !workos_directory
  end

  defp provider_active?(provider) do
    is_nil(provider.deleted_at) and is_nil(provider.disabled_at)
  end

  defp maybe_fetch_directory(provider) do
    Domain.Auth.DirectorySync.WorkOS.fetch_directory(provider)
  end
end
