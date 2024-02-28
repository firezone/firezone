defmodule Web.Settings.ApiClients.Components do
  use Web, :component_library

  attr :type, :atom, required: true
  attr :form, :any, required: true
  attr :subject, :any, required: true

  def api_client_form(assigns) do
    ~H"""
    <div>
      <.input label="Name" field={@form[:name]} placeholder="Name for API client" required />
    </div>
    """
  end

  attr :form, :any, required: true

  def api_token_form(assigns) do
    ~H"""
    <div>
      <.input label="Name" field={@form[:name]} placeholder="Name for this token (optional)" />
    </div>

    <div>
      <.input
        label="Expires At"
        type="date"
        field={@form[:expires_at]}
        value={Date.utc_today() |> Date.add(365)}
        placeholder="When the token should auto-expire"
        required
      />
    </div>
    """
  end

  attr :encoded_token, :string, required: true
  attr :account, :any, required: true
  attr :actor, :any, required: true

  def api_token_reveal(assigns) do
    ~H"""
    <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
      <div class="text-xl mb-2">
        Your API token (will be shown only once):
      </div>

      <.code_block id="code-api-token" class="w-full mw-1/2 rounded" phx-no-format><%= @encoded_token %></.code_block>

      <.button icon="hero-arrow-uturn-left" navigate={~p"/#{@account}/settings/api_clients/#{@actor}"}>
        Back to API Client
      </.button>
    </div>
    """
  end
end
