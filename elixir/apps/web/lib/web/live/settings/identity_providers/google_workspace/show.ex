defmodule Web.Settings.IdentityProviders.GoogleWorkspace.Show do
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
      safe_to_delete_actors_count = Actors.count_synced_actors_for_provider(provider)

      {:ok,
       assign(socket,
         provider: provider,
         identities_count_by_provider_id: identities_count_by_provider_id,
         groups_count_by_provider_id: groups_count_by_provider_id,
         safe_to_delete_actors_count: safe_to_delete_actors_count,
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

      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/google_workspace/#{@provider}"}>
        {@provider.name}
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Identity Provider: <code>{@provider.name}</code>
        <span :if={not is_nil(@provider.disabled_at)} class="text-primary-600">(disabled)</span>
        <span :if={not is_nil(@provider.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.edit_button navigate={
          ~p"/#{@account}/settings/identity_providers/google_workspace/#{@provider.id}/edit"
        }>
          Edit
        </.edit_button>
      </:action>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.button_with_confirmation
          :if={is_nil(@provider.disabled_at)}
          id="disable"
          style="warning"
          icon="hero-lock-closed"
          on_confirm="disable"
        >
          <:dialog_title>Confirm disabling the Provider</:dialog_title>
          <:dialog_content>
            Are you sure you want to disable this Provider?
            This will <strong>immediately</strong>
            sign out all Actors who were signed in using this Provider and directory sync will be paused.
          </:dialog_content>
          <:dialog_confirm_button>
            Disable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Disable
        </.button_with_confirmation>
        <%= if @provider.adapter_state["status"] != "pending_access_token" do %>
          <.button_with_confirmation
            :if={not is_nil(@provider.disabled_at)}
            id="enable"
            style="warning"
            confirm_style="primary"
            icon="hero-lock-open"
            on_confirm="enable"
          >
            <:dialog_title>Confirm enabling the Provider</:dialog_title>
            <:dialog_content>
              Are you sure you want to enable this provider?
            </:dialog_content>
            <:dialog_confirm_button>
              Enable
            </:dialog_confirm_button>
            <:dialog_cancel_button>
              Cancel
            </:dialog_cancel_button>
            Enable
          </.button_with_confirmation>
        <% end %>
      </:action>
      <:action :if={is_nil(@provider.deleted_at)}>
        <.button
          style="primary"
          href={
            ~p"/#{@account.id}/settings/identity_providers/google_workspace/#{@provider}/redirect"
          }
          icon="hero-arrow-path"
        >
          Reconnect
        </.button>
      </:action>
      <:help>
        <p>
          Directory sync is enabled for this provider. Users, groups, and organizational units will
          be synced every few minutes on average, but could take longer for very large organizations.
        </p>
        <p>
          <.website_link path="/kb/authenticate/directory-sync">
            Read more
          </.website_link>
          about directory sync.
        </p>
      </:help>
      <:content>
        <.header>
          <:title>Details</:title>
        </.header>

        <.flash_group flash={@flash} />

        <.flash :if={@safe_to_delete_actors_count > 0} kind={:warning}>
          You have {@safe_to_delete_actors_count} Actor(s) that were synced from this provider and do not have any other identities.
          <.button_with_confirmation
            id="delete_stale_actors"
            style="danger"
            icon="hero-trash-solid"
            on_confirm="delete_stale_actors"
            class="mt-4"
          >
            <:dialog_title>Confirm deletion of stale Actors</:dialog_title>
            <:dialog_content>
              Are you sure you want to delete all Actors that were synced synced from this provider and do not have any other identities?
            </:dialog_content>
            <:dialog_confirm_button>
              Delete Actors
            </:dialog_confirm_button>
            <:dialog_cancel_button>
              Cancel
            </:dialog_cancel_button>
            Delete Actors
          </.button_with_confirmation>
        </.flash>

        <div class="bg-white overflow-hidden">
          <.vertical_table id="provider">
            <.vertical_table_row>
              <:label>Name</:label>
              <:value>
                {@provider.name}
                <.assigned_default_badge provider={@provider} />
              </:value>
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
                <.sync_status
                  account={@account}
                  provider={@provider}
                  identities_count_by_provider_id={@identities_count_by_provider_id}
                  groups_count_by_provider_id={@groups_count_by_provider_id}
                />
                <div
                  :if={
                    (is_nil(@provider.last_synced_at) and not is_nil(@provider.last_sync_error)) or
                      not is_nil(@provider.sync_disabled_at) or
                      (@provider.last_syncs_failed > 3 and not is_nil(@provider.last_sync_error))
                  }
                  class="w-fit p-3 mt-2 border-l-4 border-red-500 bg-red-100 rounded-md"
                >
                  <p class="font-medium text-red-700">
                    IdP provider reported an error during the last sync:
                  </p>
                  <div class="flex items-center mt-1">
                    <span class="text-red-500 font-mono">{@provider.last_sync_error}</span>
                  </div>
                </div>
              </:value>
            </.vertical_table_row>

            <.vertical_table_row>
              <:label>Client ID</:label>
              <:value>{@provider.adapter_config["client_id"]}</:value>
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
          <:dialog_title>Confirm deletion of Identity Provider</:dialog_title>
          <:dialog_content>
            Are you sure you want to delete this provider? This will remove <strong>all</strong>
            Actors and Groups associated with this provider.
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

  def handle_event("delete_stale_actors", _params, socket) do
    :ok =
      Actors.delete_stale_synced_actors_for_provider(
        socket.assigns.provider,
        socket.assigns.subject
      )

    {:noreply,
     push_navigate(socket, to: view_provider(socket.assigns.account, socket.assigns.provider))}
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
