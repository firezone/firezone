defmodule Web.Settings.ApiClients.Beta do
  use Web, :live_view

  def mount(_params, _session, socket) do
    if Domain.Accounts.rest_api_enabled?(socket.assigns.account) do
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
    else
      socket =
        socket
        |> assign(:page_title, "API Clients")
        |> assign(:requested, false)

      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>API Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/beta"}>Beta</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= @page_title %></:title>
      <:help>
        API Clients are used to manage Firezone configuration through a REST API. See our
        <a class={link_style()} href={url(API.Endpoint, ~p"/swaggerui")}>interactive API docs</a>
      </:help>
      <:content>
        <.flash kind={:info}>
          <p class="flex items-center gap-1.5 text-sm font-semibold leading-6">
            <span class="hero-wrench-screwdriver h-4 w-4"></span> REST API Beta
          </p>
          The REST API is currently in closed beta.
          <span :if={@requested == false}>
            <p>
              <a
                id="beta-request"
                href="#"
                class="text-accent-900 underline"
                phx-click="request_access"
              >
                Click here
              </a>
              to request access.
            </p>
          </span>
          <span :if={@requested == true}>
            <p>
              Your request to join the closed beta has been made.
            </p>
          </span>
        </.flash>
      </:content>
    </.section>
    """
  end

  def handle_event("request_access", _params, socket) do
    Web.Mailer.BetaEmail.rest_api_beta_email(
      socket.assigns.account,
      socket.assigns.subject
    )
    |> Web.Mailer.deliver()

    socket =
      socket
      |> assign(:requested, true)

    {:noreply, socket}
  end
end
