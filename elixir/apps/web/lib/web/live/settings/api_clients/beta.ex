defmodule Web.Settings.ApiClients.Beta do
  use Web, :live_view

  def mount(_params, _session, socket) do
    if Domain.Account.rest_api_enabled?(socket.assigns.account) do
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
    else
      socket =
        assign(
          socket,
          page_title: "API Clients",
          requested: false,
          api_url: Domain.Config.get_env(:web, :api_external_url)
        )

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
      <:title>{@page_title}</:title>
      <:help>
        API Clients are used to manage Firezone configuration through a REST API. See our
        <.link navigate={"#{@api_url}/swaggerui"} class={link_style()} target="_blank">
          OpenAPI-powered docs
        </.link>
        for more information.
      </:help>
      <:content>
        <div class="w-1/2 mx-auto">
          <.flash kind={:info}>
            <p class="flex items-center gap-1.5 text-sm font-semibold leading-6">
              <span class="hero-wrench-screwdriver h-4 w-4"></span> REST API Beta
            </p>
            The REST API is currently in closed beta.
            <span :if={@requested == false}>
              <a
                id="beta-request"
                href="#"
                class="text-accent-900 underline"
                phx-click="request_access"
              >
                Click here
              </a>
              to request access.
            </span>
            <span :if={@requested == true}>
              Your request to join the closed beta has been made.
            </span>
          </.flash>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("request_access", _params, socket) do
    Domain.Mailer.BetaEmail.rest_api_beta_email(
      socket.assigns.account,
      socket.assigns.subject
    )
    |> Domain.Mailer.deliver()

    socket =
      socket
      |> assign(:requested, true)

    {:noreply, socket}
  end
end
