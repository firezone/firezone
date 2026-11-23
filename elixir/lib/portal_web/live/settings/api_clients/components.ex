defmodule PortalWeb.Settings.ApiClients.Components do
  use PortalWeb, :component_library

  attr :form, :any, required: true

  attr :scopes, :list, required: true
  attr :error, :string, default: nil

  def api_token_creation_form(assigns) do
    ~H"""
    <div>
      <Form.input
        label="Name"
        field={@form[:name]}
        placeholder="E.g. 'GitHub Actions' or 'Terraform'"
        phx-debounce="300"
        required
      />
      <p class="mt-2 text-xs text-muted">
        Describe what this API token will be used for. This can be changed later if needed.
      </p>
    </div>

    <div class="mt-4">
      <Form.input
        label="Expires at"
        type="date"
        field={@form[:expires_at]}
        value={Date.utc_today() |> Date.add(365)}
        placeholder="When the token should auto-expire"
        required
      />
    </div>

    <.api_token_scopes scopes={@scopes} error={@error} />
    """
  end

  attr :scopes, :list, required: true
  attr :error, :string, default: nil

  def api_token_scopes(assigns) do
    ~H"""
    <div class="mt-6">
      <Page.scope_picker scopes={@scopes} field_name="api_token[scopes][]" error={@error} />
    </div>
    """
  end

  # A locked box submits nothing, which is why scopes are expanded on read-back.
  attr :encoded_token, :string, required: true

  def api_token_reveal(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <p class="flex items-center gap-2 text-sm font-semibold text-fg">
        <Core.icon name="ri-key-2-line" class="w-4 h-4 text-muted" /> Your API token
      </p>

      <Core.code_block
        id="code-api-token"
        class="text-xs [&_code]:overflow-x-auto [&_code]:whitespace-pre-wrap [&_code]:break-all [&_code]:p-2"
        phx-no-format
      ><%= @encoded_token %></Core.code_block>

      <div class="flex items-start gap-2 border border-attn bg-attn-wash px-4 py-3 text-xs text-attn">
        <Core.icon name="ri-error-warning-line" class="w-4 h-4 shrink-0" />
        <span>
        Store this token in a safe place. <strong>It won't be shown again.</strong></span>
      </div>
    </div>
    """
  end
end
