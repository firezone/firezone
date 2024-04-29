defmodule Web.Settings.IdentityProviders.JumpCloud.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <.step>
          <:title>Step 1. Create a new SSO Application in JumpCloud</:title>
          <:content>
            <p class="mb-4">
              In your
              <.link
                href="https://console.jumpcloud.com/#/applications"
                class={link_style()}
                target="_blank"
              >
                JumpCloud SSO Applications
              </.link>
              page, add a new application.
            </p>

            <p class="mb-4">
              The new application should be a <strong>Custom Application</strong>
              and should use OIDC. For detailed in instructions on setting up the JumpCloud side of things visit our
              <.website_link href="/kb/authenticate/jumpcloud">JumpCloud docs</.website_link>.
            </p>
            <p class="mb-4">
              In the JumpCloud SSO application set the following redirect URIs:
            </p>
            <.code_block
              :for={
                {type, redirect_url} <- [
                  sign_in: url(~p"/#{@account.id}/sign_in/providers/#{@id}/handle_callback"),
                  connect:
                    url(
                      ~p"/#{@account.id}/settings/identity_providers/jumpcloud/#{@id}/handle_callback"
                    )
                ]
              }
              id={"redirect_url-#{type}"}
              class="w-full text-xs mb-4 whitespace-pre-line rounded"
              phx-no-format
            ><%= redirect_url %></.code_block>
            <p class="mb-4">
              For the <strong>Client Authentication Type</strong>
              make sure the following is selected: <.code_block
                id="client_auth_type"
                class="w-full text-xs mb-4 whitespace-pre-line rounded"
                phx-no-format
              >Client Secret Post</.code_block>
            </p>

            <p class="mb-4">
              For the <strong>Login URL</strong> use the following:
            </p>
            <.code_block
              id="login_url"
              class="w-full text-xs mb-4 whitespace-pre-line rounded"
              phx-no-format
            ><%= url(~p"/#{@account}") %></.code_block>
            <p class="mb-4">
              In the <strong>Attribute Mapping</strong>
              section, ensure the following standard scopes are checked:
            </p>
            <.code_block
              :for={scope <- [:email, :profile]}
              id={"scope-#{scope}"}
              class="w-full text-xs mb-4 whitespace-pre-line rounded"
              phx-no-format
            ><%= scope %></.code_block>

            <p class="mb-4">
              Before finishing the configuration in the JumpCloud admin console, make sure your user has been added to the SSO Application created above.
            </p>
            <p class="mb-4">
              Finally, click <strong>Activate</strong>
              on the bottom of the JumpCloud SSO Application config page.
              If everything was successful you will see a modal pop up with information you will need in Step 2 on this page.
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
                  A human-friendly name for this identity provider. This will be displayed to end-users.
                </p>
              </div>

              <.inputs_for :let={adapter_config_form} field={@form[:adapter_config]}>
                <div>
                  <.input
                    label="Client ID"
                    autocomplete="off"
                    field={adapter_config_form[:client_id]}
                    placeholder="Client ID from JumpCloud"
                    required
                  />
                </div>

                <div>
                  <.input
                    label="Client secret"
                    autocomplete="off"
                    field={adapter_config_form[:client_secret]}
                    placeholder="Client secret from JumpCloud"
                    required
                  />
                </div>

                <div>
                  <.input
                    label="JumpCloud API Key"
                    autocomplete="off"
                    field={adapter_config_form[:api_key]}
                    placeholder="API Key Here"
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    API Key from your JumpCloud Admin console.
                    It can be found under your user avatar in the upper right corner of the JumpCloud admin console.
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
end
