defmodule Web.SettingsLive.IdentityProviders.GoogleWorkspace.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">
            Step 1. Configure OAuth consent screen
          </h2>
          Please make sure that following scopes are added to the OAuth application permissions:
          <.code_block
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
            class="w-full mb-4 whitespace-nowrap"
          >
            <%= scope %>
          </.code_block>
        </div>

        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">
            Step 2: Create OAuth client
          </h2>
          Please make sure that OAuth client has following redirect URL's whitelisted:
          <.code_block
            :for={
              {type, redirect_url} <- [
                sign_in: url(~p"/#{@account}/sign_in/providers/#{@id}/handle_callback"),
                connect:
                  url(
                    ~p"/#{@account}/settings/identity_providers/google_workspace/#{@id}/handle_callback"
                  )
              ]
            }
            id={"redirect_url-#{type}"}
            class="w-full mb-4 whitespace-nowrap"
          >
            <%= redirect_url %>
          </.code_block>
        </div>

        <div class="mb-4">
          <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">
            3. Configure client
          </h2>

          <.base_error error={@form.errors[:base]} />

          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input
                label="Name"
                autocomplete="off"
                field={@form[:name]}
                placeholder="Name this identity provider"
                required
              />
              <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
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
            <button
              type="submit"
              class="text-white bg-primary-700 hover:bg-primary-800 focus:ring-4 focus:outline-none focus:ring-primary-300 font-medium rounded-lg text-sm px-5 py-2.5 text-center dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800"
            >
              Connect Identity Provider
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
