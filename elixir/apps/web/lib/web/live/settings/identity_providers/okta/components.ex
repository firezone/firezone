defmodule Web.Settings.IdentityProviders.Okta.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <.step>
          <:title>Step 1. Create a new App Integration in Okta</:title>
          <:content>
            <p class="mb-4">
              Ensure the following scopes are added to the OAuth application:
            </p>
            <.code_block
              id="oauth-scopes"
              class="w-full text-xs mb-4 whitespace-pre-line rounded"
              phx-no-format
            ><%= scopes() %></.code_block>

            <p class="mb-4">
              Ensure the OAuth application has the following redirect URLs whitelisted:
            </p>
            <p class="mt-4">
              <.code_block
                :for={
                  {type, redirect_url} <- [
                    sign_in: url(~p"/#{@account.id}/sign_in/providers/#{@id}/handle_callback"),
                    connect:
                      url(~p"/#{@account.id}/settings/identity_providers/okta/#{@id}/handle_callback")
                  ]
                }
                id={"redirect_url-#{type}"}
                class="w-full mb-4 text-xs whitespace-nowrap rounded"
                phx-no-format
              ><%= redirect_url %></.code_block>
            </p>
          </:content>
        </.step>

        <.step>
          <:title>Step 2. Configure Firezone</:title>
          <:content>
            <.base_error form={@form} field={:base} />

            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name"
                  autocomplete="off"
                  field={@form[:name]}
                  placeholder="Name this identity provider"
                  required
                />
                <p class="mt-2 text-xs text-neutral-500">
                  A friendly name for this identity provider. This will be displayed to end-users.
                </p>
              </div>

              <.inputs_for :let={adapter_config_form} field={@form[:adapter_config]}>
                <div>
                  <.input
                    label="Client ID"
                    autocomplete="off"
                    field={adapter_config_form[:client_id]}
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The Client ID from the previous step.
                  </p>
                </div>

                <div>
                  <.input
                    label="Client secret"
                    autocomplete="off"
                    field={adapter_config_form[:client_secret]}
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The Client secret from the previous step.
                  </p>
                </div>

                <div>
                  <.input
                    label="Okta Account Domain"
                    autocomplete="off"
                    field={adapter_config_form[:okta_account_domain]}
                    placeholder="<company>.okta.com"
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    Your Okta account domain.
                  </p>
                </div>

                <div :if={visible?(adapter_config_form[:discovery_document_uri].value)}>
                  <.input
                    type="readonly"
                    label="OIDC well-know configuration URL (readonly)"
                    field={adapter_config_form[:discovery_document_uri]}
                    placeholder=".well-known/openid-configuration URL"
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The OIDC Configuration URI.  This field is derived from the value in the Okta Account Domain field.
                  </p>
                </div>
              </.inputs_for>
            </div>

            <.submit_button>
              Connect Identity Provider
            </.submit_button>
          </:content>
        </.step>
      </.form>
    </div>
    """
  end

  def scopes do
    Domain.Auth.Adapters.Okta.Settings.scope()
    |> Enum.join("\n")
  end

  defp visible?(value) do
    case value do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
