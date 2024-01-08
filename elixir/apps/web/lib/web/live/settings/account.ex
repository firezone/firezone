defmodule Web.Settings.Account do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/account"}>Account Settings</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Account Settings
      </:title>
      <:content>
        <div class="bg-white overflow-hidden">
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
              <:value>
                <.copy id="account-slug"><%= @account.slug %></.copy>
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
      <:content>
        <h3 class="ml-4 mb-4 font-medium text-neutral-900">
          Terminate account
        </h3>
        <p class="ml-4 mb-4 text-neutral-600">
          <.icon name="hero-exclamation-circle" class="inline-block w-5 h-5 mr-1 text-red-500" />
          To disable your account and schedule it for deletion, please <.link
            class={link_style()}
            href="mailto:support@firezone.dev"
          >contact support</.link>.
        </p>
      </:content>
    </.section>
    """
  end
end
