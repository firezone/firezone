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
    {"Client Applications and Admin Portal", "clients_and_portal"},
    {"Client Applications Only", "clients_only"},
    {"Admin Portal Only", "portal_only"}
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
       okta_domain: nil,
       client_id: nil,
       client_secret: nil,
       discovery_document_uri: nil,

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
      on_close="close_modal"
      on_back="back_auth_provider"
      on_confirm={if @create_step == 1, do: "next_auth_provider", else: nil}
      confirm_disabled={
        (@create_step == 1 and is_nil(@provider_type)) or
          (@create_step == 2 and is_nil(@verified_at))
      }
    >
      <:title :if={@create_step == 2} icon={String.to_atom(@provider_type)}>
        {modal_title(@create_step, @provider_type)}
      </:title>
      <:title :if={@create_step != 2}>
        {modal_title(@create_step, @provider_type)}
      </:title>
      <:body>
        <%= if @create_step == 1 do %>
          <p class="mb-4 text-base text-neutral-700">
            Select an authentication provider type to add:
          </p>
          <ul class="grid w-full gap-4 grid-cols-1">
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
                  Authenticate users against a Google account.
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
            <%= if @verified_at && Enum.any?(verification_errors(@form, @provider_type)) do %>
              <.flash kind={:error} class="mb-4">
                {verification_errors(@form, @provider_type)
                |> Enum.map(&elem(&1, 0))
                |> Enum.join(", ")}
              </.flash>
            <% end %>

            <div class="flex items-center justify-between">
              <div class="flex-1">
                <h3 class="text-base font-semibold text-neutral-900">Provider Verification</h3>
                <p class="mt-1 text-sm text-neutral-600">
                  Verify your provider configuration by signing in with your {capitalize_provider_type(
                    @provider_type
                  )} account.
                </p>
              </div>
              <div class="ml-4">
                <.verification_status_badge
                  ready_to_verify?={ready_to_verify?(@form)}
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
                  errors={[]}
                />
                <.reset_verification_button verified_at={@verified_at} />
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
                  errors={[]}
                />
                <.reset_verification_button verified_at={@verified_at} />
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
                <.reset_verification_button verified_at={@verified_at} />
              </div>
            <% end %>
            <%= if @provider_type == "oidc" do %>
              <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
                <.verification_field
                  label="Issuer"
                  value={@issuer}
                  verified?={@verified_at != nil}
                  errors={[]}
                />
                <.reset_verification_button verified_at={@verified_at} />
              </div>
            <% end %>
          </div>
        <% end %>
      </:body>
      <:back_button :if={@create_step == 2}>
        Back
      </:back_button>
      <:confirm_button
        form={if @create_step == 2, do: "auth-provider-form"}
        type={if @create_step == 2, do: "submit", else: "button"}
      >
        {modal_confirm_button_text(@create_step)}
      </:confirm_button>
    </.modal>

    <.modal
      :if={@live_action == :new_directory}
      id="new-directory-modal"
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
        okta_domain: nil,
        client_id: nil,
        client_secret: nil,
        discovery_document_uri: nil
      )
      |> push_patch(to: ~p"/#{socket.assigns.account}/settings/identity_providers")

    {:noreply, socket}
  end

  def handle_event("select_provider_type", %{"provider_type" => "google"}, socket) do
    socket = assign(socket, provider_type: "google")
    changeset = changeset(%{}, socket)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("select_provider_type", %{"provider_type" => "entra"}, socket) do
    socket = assign(socket, provider_type: "entra")
    changeset = changeset(%{}, socket)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("select_provider_type", %{"provider_type" => "okta"}, socket) do
    socket = assign(socket, provider_type: "okta")
    changeset = changeset(%{}, socket)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("select_provider_type", %{"provider_type" => "oidc"}, socket) do
    socket = assign(socket, provider_type: "oidc")
    changeset = changeset(%{}, socket)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("validate", %{"auth_provider" => attrs}, socket) do
    portal_only? = attrs["context"] == "portal_only"

    changeset =
      attrs
      |> Map.update("is_default", nil, fn value -> if portal_only?, do: false, else: value end)
      |> changeset(socket)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, portal_only?: portal_only?, form: to_form(changeset))}
  end

  def handle_event("update_context", %{"auth_provider" => %{"context" => context}}, socket) do
    {:noreply, assign(socket, portal_only?: context == "portal_only")}
  end

  def handle_event("start_verification", _params, socket) do
    changes = socket.assigns.form.source.changes
    type = socket.assigns.provider_type

    opts =
      if type in ["okta", "oidc"] do
        [
          discovery_document_uri: changes.discovery_document_uri,
          client_id: changes.client_id,
          client_secret: changes.client_secret
        ]
      else
        []
      end

    with {:ok, verification} <- Web.OIDC.setup_verification(type, opts) do
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
    else
      {:error, %Mint.TransportError{reason: reason}} ->
        field_name = if type == "okta", do: "Okta Domain", else: "Discovery Document URI"

        msg =
          "Failed to start verification: #{inspect(reason)}. Ensure the #{field_name} is correct."

        {:noreply, assign(socket, verification_error: msg)}

      {:error, %Jason.DecodeError{}} ->
        msg =
          "Failed to start verification: the Discovery Document URI did not return a valid JSON response."

        {:noreply, assign(socket, verification_error: msg)}

      {:error, reason} ->
        account_id = get_in(socket.assigns, [:subject, :account, :id])

        Logger.warning("Failed to start OIDC verification for #{account_id}",
          reason: inspect(reason)
        )

        msg = "An unexpected error occurred while starting verification. Please try again."
        {:noreply, assign(socket, verification_error: msg)}
    end
  end

  def handle_event("next_auth_provider", _params, socket) do
    {:noreply, assign(socket, create_step: 2)}
  end

  def handle_event("back_auth_provider", _params, socket) do
    socket =
      socket
      |> assign(
        create_step: 1,
        verification_token: nil,
        verification_error: nil,
        code_verifier: nil,
        provider_config: nil,
        verified_at: nil,
        provider_type: nil,
        portal_only?: false,
        verified_at: nil,
        issuer: nil,
        hosted_domain: nil,
        tenant_id: nil,
        okta_domain: nil,
        client_id: nil,
        client_secret: nil,
        discovery_document_uri: nil
      )

    {:noreply, assign(socket, create_step: 1, provider_type: nil, verified_at: nil)}
  end

  def handle_event("reset_verification", _params, socket) do
    socket =
      assign(socket,
        verified_at: nil,
        verification_token: nil,
        verification_error: nil,
        code_verifier: nil,
        provider_config: nil,
        issuer: nil,
        hosted_domain: nil,
        tenant_id: nil,
        okta_domain: nil
      )

    {:noreply, socket}
  end

  def handle_event("create_auth_provider", params, socket) do
    {:noreply, create_provider(params, socket)}
  end

  defp provider_selection_classes(selected?) do
    [
      "component bg-white rounded-lg p-4 flex items-center cursor-pointer",
      "border-2 transition-all duration-150",
      selected? && "border-accent-500 bg-accent-50 shadow-sm",
      !selected? &&
        "border-neutral-200 hover:border-accent-300 hover:bg-neutral-50 hover:shadow-sm"
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
  defp capitalize_provider_type("oidc"), do: "OpenID Connect"
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
    <div
      :if={not is_nil(@verified_at)}
      class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-md"
    >
      <.icon name="hero-check-circle" class="h-5 w-5 mr-2" />
      <span class="font-medium">Verified</span>
    </div>
    <.button
      :if={is_nil(@verified_at) and @ready_to_verify?}
      id="verify-button"
      style="primary"
      icon="hero-arrow-top-right-on-square"
      phx-click="start_verification"
      phx-hook="OpenURL"
    >
      Verify Now
    </.button>
    <.button
      :if={is_nil(@verified_at) and not @ready_to_verify?}
      style="primary"
      icon="hero-arrow-top-right-on-square"
      disabled
    >
      Verify Now
    </.button>
    """
  end

  # Reset verification button
  defp reset_verification_button(assigns) do
    ~H"""
    <div :if={@verified_at} class="text-right">
      <button
        type="button"
        phx-click="reset_verification"
        class="text-sm text-neutral-500 hover:text-neutral-700 underline"
        title="Reset verification to reverify credentials"
      >
        Reset verification
      </button>
    </div>
    """
  end

  # Collect verification field errors based on provider type
  defp verification_errors(form, provider_type) do
    case provider_type do
      "google" ->
        form[:hosted_domain].errors

      "entra" ->
        form[:tenant_id].errors

      _ ->
        []
    end
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
      "Configure your Google authentication provider. Users will sign in using their Google accounts."

  defp provider_form_description("entra"),
    do:
      "Configure your Microsoft Entra authentication provider. Users will sign in using their Microsoft Entra accounts."

  # Verification field component
  defp verification_field(assigns) do
    ~H"""
    <div class="flex justify-between items-center">
      <label class="text-sm font-medium text-neutral-700">{@label}</label>
      <div class="text-right">
        <p class="text-sm font-semibold text-neutral-900">
          {verification_field_display(@value, @verified?)}
        </p>
      </div>
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
    <.form
      id="auth-provider-form"
      for={@form}
      phx-change="validate"
      phx-submit="create_auth_provider"
    >
      <div class="space-y-4">
        <p class="text-base text-neutral-600">
          {@description}
        </p>

        <div>
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Enter a name to identify this provider. This will be shown to end-users during authentication.
          </p>
        </div>

        <div>
          <.input
            field={@form[:context]}
            type="select"
            label="Context"
            options={context_options()}
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Choose where this provider can be used for authentication
          </p>
        </div>

        <div>
          <.input
            field={@form[:is_default]}
            type="checkbox"
            label="Set as default provider"
            disabled={@portal_only?}
            class={@portal_only? && "cursor-not-allowed"}
          />
          <p class="mt-1 text-xs text-gray-500">
            {default_provider_helper_text(@portal_only?)}
          </p>
        </div>
      </div>
    </.form>
    """
  end

  defp auth_provider_form(%{type: "okta"} = assigns) do
    assigns = assign_new(assigns, :verified_at, fn -> nil end)

    ~H"""
    <.form
      id="auth-provider-form"
      for={@form}
      phx-change="validate"
      phx-submit="create_auth_provider"
    >
      <div class="space-y-4">
        <p class="text-base text-neutral-600">
          Configure your Okta authentication provider. Users will sign in using their Okta accounts.
        </p>

        <div>
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Enter a name to identify this provider. This will be shown to end-users during authentication.
          </p>
        </div>

        <div>
          <.input
            field={@form[:okta_domain]}
            type="text"
            label="Okta Domain"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Enter your fully-qualified Okta organization domain (e.g., example.okta.com).
          </p>
        </div>

        <div>
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Paste the Client ID from your Okta application settings.
          </p>
        </div>

        <div>
          <.input
            field={@form[:client_secret]}
            type="password"
            label="Client Secret"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Paste the Client Secret from your Okta application settings.
          </p>
        </div>

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
            Choose where this provider can be used for authentication.
          </p>
        </div>

        <div>
          <.input
            field={@form[:is_default]}
            type="checkbox"
            label="Set as default provider"
            disabled={@portal_only?}
            class={@portal_only? && "cursor-not-allowed"}
          />
          <p class="mt-1 text-xs text-gray-500">
            {default_provider_helper_text(@portal_only?)}
          </p>
        </div>
      </div>
    </.form>
    """
  end

  defp auth_provider_form(%{type: "oidc"} = assigns) do
    assigns = assign_new(assigns, :verified_at, fn -> nil end)

    ~H"""
    <.form
      id="auth-provider-form"
      for={@form}
      phx-change="validate"
      phx-submit="create_auth_provider"
    >
      <div class="space-y-4">
        <p class="text-base text-neutral-600">
          Configure your OpenID Connect authentication provider. Users will sign in using an OpenID Connect compliant identity provider.
        </p>

        <div>
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Enter a name to identify this provider. This will be shown to end-users during authentication.
          </p>
        </div>

        <div>
          <.input
            field={@form[:discovery_document_uri]}
            type="text"
            label="Discovery Document URI"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Enter the OpenID Connect discovery document URI (e.g., https://example.com/.well-known/openid-configuration).
          </p>
        </div>

        <div>
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Paste the Client ID from your OpenID Connect application settings.
          </p>
        </div>

        <div>
          <.input
            field={@form[:client_secret]}
            type="password"
            label="Client Secret"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-gray-500">
            Paste the Client Secret from your OpenID Connect application settings.
          </p>
        </div>

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
            Choose where this provider can be used for authentication.
          </p>
        </div>

        <div>
          <.input
            field={@form[:is_default]}
            type="checkbox"
            label="Set as default provider"
            disabled={@portal_only?}
            class={@portal_only? && "cursor-not-allowed"}
          />
          <p class="mt-1 text-xs text-gray-500">
            {default_provider_helper_text(@portal_only?)}
          </p>
        </div>
      </div>
    </.form>
    """
  end

  defp create_provider(
         %{"auth_provider" => attrs},
         %{assigns: %{provider_type: provider_type}} = socket
       ) do
    # Add provider-specific verification fields
    attrs =
      attrs
      |> Map.put("issuer", socket.assigns.issuer)
      |> Map.put("verified_at", socket.assigns.verified_at)
      |> add_provider_specific_attrs(provider_type, socket)

    # Call the appropriate domain function
    result =
      case provider_type do
        "google" -> Domain.Google.create_auth_provider(attrs, socket.assigns.subject)
        "entra" -> Domain.Entra.create_auth_provider(attrs, socket.assigns.subject)
        "okta" -> Domain.Okta.create_auth_provider(attrs, socket.assigns.subject)
        "oidc" -> Domain.OIDC.create_auth_provider(attrs, socket.assigns.subject)
      end

    case result do
      {:ok, provider} ->
        socket
        |> put_flash(:info, "#{provider.name} created successfully")
        |> push_patch(to: ~p"/#{socket.assigns.account}/settings/identity_providers")

      {:error, changeset} ->
        assign(socket, form: to_form(changeset))
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
    |> Map.put("okta_domain", socket.assigns.org_domain)
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

  defp changeset(attrs, %{assigns: %{provider_type: "google"}} = socket) do
    attrs =
      attrs
      |> Map.put_new("hosted_domain", socket.assigns.hosted_domain)
      |> Map.put_new("issuer", socket.assigns.issuer)

    Google.AuthProvider.Changeset.create(%Google.AuthProvider{}, attrs, socket.assigns.subject)
  end

  defp changeset(attrs, %{assigns: %{provider_type: "entra"}} = socket) do
    attrs =
      attrs
      |> Map.put_new("tenant_id", socket.assigns.tenant_id)
      |> Map.put_new("issuer", socket.assigns.issuer)

    Entra.AuthProvider.Changeset.create(%Entra.AuthProvider{}, attrs, socket.assigns.subject)
  end

  defp changeset(attrs, %{assigns: %{provider_type: "okta"}} = socket) do
    attrs =
      attrs
      |> Map.put_new("issuer", socket.assigns.issuer)

    Okta.AuthProvider.Changeset.create(%Okta.AuthProvider{}, attrs, socket.assigns.subject)
  end

  defp changeset(attrs, %{assigns: %{provider_type: "oidc"}} = socket) do
    attrs =
      attrs
      |> Map.put_new("issuer", socket.assigns.issuer)

    OIDC.AuthProvider.Changeset.create(%OIDC.AuthProvider{}, attrs, socket.assigns.subject)
  end

  defp ready_to_verify?(form) do
    Enum.all?(form.source.errors, fn
      # We'll set these fields during verification
      {excluded, _errors} when excluded in [:verified_at, :issuer, :tenant_id] -> true
      {_field, _errors} -> false
    end)
  end
end
