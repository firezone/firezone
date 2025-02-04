defmodule Web.Settings.IdentityProviders.GoogleWorkspace.Components do
  use Web, :component_library
  alias Domain.Auth.Adapters.GoogleWorkspace

  def map_provider_form_attrs(attrs) do
    attrs
    |> Map.put("adapter", :google_workspace)
    |> Map.update("adapter_config", %{}, fn adapter_config ->
      Map.update(adapter_config, "service_account_json_key", nil, fn service_account_json_key ->
        case Jason.decode(service_account_json_key) do
          {:ok, map} -> map
          {:error, _} -> service_account_json_key
        end
      end)
    end)
  end

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
      <.flash kind={:info} style="wide" class="mb-4">
        Please note that a Google Workspace Super Admin is <b>required</b>
        to setup this Identity Provider. <br />For more information please see our
        <.website_link path="/kb/authenticate/google">docs</.website_link>
      </.flash>
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
                <.link href={~p"/images/gcp-oauth-screen-logo.png"} class={link_style()}>
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
                <code class="px-1 py-0.5 text-sm bg-neutral-600 text-white rounded">
                  firezone.dev
                </code>
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
              id="oauth-scopes-2"
              class="w-full text-xs mb-4 whitespace-pre-line rounded"
              phx-no-format
            ><%= Enum.join(GoogleWorkspace.Settings.scope(), "\n") %></.code_block>
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
              values from the next screen to the form below.
            </p>
          </:content>
        </.step>

        <.step>
          <:title>Step 6: Create service account with domain-wide delegation</:title>
          <:content>
            <p class="mb-4">
              Go to the
              <a
                href="https://console.cloud.google.com/iam-admin/serviceaccounts"
                target="_blank"
                class={link_style()}
              >
                <strong>Service Accounts</strong>
              </a>
              page of the Google Cloud Console and click <strong>Create Service Account</strong>.
            </p>
            <p class="mb-4">
              Use the following values on the next screen:
              <ul class="ml-4 mb-4 list-disc list-inside">
                <li>
                  <strong>Service account name</strong>: Firezone directory sync
                </li>
                <li>
                  <strong>Service account ID</strong>:
                  <code class="px-1 py-0.5 text-sm bg-neutral-600 text-white rounded">
                    firezone-directory-sync
                  </code>
                </li>
              </ul>
            </p>
            <p class="mb-4">
              Leave the rest of the options as they are, and click <strong>DONE</strong>.
            </p>
            <p class="mb-4">
              Click on the created service account, then click the <strong>Keys</strong>
              tab, <strong>Add Key</strong>
              and select <strong>Create new key</strong>. Select <strong>JSON</strong>
              and click <strong>Create</strong>. The contents of the downloaded JSON will be used for the
              <strong>Service Account JSON Key</strong>
              field of the form below.
            </p>
            <p class="mb-4">
              Go back to the <strong>Details</strong>
              tab and copy the <strong>Unique ID</strong>
              (OAuth 2 Client ID). You will need it for the next step.
            </p>
            <p class="mb-4">
              Next, go to the
              <a href="https://admin.google.com/ac/owl" target="_blank" class={link_style()}>
                <strong>API Controls</strong>
              </a>
              section of the Google Workspace Admin console.
              Click <strong>Manage Domain Wide Delegation</strong>, <strong>Add new</strong>
              and paste the <strong>Unique ID</strong>
              from the previous step to the <strong>Client ID</strong>
              field and add the following scopes: <.code_block
                id="oauth-scopes-1"
                class="w-full text-xs mb-4 whitespace-pre-line rounded"
                phx-no-format
              ><%= Enum.join(GoogleWorkspace.Settings.scope(), ",\n") %></.code_block>
            </p>
            <p class="mb-4">
              Finally, click <strong>Authorize</strong>.
            </p>
          </:content>
        </.step>

        <.step>
          <:title>Step 7. Configure Firezone</:title>
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
                    The Client ID from Step 5.
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
                    The Client secret from Step 5.
                  </p>
                </div>

                <div>
                  <.input
                    type="textarea"
                    label="Service Account JSON Key"
                    autocomplete="off"
                    field={adapter_config_form[:service_account_json_key]}
                    placeholder='{"type":"service_account","project_id":...}'
                    value={
                      case adapter_config_form[:service_account_json_key].value do
                        nil ->
                          nil

                        %Ecto.Changeset{} = changeset ->
                          changeset
                          |> Ecto.Changeset.apply_changes()
                          |> Map.from_struct()
                          |> Jason.encode!()

                        %GoogleWorkspace.Settings.GoogleServiceAccountKey{} = struct ->
                          struct
                          |> Map.from_struct()
                          |> Jason.encode!()

                        binary when is_binary(binary) ->
                          binary
                      end
                    }
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The Service Account JSON Key from Step 6.
                  </p>
                </div>
              </.inputs_for>

              <p class="text-sm text-neutral-500">
                <strong>Note:</strong>
                Only active users count towards your billing limits.
                See your
                <.link navigate={~p"/#{@account}/settings/billing"} class={link_style()}>
                  billing page
                </.link>
                for more information.
              </p>
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
