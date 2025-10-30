defmodule Web.Settings.Authentication do
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

  @okta_verification_trigger_fields ~w[okta_domain client_id client_secret]a
  @oidc_verification_trigger_fields ~w[discovery_document_uri client_id client_secret]a

  @select_type_classes ~w[
    component bg-white rounded-lg p-4 flex items-center cursor-pointer
    border-2 transition-all duration-150
    border-neutral-200 hover:border-accent-300 hover:bg-neutral-50 hover:shadow-sm
  ]

  @new_types ~w[google entra okta oidc]
  @edit_types @new_types ++ ~w[userpass email_otp]

  def mount(_params, _session, socket) do
    {:ok, init(socket)}
  end

  # New Auth Provider
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @new_types do
    changeset =
      type
      |> type_provider()
      |> changeset(socket, %{is_verified: false})

    {:noreply, assign(socket, type: type, form: to_form(changeset))}
  end

  # Edit Auth Provider
  def handle_params(
        %{"type" => type, "id" => id},
        _url,
        %{assigns: %{live_action: :edit}} = socket
      )
      when type in @edit_types do
    with {:ok, provider} <- fetch_provider(type, id, socket.assigns.subject) do
      changeset = changeset(provider, socket, %{})

      {:noreply,
       assign(socket, provider_name: provider.name, type: type, form: to_form(changeset))}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  # Unknown Provider Type
  def handle_params(%{"type" => _type}, _url, _socket) do
    raise Web.LiveErrors.NotFoundError
  end

  # Default handler
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/authentication")}
  end

  def handle_event("validate", %{"auth_provider" => attrs}, socket) do
    changeset =
      socket.assigns.form.source
      |> clear_verification_if_trigger_fields_changed()
      |> Ecto.Changeset.apply_changes()
      |> changeset(socket, attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("start_verification", _params, socket) do
    changeset = socket.assigns.form.source
    type = socket.assigns.type

    # Get values from changes (if modified) or from data (if not modified yet)
    opts =
      if type in ["okta", "idc"] do
        [
          discovery_document_uri: Ecto.Changeset.get_field(changeset, :discovery_document_uri),
          client_id: Ecto.Changeset.get_field(changeset, :client_id),
          client_secret: Ecto.Changeset.get_field(changeset, :client_secret)
        ]
      else
        []
      end

    with {:ok, verification} <- Web.OIDC.setup_verification(type, opts) do
      # Subscribe to verification PubSub topic if connected
      Domain.PubSub.subscribe("oidc-verification:#{verification}")

      socket = assign(socket, verification: verification)

      # Push JS to open verification URL in new tab
      {:noreply, push_event(socket, "open_url", %{url: verification.url})}
    else
      error ->
        field = if(type == "okta", do: :okta_domain, else: :discovery_document_uri)
        handle_verification_setup_error(error, field, socket)
    end
  end

  def handle_event("reset_verification", _params, socket) do
    changeset =
      socket.assigns.form.source
      |> Ecto.Changeset.delete_change(:is_verified)
      |> Ecto.Changeset.delete_change(:issuer)
      |> Ecto.Changeset.delete_change(:hosted_domain)
      |> Ecto.Changeset.delete_change(:tenant_id)
      |> Ecto.Changeset.apply_changes()
      |> changeset(socket, %{
        "is_verified" => false,
        "issuer" => nil,
        "hosted_domain" => nil,
        "tenant_id" => nil
      })

    {:noreply, assign(socket, verification_error: nil, form: to_form(changeset))}
  end

  def handle_event("submit_provider", _params, socket) do
    submit_provider(socket)
  end

  def handle_event("delete_provider", %{"id" => composite_id}, socket) do
    # Split composite ID "type:id"
    [type, id] = String.split(composite_id, ":", parts: 2)

    case delete_provider(type, id, socket.assigns.subject) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:info, "Authentication provider deleted successfully.")
         |> push_patch(to: ~p"/#{socket.assigns.account}/settings/authentication")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete authentication provider.")}
    end
  end

  # Sent by the OIDC verification process from another browser tab
  def handle_info({:oidc_verify, pid, code, state_token}, socket) do
    :ok = Domain.PubSub.unsubscribe("oidc-verification:#{state_token}")

    stored_token = socket.assigns.verification.token

    # Verify the state token matches
    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      code_verifier = socket.assigns.verification.verifier
      config = socket.assigns.verification.config

      case Web.OIDC.verify_callback(config, code, code_verifier) do
        {:ok, claims} ->
          send(pid, :success)

          attrs = %{
            "is_verified" => true,
            "issuer" => claims["iss"],
            "hosted_domain" => claims["hd"],
            "tenant_id" => claims["tid"]
          }

          changeset =
            socket.assigns.form.source
            |> Ecto.Changeset.apply_changes()
            |> changeset(socket, attrs)

          {:noreply, assign(socket, form: to_form(changeset))}

        {:error, reason} ->
          send(pid, {:error, reason})
          error = "Failed to verify provider: #{inspect(reason)}"
          {:noreply, assign(socket, verification_error: error)}
      end
    else
      send(pid, {:error, :token_mismatch})
      error = "Failed to verify provider: token mismatch"
      {:noreply, assign(socket, verification_error: error)}
    end
  end

  defp clear_verification_if_trigger_fields_changed(changeset) do
    if Enum.any?(verification_trigger_fields(changeset), fn field ->
         Map.has_key?(changeset.changes, field)
       end) do
      changeset
      |> Ecto.Changeset.put_change(:is_verified, false)
      |> Ecto.Changeset.put_change(:issuer, nil)
      |> Ecto.Changeset.put_change(:hosted_domain, nil)
      |> Ecto.Changeset.put_change(:tenant_id, nil)
    else
      changeset
    end
  end

  defp init(socket) do
    account = socket.assigns.subject.account

    providers =
      [
        EmailOTP.all_auth_providers_for_account!(account),
        Userpass.all_auth_providers_for_account!(account),
        Google.all_auth_providers_for_account!(account),
        Entra.all_auth_providers_for_account!(account),
        Okta.all_auth_providers_for_account!(account),
        OIDC.all_auth_providers_for_account!(account)
      ]
      |> List.flatten()

    assign(socket, providers: providers, verification_error: nil)
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/authentication"}>
        Authentication Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>Authentication Providers</:title>
      <:action><.docs_action path="/guides/settings/authentication" /></:action>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/authentication/select_type"}>
          Add Provider
        </.add_button>
      </:action>
      <:help>
        Authentication providers authenticate your users with an external source.
      </:help>
      <:content>
        <.flash_group flash={@flash} />
      </:content>
      <:content>
        <%= for provider <- @providers do %>
          <.provider_card type={provider_type(provider)} account={@account} provider={provider} />
        <% end %>
      </:content>
    </.section>

    <!-- Select Provider Type Modal -->
    <.modal :if={@live_action == :select_type} id="select-provider-type-modal" on_close="close_modal">
      <:title>Select Provider Type</:title>
      <:body>
        <p class="mb-4 text-base text-neutral-700">
          Select an authentication provider type to add:
        </p>
        <ul class="grid w-full gap-4 grid-cols-1">
          <li>
            <.link
              patch={~p"/#{@account}/settings/authentication/google/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="google" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium"> Google </span>
              </span>
              <span class="w-2/3"> Authenticate users against a Google account. </span>
            </.link>
          </li>
          <li>
            <.link
              patch={~p"/#{@account}/settings/authentication/entra/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="entra" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium"> Entra </span>
              </span>
              <span class="w-2/3"> Authenticate users against a Microsoft Entra account. </span>
            </.link>
          </li>
          <li>
            <.link
              patch={~p"/#{@account}/settings/authentication/okta/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="okta" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium">Okta</span>
              </span>
              <span class="w-2/3">Authenticate users against an Okta account. </span>
            </.link>
          </li>
          <li>
            <.link
              patch={~p"/#{@account}/settings/authentication/oidc/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="oidc" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium">OIDC</span>
              </span>
              <span class="w-2/3">
                Authenticate users against any OpenID Connect compliant identity provider.
              </span>
            </.link>
          </li>
        </ul>
      </:body>
    </.modal>

    <!-- New Auth Provider Modal -->
    <.modal
      :if={@live_action == :new}
      id="new-auth-provider-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid?}
    >
      <:title icon={@type}>Add {titleize(@type)} Provider</:title>
      <:body>
        <.provider_form
          verification_error={@verification_error}
          form={@form}
          type={@type}
          submit_event="submit_provider"
        />
      </:body>
      <:confirm_button form="auth-provider-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Edit Auth Provider Modal -->
    <.modal
      :if={@live_action == :edit}
      id="edit-auth-provider-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid? or Enum.empty?(@form.source.changes)}
    >
      <:title icon={@type}>Edit {@provider_name}</:title>
      <:body>
        <.provider_form
          verification_error={@verification_error}
          form={@form}
          type={@type}
          submit_event="submit_provider"
        />
      </:body>
      <:confirm_button
        form="auth-provider-form"
        type="submit"
      >
        Save
      </:confirm_button>
    </.modal>
    """
  end

  defp verification_trigger_fields(%Ecto.Changeset{data: %Okta.AuthProvider{}}),
    do: @okta_verification_trigger_fields

  defp verification_trigger_fields(%Ecto.Changeset{data: %OIDC.AuthProvider{}}),
    do: @oidc_verification_trigger_fields

  defp verification_trigger_fields(_), do: []

  defp provider_card(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@provider.name}</span>
      <div class="flex gap-2">
        <.button
          size="xs"
          icon="hero-pencil"
          patch={~p"/#{@account}/settings/authentication/#{@type}/#{@provider.id}/edit"}
        >
          Edit
        </.button>
        <.button_with_confirmation
          :if={@type not in ["email_otp", "userpass"]}
          id={"delete-provider-#{@provider.id}"}
          size="xs"
          style="danger"
          icon="hero-trash"
          on_confirm="delete_provider"
          on_confirm_id={"#{@type}:#{@provider.id}"}
        >
          Delete
          <:dialog_title>Delete Authentication Provider</:dialog_title>
          <:dialog_content>
            Are you sure you want to delete <strong>{@provider.name}</strong>?
            This action cannot be undone.
          </:dialog_content>
          <:dialog_confirm_button>Delete</:dialog_confirm_button>
          <:dialog_cancel_button>Cancel</:dialog_cancel_button>
        </.button_with_confirmation>
      </div>
    </div>
    """
  end

  defp provider_form(assigns) do
    ~H"""
    <.form
      id="auth-provider-form"
      for={@form}
      phx-change="validate"
      phx-submit={@submit_event}
    >
      <div class="space-y-6">
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
          <p class="mt-1 text-xs text-neutral-600">
            Enter a name to identify this provider. This will be shown to end-users during authentication.
          </p>
        </div>

        <div :if={@type == "okta"}>
          <.input
            field={@form[:okta_domain]}
            type="text"
            label="Okta Domain"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter your fully-qualified Okta organization domain (e.g., example.okta.com).
          </p>
        </div>

        <div :if={@type == "oidc"}>
          <.input
            field={@form[:discovery_document_uri]}
            type="text"
            label="Discovery Document URI"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter the OpenID Connect discovery document URI (e.g., https://example.com/.well-known/openid-configuration).
          </p>
        </div>

        <div :if={@type in ["okta", "oidc"]}>
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter the Client ID from your {titleize(@type)} application settings.
          </p>
        </div>

        <div :if={@type in ["okta", "oidc"]}>
          <.input
            field={@form[:client_secret]}
            type="password"
            label="Client Secret"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter the Client Secret from your {titleize(@type)} application settings.
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
          <p class="mt-1 text-xs text-neutral-600">
            Choose where this provider can be used for authentication.
          </p>
        </div>

        <div
          :if={@type in ["entra", "google", "okta", "oidc"]}
          class="p-4 border-2 border-accent-200 bg-accent-50 rounded-lg"
        >
          <.flash :if={@verification_error} kind={:error}>
            {@verification_error}
          </.flash>
          <div class="flex items-center justify-between">
            <div class="flex-1">
              <h3 class="text-base font-semibold text-neutral-900">Provider Verification</h3>
              <p class="mt-1 text-sm text-neutral-600">
                {verification_help_text(@form, @type)}
              </p>
            </div>
            <div class="ml-4">
              <.verification_status_badge id="verify-button" form={@form} />
            </div>
          </div>

          <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
            <.verification_fields_status type={@type} form={@form} />
            <.reset_verification_button form={@form} />
          </div>
        </div>
      </div>
    </.form>
    """
  end

  defp verification_help_text(form, type) do
    if verified?(form) do
      "This provider has been successfully verified."
    else
      "Verify your provider configuration by signing in with your #{titleize(type)} account."
    end
  end

  # Verification status badge
  defp verification_status_badge(assigns) do
    ~H"""
    <div
      :if={verified?(@form)}
      class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-md"
    >
      <.icon name="hero-check-circle" class="h-5 w-5 mr-2" />
      <span class="font-medium">Verified</span>
    </div>
    <.button
      :if={not verified?(@form) and ready_to_verify?(@form)}
      type="button"
      id="verify-button"
      style="primary"
      icon="hero-arrow-top-right-on-square"
      phx-click="start_verification"
      phx-hook="OpenURL"
    >
      Verify Now
    </.button>
    <.button
      :if={not verified?(@form) and not ready_to_verify?(@form)}
      type="button"
      style="primary"
      icon="hero-arrow-top-right-on-square"
      disabled
    >
      Verify Now
    </.button>
    """
  end

  # Verification fields status
  defp verification_fields_status(assigns) do
    fields =
      case assigns.type do
        "oidc" -> [:issuer]
        "okta" -> [:issuer]
        "google" -> [:issuer, :hosted_domain]
        "entra" -> [:issuer, :tenant_id]
      end

    assigns = assign(assigns, :fields, fields)

    ~H"""
    <%= for field <- @fields do %>
      <div class="flex justify-between items-center">
        <label class="text-sm font-medium text-neutral-700">{Phoenix.Naming.humanize(field)}</label>
        <div class="text-right">
          <p class="text-sm font-semibold text-neutral-900">
            {verification_field_display(@form.source, field)}
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  defp verification_field_display(changeset, field) do
    if Ecto.Changeset.get_field(changeset, :is_verified) do
      val = Ecto.Changeset.get_field(changeset, field)

      if field == :hosted_domain do
        if val == "" or is_nil(val), do: "Personal Gmail accounts only", else: val
      else
        val
      end
    else
      "Awaiting verification..."
    end
  end

  # Reset verification button
  defp reset_verification_button(assigns) do
    ~H"""
    <div :if={verified?(@form)} class="text-right">
      <button
        type="button"
        phx-click="reset_verification"
        class="text-sm text-neutral-600 hover:text-neutral-700 underline"
        title="Reset verification to reverify credentials"
      >
        Reset verification
      </button>
    </div>
    """
  end

  defp submit_provider(
         %{assigns: %{type: "google", live_action: :new, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :insert)
    |> Google.create_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "entra", live_action: :new, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :insert)
    |> Entra.create_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "okta", live_action: :new, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :insert)
    |> Okta.create_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "oidc", live_action: :new, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :insert)
    |> OIDC.create_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "google", live_action: :edit, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :update)
    |> Google.update_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "entra", live_action: :edit, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :update)
    |> Entra.update_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "okta", live_action: :edit, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :update)
    |> Okta.update_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "oidc", live_action: :edit, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :update)
    |> OIDC.update_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "email_otp", live_action: :edit, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :update)
    |> EmailOTP.update_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(
         %{assigns: %{type: "userpass", live_action: :edit, form: %{source: changeset}}} = socket
       ) do
    changeset
    |> Map.put(:action, :update)
    |> Userpass.update_auth_provider(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp handle_submit({:ok, _provider}, socket) do
    {:noreply,
     socket
     |> init()
     |> put_flash(:info, "Authentication provider saved successfully.")
     |> push_patch(to: ~p"/#{socket.assigns.account}/settings/authentication")}
  end

  defp handle_submit({:error, changeset}, socket) do
    verification_error = verification_errors(changeset)
    {:noreply, assign(socket, verification_error: verification_error, form: to_form(changeset))}
  end

  defp verification_errors(changeset) do
    changeset.errors
    |> Enum.filter(fn {field, _error} -> field in [:hosted_domain, :issuer, :tenant_id] end)
    |> Enum.map(fn {_field, {message, _opts}} -> message end)
    |> Enum.join(" ")
  end

  defp ready_to_verify?(form) do
    Enum.all?(form.source.errors, fn
      # We'll set these fields during verification
      {excluded, _errors} when excluded in [:is_verified, :issuer, :hosted_domain, :tenant_id] ->
        true

      {_field, _errors} ->
        false
    end)
  end

  defp context_options, do: @context_options

  defp select_type_classes, do: @select_type_classes

  defp titleize("google"), do: "Google"
  defp titleize("entra"), do: "Microsoft Entra"
  defp titleize("okta"), do: "Okta"
  defp titleize("oidc"), do: "OpenID Connect"
  defp titleize("email_otp"), do: "Email OTP"
  defp titleize("userpass"), do: "Username & Password"

  defp changeset(
         %Google.AuthProvider{} = provider,
         %{assigns: %{live_action: :new}} = socket,
         attrs
       ) do
    Google.AuthProvider.Changeset.create(provider, attrs, socket.assigns.subject)
  end

  defp changeset(
         %Entra.AuthProvider{} = provider,
         %{assigns: %{live_action: :new}} = socket,
         attrs
       ) do
    Entra.AuthProvider.Changeset.create(provider, attrs, socket.assigns.subject)
  end

  defp changeset(
         %Okta.AuthProvider{} = provider,
         %{assigns: %{live_action: :new}} = socket,
         attrs
       ) do
    Okta.AuthProvider.Changeset.create(provider, attrs, socket.assigns.subject)
  end

  defp changeset(
         %OIDC.AuthProvider{} = provider,
         %{assigns: %{live_action: :new}} = socket,
         attrs
       ) do
    OIDC.AuthProvider.Changeset.create(provider, attrs, socket.assigns.subject)
  end

  defp changeset(%Google.AuthProvider{} = provider, %{assigns: %{live_action: :edit}}, attrs) do
    Google.AuthProvider.Changeset.update(provider, attrs)
  end

  defp changeset(%Entra.AuthProvider{} = provider, %{assigns: %{live_action: :edit}}, attrs) do
    Entra.AuthProvider.Changeset.update(provider, attrs)
  end

  defp changeset(
         %Okta.AuthProvider{} = provider,
         %{assigns: %{live_action: :edit}},
         attrs
       ) do
    Okta.AuthProvider.Changeset.update(provider, attrs)
  end

  defp changeset(
         %OIDC.AuthProvider{} = provider,
         %{assigns: %{live_action: :edit}},
         attrs
       ) do
    OIDC.AuthProvider.Changeset.update(provider, attrs)
  end

  defp changeset(
         %EmailOTP.AuthProvider{} = provider,
         %{assigns: %{live_action: :edit}},
         attrs
       ) do
    EmailOTP.AuthProvider.Changeset.update(provider, attrs)
  end

  defp changeset(
         %Userpass.AuthProvider{} = provider,
         %{assigns: %{live_action: :edit}},
         attrs
       ) do
    Userpass.AuthProvider.Changeset.update(provider, attrs)
  end

  defp provider_type(%Google.AuthProvider{}), do: "google"
  defp provider_type(%Entra.AuthProvider{}), do: "entra"
  defp provider_type(%Okta.AuthProvider{}), do: "okta"
  defp provider_type(%OIDC.AuthProvider{}), do: "oidc"
  defp provider_type(%EmailOTP.AuthProvider{}), do: "email_otp"
  defp provider_type(%Userpass.AuthProvider{}), do: "userpass"
  defp type_provider("google"), do: %Google.AuthProvider{}
  defp type_provider("entra"), do: %Entra.AuthProvider{}
  defp type_provider("okta"), do: %Okta.AuthProvider{}
  defp type_provider("oidc"), do: %OIDC.AuthProvider{}

  defp fetch_provider("google", id, subject) do
    Google.fetch_auth_provider_by_id(id, subject)
  end

  defp fetch_provider("entra", id, subject) do
    Entra.fetch_auth_provider_by_id(id, subject)
  end

  defp fetch_provider("okta", id, subject) do
    Okta.fetch_auth_provider_by_id(id, subject)
  end

  defp fetch_provider("oidc", id, subject) do
    OIDC.fetch_auth_provider_by_id(id, subject)
  end

  defp fetch_provider("email_otp", id, subject) do
    EmailOTP.fetch_auth_provider_by_id(id, subject)
  end

  defp fetch_provider("userpass", id, subject) do
    Userpass.fetch_auth_provider_by_id(id, subject)
  end

  defp delete_provider("google", id, subject) do
    Google.delete_auth_provider_by_id(id, subject)
  end

  defp delete_provider("entra", id, subject) do
    Entra.delete_auth_provider_by_id(id, subject)
  end

  defp delete_provider("okta", id, subject) do
    Okta.delete_auth_provider_by_id(id, subject)
  end

  defp delete_provider("oidc", id, subject) do
    OIDC.delete_auth_provider_by_id(id, subject)
  end

  defp verified?(form) do
    Ecto.Changeset.get_field(form.source, :is_verified) == true
  end

  defp handle_verification_setup_error(
         {:error, %Mint.TransportError{reason: reason}},
         field,
         socket
       ) do
    msg = "Failed to start verification: #{inspect(reason)}."
    add_error(msg, field, socket)
  end

  defp handle_verification_setup_error({:error, %Jason.DecodeError{}}, field, socket) do
    msg =
      "Failed to start verification: the Discovery Document URI did not return a valid JSON response."

    add_error(msg, field, socket)
  end

  defp handle_verification_setup_error({:error, reason}, field, socket) do
    Logger.warning(
      "Unexpected error during OIDC verification setup",
      subject: socket.assigns.subject,
      reason: reason
    )

    msg = "Failed to start verification: An unexpected error occurred."
    add_error(msg, field, socket)
  end

  defp add_error(msg, field, socket) do
    changeset = Ecto.Changeset.add_error(socket.assigns.form.source, field, msg)
    assign(socket, form: to_form(changeset))
  end
end
