defmodule Web.Settings.IdentityProviders.IndexNew do
  @moduledoc """
    The new identity provider settings UI for accounts that have migrated to the new authentication system.
  """

  use Web, :live_view

  alias Domain.{
    EmailOTP,
    Userpass,
    OIDC,
    Entra,
    Google,
    Okta
  }

  require Logger

  @context_options [
    {"Clients and Portal", "clients_and_portal"},
    {"Clients Only", "clients_only"},
    {"Portal Only", "portal_only"}
  ]

  def mount(_params, _session, socket) do
    auth_providers = auth_providers(socket.assigns.account)
    directories = directories(socket.assigns.account)

    {:ok,
     assign(socket,
       auth_providers: auth_providers,
       directories: directories,

       # Add Auth Provider
       provider_type: nil,
       create_step: 1,
       verification_token: nil,
       verification_error: nil,
       code_verifier: nil,
       provider_config: nil,
       form: nil,
       verified_at: nil,
       portal_only?: false,
       issuer: nil,
       hosted_domain: nil,
       tenant_id: nil,
       org_domain: nil,
       client_id: nil,
       client_secret: nil,
       discovery_document_uri: nil,
       client_id_valid?: false,
       client_secret_valid?: false,
       discovery_document_uri_valid?: false,

       # Edit Auth Provider
       provider: nil,

       # Edit Directory
       directory: nil
     )}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>Identity Providers</:title>
      <:action><.docs_action path="/guides/settings/identity-providers" /></:action>
      <:help>
        Identity providers authenticate and sync your users and groups with an external source.
      </:help>
      <:content>
        <.flash_group flash={@flash} />
      </:content>
    </.section>
    <.section>
      <:title>Authentication Providers</:title>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/identity_providers/auth_providers/new"}>
          Add Provider
        </.add_button>
      </:action>
      <:content>
        <%= for provider <- @auth_providers.email_otp do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/email_otp_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.userpass do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/userpass_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.oidc do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/oidc_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.google do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/google_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.entra do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/entra_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.okta do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/okta_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
      </:content>
    </.section>
    <.section>
      <:title>Directories</:title>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/identity_providers/directories/new"}>
          Add Directory
        </.add_button>
      </:action>
      <:content>
        <%= for directory <- @directories.google_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/google_directories/#{directory}/edit"
            }
          />
        <% end %>
        <%= for directory <- @directories.entra_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/entra_directories/#{directory}/edit"
            }
          />
        <% end %>
        <%= for directory <- @directories.okta_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/okta_directories/#{directory}/edit"
            }
          />
        <% end %>
      </:content>
    </.section>

    <.modal
      :if={@live_action == :new_auth_provider}
      id="new-auth-provider-modal"
      show={true}
      on_close="close_modal"
      on_back="back_auth_provider"
      on_confirm={if @create_step == 1, do: "next_auth_provider", else: nil}
      phx_submit={if @create_step == 2, do: "create_auth_provider", else: nil}
      phx_change="validate"
      confirm_type={if @create_step == 2, do: "submit", else: "button"}
      confirm_disabled={
        (@create_step == 1 and is_nil(@provider_type)) or
          (@create_step == 2 and is_nil(@verified_at))
      }
      for={@form}
    >
      <:title>
        {modal_title(@create_step, @provider_type)}
      </:title>
      <:body>
        <%= if @create_step == 1 do %>
          <p>Select an authentication provider type to add:</p>
          <ul class="grid w-full gap-6 grid-cols-1">
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="google"
                class={provider_selection_classes(@provider_type == "google")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:google} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Google
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against a Google Workspace account.
                </span>
              </div>
            </li>
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="entra"
                class={provider_selection_classes(@provider_type == "entra")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:entra} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Entra
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against a Microsoft Entra account.
                </span>
              </div>
            </li>
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="okta"
                class={provider_selection_classes(@provider_type == "okta")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:okta} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Okta
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against an Okta account.
                </span>
              </div>
            </li>
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="oidc"
                class={provider_selection_classes(@provider_type == "oidc")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:oidc} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    OpenID Connect
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against an OpenID Connect compliant identity provider.
                </span>
              </div>
            </li>
          </ul>
        <% else %>
          <.auth_provider_form
            type={@provider_type}
            form={@form}
            verified_at={@verified_at}
            portal_only?={@portal_only?}
          />
          <div class="mt-6 p-4 border-2 border-accent-200 bg-accent-50 rounded-lg">
            <%= if @verification_error do %>
              <.flash kind={:error} class="mb-4">
                {@verification_error}
              </.flash>
            <% end %>

            <div class="flex items-center justify-between">
              <div class="flex-1">
                <h3 class="text-base font-semibold text-gray-900">Provider Verification</h3>
                <p class="mt-1 text-sm text-gray-600">
                  Verify your provider configuration by signing in with your {capitalize_provider_type(
                    @provider_type
                  )} account.
                </p>
              </div>
              <div class="ml-4">
                <.verification_status_badge
                  provider_type={@provider_type}
                  client_id_valid?={@client_id_valid?}
                  client_secret_valid?={@client_secret_valid?}
                  discovery_document_uri_valid?={@discovery_document_uri_valid?}
                  verified_at={@verified_at}
                />
              </div>
            </div>

            <%= if @provider_type == "google" do %>
              <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
                <.verification_field
                  label="Issuer"
                  value={@issuer}
                  verified?={@verified_at != nil}
                  errors={[]}
                />
                <.verification_field
                  label="Hosted Domain"
                  value={@hosted_domain}
                  verified?={@verified_at != nil}
                  errors={@form[:hosted_domain].errors}
                />
              </div>
            <% end %>
            <%= if @provider_type == "entra" do %>
              <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
                <.verification_field
                  label="Issuer"
                  value={@issuer}
                  verified?={@verified_at != nil}
                  errors={[]}
                />
                <.verification_field
                  label="Tenant ID"
                  field={:tenant_id}
                  value={@tenant_id}
                  verified?={@verified_at != nil}
                  errors={@form[:tenant_id].errors}
                />
              </div>
            <% end %>
            <%= if @provider_type == "okta" do %>
              <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
                <.verification_field
                  label="Issuer"
                  value={@issuer}
                  verified?={@verified_at != nil}
                  errors={[]}
                />
              </div>
            <% end %>
          </div>
        <% end %>
      </:body>
      <:back_button :if={@create_step == 2}>
        Back
      </:back_button>
      <:confirm_button>
        {modal_confirm_button_text(@create_step)}
      </:confirm_button>
    </.modal>

    <.modal
      :if={@live_action == :new_directory}
      id="new-directory-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Add Directory Provider</:title>
      <:body>
        <p>Select a directory provider type to add:</p>
        {# TODO: Add directory provider selection UI }
      </:body>
    </.modal>

    <.modal
      :if={
        @live_action in [
          :edit_email_otp_auth_provider,
          :edit_userpass_auth_provider,
          :edit_oidc_auth_provider,
          :edit_google_auth_provider,
          :edit_entra_auth_provider,
          :edit_okta_auth_provider
        ] && @provider
      }
      id="edit-auth-provider-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Edit {@provider.name}</:title>
      <:body>
        <p>Edit authentication provider form will go here</p>
        {# TODO: Add provider edit form }
      </:body>
    </.modal>

    <.modal
      :if={
        @live_action in [:edit_google_directory, :edit_entra_directory, :edit_okta_directory] &&
          @directory
      }
      id="edit-directory-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Edit {@directory.name}</:title>
      <:body>
        <p>Edit directory provider form will go here</p>
        {# TODO: Add directory edit form }
      </:body>
    </.modal>
    """
  end

  def handle_params(
        %{"provider_id" => provider_id},
        _url,
        %{assigns: %{live_action: live_action}} = socket
      ) do
    provider =
      case live_action do
        :edit_email_otp_auth_provider ->
          case EmailOTP.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_userpass_auth_provider ->
          case Userpass.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_oidc_auth_provider ->
          case OIDC.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_google_auth_provider ->
          case Google.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_entra_auth_provider ->
          case Entra.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_okta_auth_provider ->
          case Okta.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        _ ->
          raise Web.LiveErrors.NotFoundError
      end

    {:noreply, assign(socket, provider: provider)}
  end

  def handle_params(
        %{"directory_id" => directory_id},
        _url,
        %{assigns: %{live_action: live_action}} = socket
      ) do
    directory =
      case live_action do
        :edit_google_directory ->
          case Google.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_entra_directory ->
          case Entra.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_okta_directory ->
          case Okta.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        _ ->
          raise Web.LiveErrors.NotFoundError
      end

    {:noreply, assign(socket, directory: directory)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, provider: nil, directory: nil)}
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(
        provider_type: nil,
        form: nil,
        create_step: 1,
        verification_token: nil,
        verification_error: nil,
        code_verifier: nil,
        provider_config: nil,
        verified_at: nil,
        portal_only?: false,
        issuer: nil,
        hosted_domain: nil,
        tenant_id: nil,
        org_domain: nil,
        client_id: nil,
        client_secret: nil,
        discovery_document_uri: nil,
        client_id_valid?: false,
        client_secret_valid?: false,
        discovery_document_uri_valid?: false
      )
      |> push_patch(to: ~p"/#{socket.assigns.account}/settings/identity_providers")

    {:noreply, socket}
  end

  def handle_event("select_provider_type", %{"provider_type" => "google"}, socket) do
    socket = assign(socket, provider_type: "google")
    changeset = changeset(%Google.AuthProvider{}, %{}, socket)
    {:noreply, assign(socket, form: to_provider_form(changeset))}
  end

  def handle_event("select_provider_type", %{"provider_type" => "entra"}, socket) do
    socket = assign(socket, provider_type: "entra")
    changeset = changeset(%Entra.AuthProvider{}, %{}, socket)
    {:noreply, assign(socket, form: to_provider_form(changeset))}
  end

  def handle_event("select_provider_type", %{"provider_type" => "okta"}, socket) do
    socket = assign(socket, provider_type: "okta")
    changeset = changeset(%Okta.AuthProvider{}, %{}, socket)
    {:noreply, assign(socket, form: to_provider_form(changeset))}
  end

  def handle_event("select_provider_type", %{"provider_type" => "oidc"}, socket) do
    socket = assign(socket, provider_type: "oidc")
    changeset = changeset(%OIDC.AuthProvider{}, %{}, socket)
    {:noreply, assign(socket, form: to_provider_form(changeset))}
  end

  def handle_event("validate", params, socket) do
    old_changeset = socket.assigns.form.source
    old_form = socket.assigns.form

    changeset =
      old_changeset
      |> changeset(params, socket)
      |> Map.put(:action, :validate)

    new_form = to_provider_form(changeset)

    IO.puts("\n=== FORM COMPARISON ===")
    IO.puts("Old form.id: #{old_form.id}")
    IO.puts("New form.id: #{new_form.id}")
    IO.puts("Old form.name: #{old_form.name}")
    IO.puts("New form.name: #{new_form.name}")
    IO.puts("Form IDs match? #{old_form.id == new_form.id}")
    IO.puts("Form structs identical? #{old_form === new_form}")
    IO.puts("Form struct hash old: #{:erlang.phash2(old_form)}")
    IO.puts("Form struct hash new: #{:erlang.phash2(new_form)}")

    IO.puts("\nOld form[:org_domain].id: #{old_form[:org_domain].id}")
    IO.puts("New form[:org_domain].id: #{new_form[:org_domain].id}")
    IO.puts("Field IDs match? #{old_form[:org_domain].id == new_form[:org_domain].id}")
    IO.puts("===========================\n")

    {:noreply, assign(socket, form: new_form)}
  end

  def handle_event("update_context", %{"auth_provider" => %{"context" => context}}, socket) do
    {:noreply, assign(socket, portal_only?: context == "portal_only")}
  end

  def handle_event("start_verification", _params, socket) do
    opts =
      case socket.assigns.provider_type do
        type when type in ["okta", "oidc"] ->
          [
            discovery_document_uri: socket.assigns.discovery_document_uri,
            client_id: socket.assigns.client_id,
            client_secret: socket.assigns.client_secret
          ]

        _ ->
          []
      end

    verification = Web.OIDC.setup_verification(socket.assigns.provider_type, opts)

    # Subscribe to verification PubSub topic if connected
    Domain.PubSub.subscribe("oidc-verification:#{verification.token}")

    socket =
      assign(socket,
        verification_token: verification.token,
        code_verifier: verification.verifier,
        provider_config: verification.config
      )

    # Push JS to open verification URL in new tab
    {:noreply, push_event(socket, "open_url", %{url: verification.url})}
  end

  def handle_event("next_auth_provider", _params, socket) do
    {:noreply, assign(socket, create_step: 2)}
  end

  def handle_event("back_auth_provider", _params, socket) do
    {:noreply, assign(socket, create_step: 1, provider_type: nil, verified_at: nil)}
  end

  def handle_event("create_auth_provider", params, socket) do
    {:noreply, create_provider(params, socket)}
  end

  defp provider_selection_classes(selected?) do
    [
      "component bg-white rounded p-4 flex items-center cursor-pointer",
      "border transition-colors",
      selected? && "border-accent-500 bg-accent-50",
      !selected? && "border-neutral-300 hover:border-neutral-400 hover:bg-neutral-50"
    ]
  end

  # Modal title helpers
  defp modal_title(step, provider_type) do
    case step do
      2 -> "Configure #{capitalize_provider_type(provider_type)} Provider"
      _ -> "Add Authentication Provider"
    end
  end

  defp modal_confirm_button_text(step) do
    case step do
      2 -> "Create"
      _ -> "Next"
    end
  end

  # Provider type formatting
  defp capitalize_provider_type(nil), do: "Provider"
  defp capitalize_provider_type(provider_type), do: String.capitalize(provider_type)

  # Verification field display helpers
  defp verification_field_display(value, verified?) do
    case {value, verified?} do
      {nil, true} -> "None"
      {"", true} -> "None"
      {nil, false} -> "Awaiting verification..."
      {"", false} -> "Awaiting verification..."
      {val, _} -> val
    end
  end

  # Verification status badge
  defp verification_status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @verified_at -> %>
        <div class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-md">
          <.icon name="hero-check-circle" class="h-5 w-5 mr-2" />
          <span class="font-medium">Verified</span>
        </div>
      <% ready_to_verify?(@provider_type, @client_id_valid?, @client_secret_valid?, @discovery_document_uri_valid?) -> %>
        <.button
          style="primary"
          icon="hero-arrow-top-right-on-square"
          phx-click="start_verification"
        >
          Verify Now
        </.button>
      <% true -> %>
        <.button
          style="primary"
          icon="hero-arrow-top-right-on-square"
          disabled
        >
          Verify Now
        </.button>
    <% end %>
    """
  end

  # Checkbox helper text for default provider option
  defp default_provider_helper_text(portal_only?) do
    if portal_only? do
      "Portal-only providers cannot be set as default."
    else
      "When selected, users signing in from the Firezone client will be taken directly to this provider for authentication."
    end
  end

  # Provider form descriptions
  defp provider_form_description("google"),
    do:
      "Configure your Google Workspace authentication provider. Users will sign in using their Google Workspace accounts."

  defp provider_form_description("entra"),
    do:
      "Configure your Microsoft Entra authentication provider. Users will sign in using their Microsoft Entra accounts."

  # Verification field component
  defp verification_field(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between items-center">
        <label class="text-sm font-medium text-neutral-700">{@label}</label>
        <div class="text-right">
          <p class="text-sm font-semibold text-neutral-900">
            {verification_field_display(@value, @verified?)}
          </p>
        </div>
      </div>
      <%= if Enum.any?(@errors) do %>
        <p class="mt-1 text-sm text-red-600">
          {@errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}
        </p>
      <% end %>
    </div>
    """
  end

  defp auth_provider_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@provider.name}</span>
      <.button size="xs" icon="hero-pencil" patch={@edit_path}>
        Edit
      </.button>
    </div>
    """
  end

  defp directory_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@directory.name}</span>
      <.button size="xs" icon="hero-pencil" patch={@edit_path}>
        Edit
      </.button>
    </div>
    """
  end

  defp auth_providers(account) do
    %{
      email_otp: EmailOTP.all_auth_providers_for_account!(account),
      userpass: Userpass.all_auth_providers_for_account!(account),
      oidc: OIDC.all_auth_providers_for_account!(account),
      entra: Entra.all_auth_providers_for_account!(account),
      google: Google.all_auth_providers_for_account!(account),
      okta: Okta.all_auth_providers_for_account!(account)
    }
  end

  defp directories(account) do
    %{
      entra_directories: Entra.all_directories_for_account!(account),
      google_directories: Google.all_directories_for_account!(account),
      okta_directories: Okta.all_directories_for_account!(account)
    }
  end

  defp auth_provider_form(%{type: type} = assigns) when type in ["google", "entra"] do
    assigns =
      assigns
      |> assign_new(:verified_at, fn -> nil end)
      |> assign(:description, provider_form_description(type))

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600">
        {@description}
      </p>

      <.input
        field={@form[:name]}
        type="text"
        label="Name"
        autocomplete="off"
        phx-debounce="300"
        data-1p-ignore
        required
      />

      <div>
        <.input
          field={@form[:context]}
          type="select"
          label="Context"
          phx-change="update_context"
          options={context_options()}
          required
        />
        <p class="mt-1 text-xs text-gray-500">
          Choose where this provider can be used for authentication
        </p>
      </div>

      <div>
        <.input
          field={@form[:assigned_default_at]}
          type="checkbox"
          label="Set as default provider"
          disabled={@portal_only?}
          checked={not is_nil(@form[:assigned_default_at].value)}
          class={@portal_only? && "cursor-not-allowed"}
        />
        <p class="mt-1 text-xs text-gray-500">
          {default_provider_helper_text(@portal_only?)}
        </p>
      </div>
    </div>
    """
  end

  defp auth_provider_form(%{type: "okta"} = assigns) do
    assigns = assign_new(assigns, :verified_at, fn -> nil end)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600">
        Configure your Okta authentication provider. Users will sign in using their Okta accounts.
      </p>

      <.input
        field={@form[:name]}
        type="text"
        label="Name"
        autocomplete="off"
        phx-debounce="300"
        data-1p-ignore
        required
      />

      <.input
        field={@form[:org_domain]}
        type="text"
        label="Okta Domain"
        placeholder="example.okta.com"
        autocomplete="off"
        phx-debounce="300"
        data-1p-ignore
        required
      />

      <.input
        field={@form[:client_id]}
        type="text"
        label="Client ID"
        autocomplete="off"
        phx-debounce="300"
        data-1p-ignore
        required
      />

      <.input
        field={@form[:client_secret]}
        type="password"
        label="Client Secret"
        autocomplete="off"
        data-1p-ignore
        required
      />

      <div>
        <.input
          field={@form[:context]}
          type="select"
          label="Context"
          phx-change="update_context"
          options={context_options()}
          required
        />
        <p class="mt-1 text-xs text-gray-500">
          Choose where this provider can be used for authentication
        </p>
      </div>

      <div>
        <.input
          field={@form[:assigned_default_at]}
          type="checkbox"
          label="Set as default provider"
          disabled={@portal_only?}
          checked={not is_nil(@form[:assigned_default_at].value)}
          class={@portal_only? && "cursor-not-allowed"}
        />
        <p class="mt-1 text-xs text-gray-500">
          {default_provider_helper_text(@portal_only?)}
        </p>
      </div>
    </div>
    """
  end

  defp auth_provider_form(%{type: "oidc"} = assigns) do
    ~H"""
    <p>OIDC Provider Form Goes Here</p>
    """
  end

  defp ready_to_verify?(
         provider_type,
         _client_id_valid?,
         _client_secret_valid?,
         _discovery_document_uri_valid?
       )
       when provider_type in ["google", "entra"] do
    true
  end

  defp ready_to_verify?(
         _provider_type,
         client_id_valid?,
         client_secret_valid?,
         discovery_document_uri_valid?
       ) do
    client_id_valid? and client_secret_valid? and discovery_document_uri_valid?
  end

  defp create_provider(
         %{"auth_provider" => attrs},
         %{assigns: %{provider_type: provider_type}} = socket
       )
       when provider_type in ["google", "entra", "okta"] do
    is_default = attrs["assigned_default_at"] == "on"

    # Add provider-specific verification fields
    attrs =
      attrs
      |> Map.put("issuer", socket.assigns.issuer)
      |> Map.put("verified_at", socket.assigns.verified_at)
      |> Map.put("assigned_default_at", if(is_default, do: DateTime.utc_now(), else: nil))
      |> add_provider_specific_attrs(provider_type, socket)

    # Call the appropriate domain function
    result =
      case provider_type do
        "google" -> Domain.Google.create_auth_provider(attrs, socket.assigns.subject)
        "entra" -> Domain.Entra.create_auth_provider(attrs, socket.assigns.subject)
        "okta" -> Domain.Okta.create_auth_provider(attrs, socket.assigns.subject)
      end

    case result do
      {:ok, provider} ->
        socket
        |> put_flash(:info, "#{provider.name} created successfully")
        |> push_patch(to: ~p"/#{socket.assigns.account}/settings/identity_providers")

      {:error, changeset} ->
        assign(socket, form: to_provider_form(changeset))
    end
  end

  defp create_provider(_params, socket) do
    # For other provider types
    socket
    |> put_flash(:error, "Provider type not yet implemented")
  end

  # Add provider-specific attributes from socket assigns
  defp add_provider_specific_attrs(attrs, "google", socket) do
    Map.put(attrs, "hosted_domain", socket.assigns.hosted_domain)
  end

  defp add_provider_specific_attrs(attrs, "entra", socket) do
    Map.put(attrs, "tenant_id", socket.assigns.tenant_id)
  end

  defp add_provider_specific_attrs(attrs, "okta", socket) do
    attrs
    |> Map.put("org_domain", socket.assigns.org_domain)
    |> Map.put("client_id", socket.assigns.client_id)
    |> Map.put("client_secret", socket.assigns.client_secret)
  end

  def handle_info({:oidc_verify, pid, code, state_token}, socket) do
    # Verify the state token matches
    stored_token = socket.assigns.verification_token

    Domain.PubSub.unsubscribe("oidc-verification:#{state_token}")

    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      code_verifier = socket.assigns.code_verifier
      config = socket.assigns.provider_config

      case Web.OIDC.verify_callback(config, code, code_verifier) do
        {:ok, claims} ->
          send(pid, :success)

          socket = assign(socket, verified_at: DateTime.utc_now())

          # Extract provider-specific fields from claims
          socket =
            case socket.assigns.provider_type do
              "google" ->
                assign(socket,
                  hosted_domain: claims["hd"],
                  issuer: claims["iss"]
                )

              "entra" ->
                assign(socket,
                  tenant_id: claims["tid"],
                  issuer: claims["iss"]
                )

              _ ->
                assign(socket, issuer: claims["iss"])
            end

          {:noreply, socket}

        {:error, reason} ->
          Logger.warning("Failed to verify provider: #{inspect(reason)}")
          send(pid, {:error, reason})
          {:noreply, socket}
      end
    else
      Logger.warning("Verification token mismatch")
      send(pid, {:error, :token_mismatch})
      {:noreply, socket}
    end
  end

  defp context_options, do: @context_options

  defp changeset(provider, attrs, %{assigns: %{provider_type: "google", subject: subject}}) do
    Google.AuthProvider.Changeset.create(provider, attrs, subject)
  end

  defp changeset(provider, attrs, %{assigns: %{provider_type: "entra", subject: subject}}) do
    Entra.AuthProvider.Changeset.create(provider, attrs, subject)
  end

  defp changeset(provider, attrs, %{assigns: %{provider_type: "okta", subject: subject}}) do
    Okta.AuthProvider.Changeset.create(provider, attrs, subject)
  end

  defp changeset(provider, attrs, %{assigns: %{provider_type: "oidc", subject: subject}}) do
    OIDC.AuthProvider.Changeset.create(provider, attrs, subject)
  end

  defp to_provider_form(changeset) do
    to_form(changeset, as: :auth_provider, id: "auth-provider-form")
  end
end
