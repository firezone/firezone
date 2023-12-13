defmodule Web.Settings.IdentityProviders.GoogleWorkspace.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <.step>
          <:title>Step 1. Create a new project in Google Cloud</:title>
          <:content>
            Visit the following link to create a new project to use for this integration:
            <a
              href="https://console.cloud.google.com/projectcreate"
              class={link_style()}
              target="_blank"
            >
              https://console.cloud.google.com/projectcreate
            </a>
          </:content>
        </.step>

        <.step>
          <:title>Step 2. Enable Admin SDK API</:title>
          <:content>
            Visit the following link to enable the Admin SDK API for the project you just created:
            <a
              href="https://console.cloud.google.com/apis/library/admin.googleapis.com"
              class={link_style()}
              target="_blank"
            >
              https://console.cloud.google.com/apis/library/admin.googleapis.com
            </a>
          </:content>
        </.step>

        <.step>
          <:title>Step 3. Configure OAuth consent screen</:title>
          <:content>
            <p class="mb-4">
              Visit the following link to configure the OAuth consent screen:
              <a
                href="https://console.cloud.google.com/apis/credentials/consent"
                class={link_style()}
                target="_blank"
              >
                https://console.cloud.google.com/apis/credentials/consent
              </a>
            </p>
            <p class="mb-4">
              Select <strong>Internal</strong> for the user type and click <strong>CREATE</strong>.
            </p>
            <p class="mb-4">
              On the next page, use the following values:
            </p>
            <ul class="ml-4 mb-4 list-disc list-inside">
              <li>
                <strong>App name</strong>: Firezone
              </li>
              <li>
                <strong>User support email</strong>: Your email address
              </li>
              <li>
                <strong>App logo</strong>:
                <.link
                  href="https://www.firezone.dev/images/gco-oauth-screen-logo.png"
                  class={link_style()}
                >
                  Download here
                </.link>
              </li>
              <li>
                <strong>Application home page</strong>:
                <.link href="https://www.firezone.dev" class={link_style()}>
                  https://www.firezone.dev
                </.link>
              </li>
              <li>
                <strong>Application privacy policy link</strong>:
                <.link href="https://www.firezone.dev/privacy-policy" class={link_style()}>
                  https://www.firezone.dev/privacy-policy
                </.link>
              </li>
              <li>
                <strong>Application terms of service link</strong>:
                <.link href="https://www.firezone.dev/terms" class={link_style()}>
                  https://www.firezone.dev/terms
                </.link>
              </li>
              <li>
                <strong>Authorized domains</strong>:
                <code class="px-1 py-0.5 text-sm bg-neutral-600 text-white">firezone.dev</code>
              </li>
            </ul>
            <p class="mb-4">
              Click <strong>SAVE AND CONTINUE</strong>.
            </p>
          </:content>
        </.step>

        <.step>
          <:title>Step 4. Configure scopes</:title>
          <:content>
            <p class="mb-4">
              Click <strong>ADD OR REMOVE SCOPES</strong> and ensure the following scopes are added:
            </p>
            <.code_block
              id="oauth-scopes"
              class="w-full text-xs mb-4 whitespace-pre-line rounded"
              phx-no-format
            ><%= scopes() %></.code_block>
            <p class="mb-4">
              Then click <strong>UPDATE</strong>.
            </p>
          </:content>
        </.step>

        <.step>
          <:title>Step 5: Create client credentials</:title>
          <:content>
            <p class="mb-4">
              Go to the client credentials section and click <strong>CREATE CREDENTIALS</strong>
              to create new OAuth credentials.
            </p>
            <p class="mb-4">
              Select <strong>OAuth client ID</strong>
              and then select <strong>Web application</strong>.
            </p>
            <p class="mb-4">
              Use the following values on the next screen:
            </p>
            <ul class="ml-4 mb-4 list-disc list-inside">
              <li>
                <strong>Name</strong>: Firezone OAuth Client
              </li>
              <li>
                <strong>Authorized redirect URIs</strong>:
                <p class="mt-4">
                  <.code_block
                    :for={
                      {type, redirect_url} <- [
                        sign_in: url(~p"/#{@account.id}/sign_in/providers/#{@id}/handle_callback"),
                        connect:
                          url(
                            ~p"/#{@account.id}/settings/identity_providers/google_workspace/#{@id}/handle_callback"
                          )
                      ]
                    }
                    id={"redirect_url-#{type}"}
                    class="w-full mb-4 text-xs whitespace-nowrap rounded"
                    phx-no-format
                  ><%= redirect_url %></.code_block>
                </p>
              </li>
            </ul>
            <p class="mb-4">
              Click <strong>CREATE</strong>. Copy the <strong>Client ID</strong>
              and <strong>Client secret</strong>
              values from the next screen.
            </p>
          </:content>
        </.step>

        <.step>
          <:title>Step 6. Configure Firezone</:title>
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
    https://www.googleapis.com/auth/admin.directory.orgunit.readonly
    https://www.googleapis.com/auth/admin.directory.group.readonly
    https://www.googleapis.com/auth/admin.directory.user.readonly
    """
  end
end
