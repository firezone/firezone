defmodule Web.Settings.Billing do
  use Web, :live_view
  alias Domain.{Accounts, Actors, Clients, Gateways, Billing}
  require Logger

  def mount(_params, _session, socket) do
    admins_count = Actors.count_account_admin_users_for_account(socket.assigns.account)
    service_accounts_count = Actors.count_service_accounts_for_account(socket.assigns.account)
    users_count = Actors.count_users_for_account(socket.assigns.account)
    active_users_count = Clients.count_1m_active_users_for_account(socket.assigns.account)
    gateway_groups_count = Gateways.count_groups_for_account(socket.assigns.account)
    stripe_customer_id = socket.assigns.account.stripe_customer_id

    socket =
      assign(socket,
        page_title: "Billing",
        error: nil,
        admins_count: admins_count,
        users_count: users_count,
        active_users_count: active_users_count,
        service_accounts_count: service_accounts_count,
        gateway_groups_count: gateway_groups_count,
        customer: nil,
        loading: true
      )

    if connected?(socket) do
      if is_nil(stripe_customer_id) do
        {:ok, assign(socket, loading: false)}
      else
        with {:ok, customer} <- Billing.fetch_customer(stripe_customer_id) do
          {:ok, assign(socket, loading: false, customer: customer)}
        else
          _ ->
            {:ok,
             assign(socket,
               loading: false,
               error: "Unable to load billing information. Please try again later."
             )}
        end
      end
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/billing"}>Billing</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Billing Information
      </:title>
      <:action :if={not is_nil(@account.stripe_customer_id)}>
        <.button icon="hero-pencil" phx-click="redirect_to_billing_portal">
          Manage
        </.button>
      </:action>
      <:content :if={not @loading}>
        <.flash :if={@error} kind={:error}>
          <p>{@error}</p>

          <p>
            If you need assistance, please <.link
              class={link_style()}
              href={
                mailto_support(
                  @account,
                  @subject,
                  "Issues accessing billing portal: #{@account.name}"
                )
              }
            >contact support</.link>.
          </p>
        </.flash>

        <.vertical_table id="billing">
          <.vertical_table_row>
            <:label>Current Plan</:label>
            <:value>
              {current_plan(@customer)}
              <span class="ml-1">
                <.link
                  class={link_style()}
                  target="_blank"
                  href={
                    mailto_support(
                      @account,
                      @subject,
                      "Billing question: #{@account.name}"
                    )
                  }
                >
                  Contact sales
                </.link>
              </span>
            </:value>
          </.vertical_table_row>

          <%= if not is_nil(@customer) do %>
            <.vertical_table_row>
              <:label>Billing Email</:label>
              <:value>
                {@customer.email}
              </:value>
            </.vertical_table_row>

            <.vertical_table_row>
              <:label>Billing Name</:label>
              <:value>
                {@customer.name}
              </:value>
            </.vertical_table_row>

            <.vertical_table_row>
              <:label>Billing Address</:label>
              <:value>
                {@customer.address}
              </:value>
            </.vertical_table_row>
          <% end %>
        </.vertical_table>
      </:content>
      <:content :if={@loading}>
        <.flash kind={:info}>
          <p>Loading billing information...</p>
        </.flash>
      </:content>
    </.section>

    <.section :if={
      @account.limits |> Map.from_struct() |> Enum.any?(fn {_, value} -> not is_nil(value) end)
    }>
      <:title>
        Limits
      </:title>
      <:help>
        Upgrade your plan to increase the limits below.
      </:help>
      <:content>
        <.vertical_table id="billing-limits">
          <.vertical_table_row :if={not is_nil(@account.limits.users_count)}>
            <:label>
              <p>Users</p>
            </:label>
            <:value>
              <span class={[
                (not is_nil(@users_count) and
                   @users_count > @account.limits.users_count) && "text-red-500"
              ]}>
                {@users_count} used
              </span>
              / {@account.limits.users_count} allowed
            </:value>
          </.vertical_table_row>

          <.vertical_table_row :if={not is_nil(@account.limits.monthly_active_users_count)}>
            <:label>
              <p>Seats</p>
            </:label>
            <:value>
              <span class={[
                (not is_nil(@active_users_count) and
                   @active_users_count > @account.limits.monthly_active_users_count) && "text-red-500"
              ]}>
                {@active_users_count} used
              </span>
              / {@account.limits.monthly_active_users_count} allowed
              <p class="text-xs">Users that have signed in from a device within the last month</p>
            </:value>
          </.vertical_table_row>

          <.vertical_table_row :if={not is_nil(@account.limits.service_accounts_count)}>
            <:label>
              <p>Service Accounts</p>
            </:label>
            <:value>
              <span class={[
                (not is_nil(@service_accounts_count) and
                   @service_accounts_count > @account.limits.service_accounts_count) && "text-red-500"
              ]}>
                {@service_accounts_count} used
              </span>
              / {@account.limits.service_accounts_count} allowed
            </:value>
          </.vertical_table_row>

          <.vertical_table_row :if={not is_nil(@account.limits.account_admin_users_count)}>
            <:label>
              <p>Admins</p>
            </:label>
            <:value>
              <span class={[
                (not is_nil(@admins_count) and
                   @admins_count > @account.limits.account_admin_users_count) && "text-red-500"
              ]}>
                {@admins_count} used
              </span>
              / {@account.limits.account_admin_users_count} allowed
            </:value>
          </.vertical_table_row>

          <.vertical_table_row :if={not is_nil(@account.limits.gateway_groups_count)}>
            <:label>
              <p>Sites</p>
            </:label>
            <:value>
              <span class={[
                (not is_nil(@gateway_groups_count) and
                   @gateway_groups_count > @account.limits.gateway_groups_count) && "text-red-500"
              ]}>
                {@gateway_groups_count} used
              </span>
              / {@account.limits.gateway_groups_count} allowed
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Support
      </:title>
      <:content>
        <div class="ml-4 mb-4 text-neutral-600">
          <span :if={support_type(@customer) == "email"}>
            Please send
            <.link
              class={link_style()}
              target="_blank"
              href={
                mailto_support(
                  @account,
                  @subject,
                  "Support request: #{@account.name}"
                )
              }
            >
              an email
            </.link>
            and we will get back to you as soon as possible.
          </span>

          <span :if={support_type(@customer) == "email_and_slack"}>
            Please send us a message in the shared Slack channel or <.link
              class={link_style()}
              target="_blank"
              href={
                mailto_support(
                  @account,
                  @subject,
                  "Support request: #{@account.name}"
                )
              }
            >an email</.link>.
          </span>

          <span :if={support_type(@customer) not in ["email", "email_and_slack"]}>
            Ask questions, get help from other Firezone users on
            <.link class={link_style()} href="https://discourse.firez.one/">
              Discourse
            </.link>
            or <.link class={link_style()} href="https://discord.gg/DY8gxpSgep">Discord</.link>.
            Priority email and dedicated Slack support options are available on paid plans.
          </span>
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
            target="_blank"
            href={mailto_support(@account, @subject, "Account termination request: #{@account.name}")}
          >contact support</.link>.
        </p>
      </:content>
    </.section>
    """
  end

  def handle_event("redirect_to_billing_portal", _params, socket) do
    with {:ok, billing_portal_url} <-
           Billing.billing_portal_url(
             socket.assigns.account,
             url(~p"/#{socket.assigns.account}/settings/billing"),
             socket.assigns.subject
           ) do
      {:noreply, redirect(socket, external: billing_portal_url)}
    else
      {:error, reason} ->
        Logger.error("Failed to get billing portal URL",
          reason: inspect(reason),
          account_id: socket.assigns.account.id
        )

        socket =
          assign(socket,
            error: "The billing portal is temporarily unavailable. Please try again later."
          )

        {:noreply, socket}
    end
  end

  defp current_plan(nil), do: "Starter"

  defp current_plan(customer) do
    dbg(customer)

    "TODO"
  end

  defp support_type(nil), do: nil

  defp support_type(customer) do
    # TODO: Get this from product object
    customer["metadata"]["support_type"]
  end
end
