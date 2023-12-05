defmodule Web.Settings.IdentityProviders.GoogleWorkspace.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">
            Step 1. Enable Admin SDK API
          </h2>
          Please visit following link and enable Admin SDK API for your Google Workspace account:
          <a
            href="https://console.cloud.google.com/apis/library/admin.googleapis.com"
            class={link_style()}
            target="_blank"
          >
            https://console.cloud.google.com/apis/library/admin.googleapis.com
          </a>
        </div>

        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">
            Step 2. Configure OAuth consent screen
          </h2>
          Please make sure that following scopes are added to the OAuth application permissions: <.code_block
            :for={
              {name, scope} <- [
                openid: "openid",
                email: "email",
                profile: "profile",
                orgunit: "https://www.googleapis.com/auth/admin.directory.orgunit.readonly",
                group: "https://www.googleapis.com/auth/admin.directory.group.readonly",
                user: "https://www.googleapis.com/auth/admin.directory.user.readonly"
              ]
            }
            id={"scope-#{name}"}
            class="w-full mb-4 whitespace-nowrap rounded"
            phx-no-format
          ><%= scope %></.code_block>
        </div>

        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">
            Step 3: Create OAuth client
          </h2>
          Please make sure that OAuth client has following redirect URL's whitelisted: <.code_block
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
            class="w-full mb-4 whitespace-nowrap rounded"
            phx-no-format
          ><%= redirect_url %></.code_block>
        </div>

        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-neutral-900">
            Step 4. Configure client
          </h2>

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
              </div>

              <div>
                <.input
                  label="Client secret"
                  autocomplete="off"
                  field={adapter_config_form[:client_secret]}
                  required
                />
              </div>
            </.inputs_for>
          </div>

          <div class="flex items-center space-x-4">
            <.submit_button>
              Connect Identity Provider
            </.submit_button>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
