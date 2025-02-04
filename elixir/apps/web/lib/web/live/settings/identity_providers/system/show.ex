defmodule Web.Settings.IdentityProviders.System.Show do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <-
           Auth.fetch_provider_by_id(provider_id, socket.assigns.subject,
             preload: [created_by_identity: [:actor]]
           ) do
      socket =
        assign(socket, provider: provider, page_title: "Identity Provider #{provider.name}")

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

      <.breadcrumb path={
        ~p"/#{@account}/settings/identity_providers/google_workspace//DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"
      }>
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
            sign out all Actors who were signed in using this Provider.
          </:dialog_content>
          <:dialog_confirm_button>
            Disable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Disable
        </.button_with_confirmation>
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
              <:value>{@provider.name}</:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Status</:label>
              <:value>
                <.status provider={@provider} />
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
