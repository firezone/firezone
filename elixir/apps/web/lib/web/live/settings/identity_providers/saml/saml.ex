defmodule Web.Settings.IdentityProviders.SAML.New do
  use Web, :live_view
  import Web.Settings.IdentityProviders.SAML.Components

  # TODO: Use a changeset for this
  @form_initializer %{
    "type" => "saml",
    "scopes" => "openid profile email offline_access",
    "provisioning_strategy" => "scim",
    "saml_sign_requests" => true,
    "saml_sign_metadata" => true,
    "saml_require_signed_assertions" => true,
    "saml_require_signed_envelopes" => true
  }

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(@form_initializer))}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/new"}>
        Create Identity Provider
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/saml/new"}>SAML</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Add a new SAML Identity Provider
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <.form for={@form} id="saml-form" phx-change="change" phx-submit="submit">
            <h2 class="mb-4 text-xl font-bold text-neutral-900">SAML configuration</h2>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name"
                  autocomplete="off"
                  field={@form[:name]}
                  class={[
                    "bg-neutral-50 border border-neutral-300 text-neutral-900 text-sm rounded",
                    "block w-full p-2.5"
                  ]}
                  placeholder="Name this identity provider"
                  required
                />
                <p class="mt-2 text-xs text-neutral-500">
                  A friendly name for this identity provider. This will be displayed to end-users.
                </p>
              </div>
              <div>
                <.input
                  label="Metadata"
                  type="textarea"
                  field={@form[:metadata]}
                  placeholder="SAML XML Metadata from your identity provider"
                  required
                />
              </div>
              <div>
                <.input label="Sign requests" type="checkbox" field={@form[:saml_sign_requests]} />
              </div>
              <div>
                <.input label="Sign metadata" type="checkbox" field={@form[:saml_sign_metadata]} />
              </div>
              <div>
                <.input
                  label="Require signed assertions"
                  type="checkbox"
                  field={@form[:saml_require_signed_assertions]}
                />
              </div>
              <div>
                <.input
                  label="Require signed envelopes"
                  type="checkbox"
                  field={@form[:saml_require_signed_envelopes]}
                />
              </div>
            </div>

            <.provisioning_strategy_form form={@form} />

            <.submit_button>
              Create Identity Provider
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", params, socket) do
    # TODO: Validations
    # changeset = ProvisioningStrategies.changeset(%ProvisioningStrategy{}, params)

    {:noreply, assign(socket, form: to_form(params))}
  end

  def handle_event("submit", _params, socket) do
    # TODO: Create identity provider
    idp = %{id: "DF43E951-7DFB-4921-8F7F-BF0F8D31FA89"}

    {:noreply,
     push_navigate(socket,
       to: ~p"/#{socket.assigns.subject.account}/settings/identity_providers/saml/#{idp.id}"
     )}
  end
end
