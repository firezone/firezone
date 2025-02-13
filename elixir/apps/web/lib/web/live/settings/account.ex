defmodule Web.Settings.Account do
  use Web, :live_view
  alias Domain.Accounts

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Account",
        account_type: Accounts.type(socket.assigns.account)
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
        <.edit_button
          :if={@account_type != "Starter"}
          navigate={~p"/#{@account}/settings/account/notifications/edit"}
        >
          Edit Notifications
        </.edit_button>
        <.upgrade_badge :if={@account_type == "Starter"} account={@account} />
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
      <:content>
        <h3 class="ml-4 mb-4 font-medium text-neutral-900">
          Terminate account
        </h3>
        <p class="ml-4 mb-4 text-neutral-600">
          <.icon name="hero-exclamation-circle" class="inline-block w-5 h-5 mr-1 text-red-500" /> To
          <span :if={Accounts.account_active?(@account)}>disable your account and</span>
          schedule it for deletion, please <.link
            class={link_style()}
            href={mailto_support(@account, @subject, "Account termination request: #{@account.name}")}
          >contact support</.link>.
        </p>
      </:content>
    </.section>
    """
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

  defp upgrade_badge(assigns) do
    ~H"""
    <.link navigate={~p"/#{@account}/settings/billing"} class="text-sm text-primary-500">
      <.badge type="primary" title="Feature available on a higher pricing plan">
        <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
      </.badge>
    </.link>
    """
  end

  defp notification_badge(assigns) do
    ~H"""
    <.badge type={if @notification.enabled, do: "success", else: "neutral"}>
      {if @notification.enabled, do: "Enabled", else: "Disabled"}
    </.badge>
    """
  end
end
