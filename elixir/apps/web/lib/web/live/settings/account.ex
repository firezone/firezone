defmodule Web.Settings.Account do
  use Web, :live_view
  alias Domain.{Accounts, Billing}
  require Logger

  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        socket
        |> assign_billing_portal_url()
      else
        assign(socket,
          billing_portal_url: nil,
          billing_portal_error: nil
        )
      end

    socket = assign(socket, page_title: "Account")

    {:ok, socket}
  end

  defp assign_billing_portal_url(socket) do
    case Billing.billing_portal_url(
           socket.assigns.account,
           url(~p"/#{socket.assigns.account}/settings/account"),
           socket.assigns.subject
         ) do
      {:ok, billing_portal_url} ->
        assign(socket,
          billing_portal_url: billing_portal_url,
          billing_portal_error: nil
        )

      {:error, :account_not_provisioned} ->
        assign(socket,
          billing_portal_url: nil,
          billing_portal_error: nil
        )

      {:error, reason} ->
        Logger.error("Failed to get billing portal URL", reason: inspect(reason))

        assign(socket,
          billing_portal_url: nil,
          billing_portal_error:
            "Billing portal is temporarily unavailable, please contact support if you need assistance with changing your plan."
        )
    end
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
      <:content>
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
          <.vertical_table_row :if={Billing.account_provisioned?(@account)}>
            <:label>Current Plan</:label>
            <:value>
              <%= @account.metadata.stripe.product_name %>
              <a :if={@billing_portal_url} class={link_style()} href={@billing_portal_url}>
                (manage)
              </a>
              <div :if={@billing_portal_error} class="text-red-500">
                <%= @billing_portal_error %>
              </div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={
            Billing.account_provisioned?(@account) and
              not is_nil(@account.limits.monthly_active_actors_count) and
              not is_nil(@active_actors_count)
          }>
            <:label>Seats</:label>
            <:value>
              <span class={[
                @active_actors_count > @account.limits.monthly_active_actors_count && "text-red-500"
              ]}>
                <%= @active_actors_count %> used
              </span>
              / <%= @account.limits.monthly_active_actors_count %> purchased
            </:value>
          </.vertical_table_row>
        </.vertical_table>
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
end
