defmodule PortalWeb.Settings.Account do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Account",
        delete_requested: false,
        account_type: account_type(socket.assigns.account)
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/account"}>Account Settings</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Account Settings
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/settings/account/edit"}>
          Edit Account
        </.edit_button>
      </:action>
      <:content>
        <.vertical_table id="account">
          <.vertical_table_row>
            <:label>Account Name</:label>
            <:value>{@account.name}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Account ID</:label>
            <:value>{@account.id}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Account Slug</:label>
            <:value>
              <.copy id="account-slug">{@account.slug}</.copy>
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Notifications
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/settings/account/notifications/edit"}>
          Edit Notifications
        </.edit_button>
      </:action>
      <:content>
        <div class="relative overflow-x-auto">
          <.notifications_table notifications={@account.config.notifications} />
        </div>
      </:content>
    </.section>

    <.section>
      <:title>
        Danger zone
      </:title>
      <:action>
        <.button_with_confirmation
          id="delete_account"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete_account"
          disabled={@delete_requested}
        >
          <:dialog_title>Confirm Account Deletion</:dialog_title>
          <:dialog_content>
            This account <strong>{@account.slug}</strong>
            will be scheduled for complete deletion.<br /><br />
            Are you sure you want to delete your account?
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Account
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          <span :if={@delete_requested}>Delete Requested</span>
          <span :if={!@delete_requested}>Delete Account</span>
        </.button_with_confirmation>
      </:action>
      <:content>
        <h3 class="ml-4 mb-4 font-medium text-neutral-900">
          Terminate account
        </h3>
        <p class="ml-4 mb-4 text-neutral-600">
          <.icon name="hero-exclamation-circle" class="inline-block w-5 h-5 mr-1 text-red-500" />
          <span :if={@delete_requested}>
            A request has been sent to delete your account.
          </span>
          <span :if={!@delete_requested}>
            Schedule your account for deletion.
          </span>
        </p>
      </:content>
    </.section>
    """
  end

  def handle_event("delete_account", _params, socket) do
    Portal.Mailer.AccountDelete.account_delete_email(
      socket.assigns.account,
      socket.assigns.subject
    )
    |> Portal.Mailer.deliver()

    socket =
      socket
      |> assign(:delete_requested, true)

    {:noreply, socket}
  end

  defp notifications_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm text-left text-neutral-500">
        <thead class="text-xs text-neutral-700 uppercase bg-neutral-50">
          <tr>
            <th class="px-4 py-3 font-medium">Notification Type</th>
            <th class="px-4 py-3 font-medium">Status</th>
          </tr>
        </thead>
        <tbody>
          <tr class="border-b">
            <td class="px-4 py-3">
              Gateway Upgrade Available
            </td>
            <td class="px-4 py-3">
              <.notification_badge notification={
                Map.get(@notifications || %{}, :outdated_gateway, %{enabled: false})
              } />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp notification_badge(assigns) do
    ~H"""
    <.badge type={if @notification.enabled, do: "success", else: "neutral"}>
      {if @notification.enabled, do: "Enabled", else: "Disabled"}
    </.badge>
    """
  end

  defp account_type(%Portal.Account{metadata: %{string: %{product_name: type}}}) do
    type || "Starter"
  end

  defp account_type(%Portal.Account{}), do: "Starter"
end
