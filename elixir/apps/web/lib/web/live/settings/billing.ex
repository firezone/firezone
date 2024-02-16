defmodule Web.Settings.Billing do
  use Web, :live_view
  alias Domain.{Accounts, Billing}
  require Logger

  def mount(_params, _session, socket) do
    unless Billing.account_provisioned?(socket.assigns.account),
      do: raise(Web.LiveErrors.NotFoundError)

    socket = assign(socket, error: nil, page_title: "Billing")

    {:ok, socket}
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
      <:action>
        <.button icon="hero-pencil" phx-click="redirect_to_billing_portal">
          Manage
        </.button>
      </:action>
      <:content>
        <.flash :if={@error} kind={:error}>
          <p><%= @error %></p>

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
              <%= @account.metadata.stripe.product_name %>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={not is_nil(@account.limits.monthly_active_actors_count)}>
            <:label>Seats</:label>
            <:value>
              <span class={[
                not is_nil(@active_actors_count) and
                  @active_actors_count > @account.limits.monthly_active_actors_count && "text-red-500"
              ]}>
                <%= @active_actors_count || "?" %> used
              </span>
              / <%= @account.limits.monthly_active_actors_count %> purchased
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Plan Features
      </:title>
      <:content>
        <.vertical_table id="features">
          <.vertical_table_row :for={{key, _value} <- Map.from_struct(@account.features)}>
            <:label><.feature_name feature={key} /></:label>
            <:value>
              <% value = apply(Domain.Accounts, :"#{key}_enabled?", [@account]) %>
              <.icon
                :if={value == true}
                name="hero-check"
                class="inline-block w-5 h-5 mr-1 text-green-500"
              />
              <.icon
                :if={value == false}
                name="hero-x-mark"
                class="inline-block w-5 h-5 mr-1 text-red-500"
              />
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
        Logger.error("Failed to get billing portal URL", reason: inspect(reason))

        socket =
          assign(socket,
            error: "Billing portal is temporarily unavailable, please try again later."
          )

        {:noreply, socket}
    end
  end
end
