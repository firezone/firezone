defmodule Web.Settings.Account do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/actors"}>
      <.breadcrumb path={~p"/#{@account}/settings/account"}>Account Settings</.breadcrumb>
    </.breadcrumbs>
    <!-- Account Settings -->
    <.header>
      <:title>
        Account Settings
      </:title>
    </.header>
    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.vertical_table id="account">
        <.vertical_table_row>
          <:label>Account Name</:label>
          <:value><%= @account.name %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Account ID</:label>
          <:value><%= @account.id %></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Account Slug</:label>
          <:value><%= @account.slug %></:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    <!-- Danger zone -->
    <.header>
      <:title>
        Danger zone
      </:title>
    </.header>
    <h3 class="ml-4 mb-4 font-bold text-gray-900 dark:text-white">
      Terminate account
    </h3>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.icon name="hero-exclamation-circle" class="inline-block w-5 h-5 mr-1 text-red-500" />
      To disable your account and schedule it for deletion, please <.link
        class="text-blue-600 dark:text-blue-500 hover:underline"
        href="mailto:support@firezone.dev"
      >
        contact support
      </.link>.
    </p>
    """
  end
end
