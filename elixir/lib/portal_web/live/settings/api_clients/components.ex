defmodule Web.Settings.ApiClients.Components do
  use Web, :component_library

  attr :type, :atom, required: true
  attr :form, :any, required: true
  attr :subject, :any, required: true

  def api_client_form(assigns) do
    ~H"""
    <div>
      <.input
        label="Name"
        field={@form[:name]}
        placeholder="E.g. 'GitHub Actions' or 'Terraform'"
        phx-debounce="300"
        required
      />
      <p class="mt-2 text-xs text-neutral-500">
        Describe what this API client will be used for. This can be changed later if needed.
      </p>
    </div>
    """
  end

  attr :form, :any, required: true

  def api_token_form(assigns) do
    ~H"""
    <div>
      <.input
        label="Name"
        field={@form[:name]}
        placeholder="Name for this token (optional)"
        phx-debounce="300"
      />
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
        Your API Token:
      </div>

      <div>
        <.code_block id="code-api-token" class="w-full mw-1/2 rounded" phx-no-format><%= @encoded_token %></.code_block>
        <p class="mt-2 text-xs text-gray-500">
          Store this in a safe place. <strong>It won't be shown again.</strong>
        </p>
      </div>

      <div class="flex justify-start">
        <.button
          icon="hero-arrow-uturn-left"
          navigate={~p"/#{@account}/settings/api_clients/#{@actor}"}
        >
          Back to API Client
        </.button>
      </div>
    </div>
    """
  end
end
