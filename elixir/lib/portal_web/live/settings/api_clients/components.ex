defmodule PortalWeb.Settings.ApiClients.Components do
  use PortalWeb, :component_library

  attr :form, :any, required: true

  def api_token_creation_form(assigns) do
    ~H"""
    <div>
      <.input
        label="Name"
        field={@form[:name]}
        placeholder="E.g. 'GitHub Actions' or 'Terraform'"
        phx-debounce="300"
        required
      />
      <p class="mt-2 text-xs text-[var(--text-tertiary)]">
        Describe what this API token will be used for. This can be changed later if needed.
      </p>
    </div>

    <div class="mt-4">
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

  def api_token_reveal(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <p class="text-sm font-semibold text-[var(--text-primary)]">Your API Token</p>

      <.code_block
        id="code-api-token"
        class="text-xs rounded-md [&_code]:overflow-x-auto [&_code]:whitespace-pre-wrap [&_code]:break-all [&_code]:p-2"
        phx-no-format
      ><%= @encoded_token %></.code_block>

      <div class="rounded border border-[var(--warning-border)] bg-[var(--warning-surface)] px-4 py-3 text-xs text-[var(--warning-text)]">
        Store this token in a safe place. <strong>It won't be shown again.</strong>
      </div>
    </div>
    """
  end
end
