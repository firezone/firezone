defmodule PortalWeb.Components.Turnstile do
  @moduledoc """
  The Cloudflare Turnstile widget for public forms. The page must also allow
  Turnstile in `PortalWeb.Plugs.PutSecurityHeaders`.
  """
  use Phoenix.Component

  # Each step needs its own id. A shared id would carry the widget, and its spent token,
  # from one step into the next without running the hook again.
  attr :id, :string, required: true

  def widget(assigns) do
    ~H"""
    <div
      :if={Portal.Turnstile.enabled?()}
      id={@id}
      phx-hook="Turnstile"
      phx-update="ignore"
      data-sitekey={Portal.Turnstile.site_key()}
      class="my-1"
    >
      <div data-turnstile-widget></div>
      <p data-turnstile-error role="alert" hidden class="text-sm text-error mt-1">
        We couldn't load the verification check. If a blocker is on, allow challenges.cloudflare.com and reload this page.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true

  def token_input(assigns) do
    ~H"""
    <div :if={Portal.Turnstile.enabled?()} id={@id} phx-update="ignore">
      <input type="hidden" name="cf-turnstile-response" data-turnstile-token />
    </div>
    """
  end

  def error_message(:unavailable),
    do: "We couldn't verify your request right now. Please try again in a moment."

  def error_message(_reason),
    do: "Please complete the verification and try again."

  # Tokens are single use, so the widget must issue a new one after every attempt.
  def reset(socket) do
    if Portal.Turnstile.enabled?(),
      do: Phoenix.LiveView.push_event(socket, "turnstile:reset", %{}),
      else: socket
  end
end
