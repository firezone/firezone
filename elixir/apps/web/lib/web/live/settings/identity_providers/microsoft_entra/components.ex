defmodule Web.Settings.IdentityProviders.MicrosoftEntra.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <.step>
          <:title>Step 1. Create a new App Registration in Microsoft Entra</:title>
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
                      url(
                        ~p"/#{@account.id}/settings/identity_providers/microsoft_entra/#{@id}/handle_callback"
                      )
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
                    label="Discovery Document URI"
                    autocomplete="off"
                    field={adapter_config_form[:discovery_document_uri]}
                    placeholder="https://login.microsoftonline.com/<azure-tenant-id>/v2.0/.well-known/openid-configuration"
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The URI to the OpenID Connect discovery document for your Microsoft Entra ID provider.
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
    """
    openid
    profile
    email
    offline_access
    Group.Read.All
    GroupMember.Read.All
    User.Read
    User.Read.All
    """
  end
end
