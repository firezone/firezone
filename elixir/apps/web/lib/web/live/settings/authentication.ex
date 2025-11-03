defmodule Web.Settings.Authentication do
  use Web, :live_view

  alias Domain.{
    AuthProviders,
    EmailOTP,
    Userpass,
    OIDC,
    Entra,
    Google,
    Okta,
    Safe
  }

  import Ecto.Changeset

  require Logger

  @context_options [
    {"Client Applications and Admin Portal", "clients_and_portal"},
    {"Client Applications Only", "clients_only"},
    {"Admin Portal Only", "portal_only"}
  ]

  @select_type_classes ~w[
    component bg-white rounded-lg p-4 flex items-center cursor-pointer
    border-2 transition-all duration-150
    border-neutral-200 hover:border-accent-300 hover:bg-neutral-50 hover:shadow-sm
  ]

  @new_types ~w[google entra okta oidc]
  @edit_types @new_types ++ ~w[userpass email_otp]

  @common_fields ~w[name context is_disabled issuer]a

  @fields %{
    EmailOTP.AuthProvider => @common_fields,
    Userpass.AuthProvider => @common_fields,
    Google.AuthProvider => @common_fields ++ ~w[hosted_domain is_verified]a,
    Entra.AuthProvider => @common_fields ++ ~w[tenant_id is_verified]a,
    Okta.AuthProvider => @common_fields ++ ~w[okta_domain client_id client_secret is_verified]a,
    OIDC.AuthProvider =>
      @common_fields ++ ~w[discovery_document_uri client_id client_secret is_verified]a
  }

  def mount(_params, _session, socket) do
    {:ok, init(socket)}
  end

  # New Auth Provider
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @new_types do
    schema = AuthProviders.AuthProvider.module!(type)
    struct = struct(schema)
    attrs = %{id: Ecto.UUID.generate()}
    changeset = changeset(struct, attrs, socket)

    {:noreply, assign(socket, type: type, form: to_form(changeset))}
  end

  # Edit Auth Provider
  def handle_params(
        %{"type" => type, "id" => id},
        _url,
        %{assigns: %{live_action: :edit}} = socket
      )
      when type in @edit_types do
    schema = AuthProviders.AuthProvider.module!(type)
    provider = get_provider!(schema, id, socket.assigns.subject)
    changeset = changeset(provider, %{is_verified: true}, socket)

    {:noreply, assign(socket, provider_name: provider.name, type: type, form: to_form(changeset))}
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
      |> apply_changes()
      |> changeset(attrs, socket)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("start_verification", _params, socket) do
    changeset = socket.assigns.form.source
    type = socket.assigns.type

    # Get values from changes (if modified) or from data (if not modified yet)
    opts =
      if type in ["okta", "oidc"] do
        [
          discovery_document_uri: get_field(changeset, :discovery_document_uri),
          client_id: get_field(changeset, :client_id),
          client_secret: get_field(changeset, :client_secret)
        ]
      else
        []
      end

    with {:ok, verification} <- Web.OIDC.setup_verification(type, opts) do
      # Subscribe to verification PubSub topic if connected
      # For Entra, use "entra-verification:" topic; for others use "oidc-verification:"
      topic =
        if type == "entra" do
          "entra-verification:#{verification.token}"
        else
          "oidc-verification:#{verification.token}"
        end

      :ok = Domain.PubSub.subscribe(topic)

      socket = assign(socket, verification: verification)

      # Push JS to open verification URL in new tab
      {:noreply, push_event(socket, "open_url", %{url: verification.url})}
    else
      error ->
        field = if(type == "okta", do: :okta_domain, else: :discovery_document_uri)
        {:noreply, handle_verification_setup_error(error, field, socket)}
    end
  end

  def handle_event("reset_verification", _params, socket) do
    changeset =
      socket.assigns.form.source
      |> delete_change(:is_verified)
      |> delete_change(:issuer)
      |> delete_change(:hosted_domain)
      |> delete_change(:tenant_id)
      |> apply_changes()
      |> changeset(
        %{
          "is_verified" => false,
          "issuer" => nil,
          "hosted_domain" => nil,
          "tenant_id" => nil
        },
        socket
      )

    {:noreply, assign(socket, verification_error: nil, form: to_form(changeset))}
  end

  def handle_event("submit_provider", _params, socket) do
    submit_provider(socket)
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    provider = socket.assigns.providers |> Enum.find(fn p -> p.id == id end)

    case delete_provider(provider, socket.assigns.subject) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:info, "Authentication provider deleted successfully.")
         |> push_patch(to: ~p"/#{socket.assigns.account}/settings/authentication")}

      {:error, reason} ->
        Logger.error("Failed to delete authentication provider: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to delete authentication provider.")}
    end
  end

  def handle_event("toggle_provider", %{"id" => id}, socket) do
    provider = socket.assigns.providers |> Enum.find(fn p -> p.id == id end)
    new_disabled_state = not provider.is_disabled

    changeset =
      provider
      |> Ecto.Changeset.change(is_disabled: new_disabled_state)

    case Safe.scoped(socket.assigns.subject) |> Safe.update(changeset) do
      {:ok, _provider} ->
        action = if new_disabled_state, do: "disabled", else: "enabled"

        {:noreply,
         socket
         |> init()
         |> put_flash(:info, "Authentication provider #{action} successfully.")}

      {:error, reason} ->
        Logger.error("Failed to toggle authentication provider: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to update authentication provider.")}
    end
  end

  # Sent by the Entra admin consent verification process from another browser tab
  def handle_info({:entra_verification, pid, issuer, tenant_id, state_token}, socket) do
    :ok = Domain.PubSub.unsubscribe("entra-verification:#{state_token}")

    stored_token = socket.assigns.verification.token

    # Verify the state token matches
    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      send(pid, :success)

      attrs = %{
        "is_verified" => true,
        "issuer" => issuer,
        "tenant_id" => tenant_id
      }

      changeset =
        socket.assigns.form.source
        |> apply_changes()
        |> changeset(attrs, socket)

      {:noreply, assign(socket, form: to_form(changeset))}
    else
      send(pid, {:error, :token_mismatch})
      {:noreply, socket}
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
            |> apply_changes()
            |> changeset(attrs, socket)

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
    fields = [:client_id, :client_secret, :discovery_document_uri, :okta_domain]

    if Enum.any?(fields, &get_change(changeset, &1)) do
      put_change(changeset, :is_verified, false)
    else
      changeset
    end
  end

  defp init(socket) do
    subject = socket.assigns.subject

    providers =
      [
        Safe.scoped(subject) |> Safe.all(EmailOTP.AuthProvider),
        Safe.scoped(subject) |> Safe.all(Userpass.AuthProvider),
        Safe.scoped(subject) |> Safe.all(Google.AuthProvider),
        Safe.scoped(subject) |> Safe.all(Entra.AuthProvider),
        Safe.scoped(subject) |> Safe.all(Okta.AuthProvider),
        Safe.scoped(subject) |> Safe.all(OIDC.AuthProvider)
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
        <div class="flex flex-wrap gap-4">
          <%= for provider <- @providers do %>
            <.provider_card type={provider_type(provider)} account={@account} provider={provider} />
          <% end %>
        </div>
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

  defp context_icon(:clients_and_portal), do: "hero-globe-alt"
  defp context_icon(:portal_only), do: "hero-window"
  defp context_icon(:clients_only), do: "hero-device-phone-mobile"

  defp context_title(:clients_and_portal),
    do: "Available for both client applications and admin portal"

  defp context_title(:portal_only), do: "Available only for admin portal sign-in"
  defp context_title(:clients_only), do: "Available only for client applications"

  defp provider_card(assigns) do
    ~H"""
    <div class="flex flex-col bg-neutral-50 rounded-lg p-4 w-96">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center flex-1 min-w-0">
          <.provider_icon type={@type} class="w-7 h-7 mr-2 flex-shrink-0" />
          <span class="font-normal text-lg truncate" title={@provider.name}>
            {@provider.name}
          </span>
        </div>
        <div class="flex items-center">
          <.button_with_confirmation
            id={"toggle-provider-#{@provider.id}"}
            on_confirm="toggle_provider"
            on_confirm_id={@provider.id}
            class="p-0 border-0 bg-transparent shadow-none hover:bg-transparent"
          >
            <.toggle
              id={"provider-toggle-#{@provider.id}"}
              checked={not @provider.is_disabled}
            />
            <:dialog_title>
              {if @provider.is_disabled, do: "Enable", else: "Disable"} Authentication Provider
            </:dialog_title>
            <:dialog_content>
              <p>
                Are you sure you want to {if @provider.is_disabled, do: "enable", else: "disable"} <strong>{@provider.name}</strong>?
              </p>
              <%= if not @provider.is_disabled do %>
                <p class="mt-2">
                  Users will not be able to sign in using this provider while it is disabled.
                </p>
              <% end %>
            </:dialog_content>
            <:dialog_confirm_button>
              {if @provider.is_disabled, do: "Enable", else: "Disable"}
            </:dialog_confirm_button>
            <:dialog_cancel_button>Cancel</:dialog_cancel_button>
          </.button_with_confirmation>
          <.popover placement="bottom" trigger="click">
            <:target>
              <button
                type="button"
                class="p-1 text-neutral-500 hover:text-neutral-700 rounded"
              >
                <.icon name="hero-ellipsis-horizontal" class="text-neutral-800 w-5 h-5" />
              </button>
            </:target>
            <:content>
              <div class="flex flex-col py-1">
                <.link
                  patch={~p"/#{@account}/settings/authentication/#{@type}/#{@provider.id}/edit"}
                  class="px-4 py-2 text-sm text-neutral-800 rounded-lg hover:bg-neutral-100 flex items-center gap-2"
                >
                  <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                </.link>
                <.button_with_confirmation
                  :if={@type not in ["email_otp", "userpass"]}
                  id={"delete-provider-#{@provider.id}"}
                  on_confirm="delete_provider"
                  on_confirm_id={@provider.id}
                  class="w-full px-4 py-2 text-sm text-red-600 rounded-lg flex items-center gap-2 text-left border-0 bg-transparent"
                >
                  <.icon name="hero-trash" class="w-4 h-4" /> Delete
                  <:dialog_title>Delete Authentication Provider</:dialog_title>
                  <:dialog_content>
                    Are you sure you want to delete <strong>{@provider.name}</strong>?
                    This action cannot be undone.
                  </:dialog_content>
                  <:dialog_confirm_button>Delete</:dialog_confirm_button>
                  <:dialog_cancel_button>Cancel</:dialog_cancel_button>
                </.button_with_confirmation>
              </div>
            </:content>
          </.popover>
        </div>
      </div>

      <div class="mt-auto bg-white rounded-lg p-3 space-y-3 text-sm text-neutral-600">
        <div :if={Map.get(@provider, :issuer)} class="flex items-center gap-2 min-w-0">
          <.icon name="hero-identification" class="w-5 h-5 flex-shrink-0" title="Issuer" />
          <span class="truncate font-medium" title={@provider.issuer}>{@provider.issuer}</span>
        </div>

        <div class="flex items-center gap-2" title={context_title(@provider.context)}>
          <.icon name={context_icon(@provider.context)} class="w-5 h-5" />
          <span class="font-medium">{Phoenix.Naming.humanize(@provider.context)}</span>
        </div>

        <div class="flex items-center gap-2">
          <.icon name="hero-clock" class="w-5 h-5" />
          <span class="font-medium">
            updated <.relative_datetime datetime={@provider.updated_at} />
          </span>
        </div>
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
    if get_field(changeset, :is_verified) do
      val = get_field(changeset, field)

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

  defp submit_provider(%{assigns: %{live_action: :new, form: %{source: changeset}}} = socket) do
    Safe.scoped(socket.assigns.subject)
    |> Safe.insert(changeset)
    |> handle_submit(socket)
  end

  defp submit_provider(%{assigns: %{live_action: :edit, form: %{source: changeset}}} = socket) do
    Safe.scoped(socket.assigns.subject)
    |> Safe.update(changeset)
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

  defp maybe_initialize_with_parent(changeset, account_id) do
    if is_nil(get_field(changeset, :id)) do
      id = Ecto.UUID.generate()

      changeset
      |> put_change(:id, id)
      |> put_assoc(:auth_provider, %AuthProviders.AuthProvider{id: id, account_id: account_id})
    else
      changeset
    end
  end

  defp changeset(struct, attrs, socket) do
    schema = struct.__struct__
    changeset = cast(struct, attrs, Map.get(@fields, schema))

    changeset
    |> maybe_initialize_with_parent(socket.assigns.subject.account.id)
    |> schema.changeset()
  end

  defp get_provider!(schema, id, subject) do
    import Ecto.Query

    query = from(p in schema, where: p.id == ^id)
    Safe.scoped(subject) |> Safe.one!(query)
  end

  defp delete_provider(provider, subject) do
    Safe.scoped(subject) |> Safe.delete(provider)
  end

  defp verified?(form) do
    get_field(form.source, :is_verified) == true
  end

  defp handle_verification_setup_error(
         {:error, %Mint.TransportError{reason: reason}},
         field,
         socket
       ) do
    msg = "Failed to start verification: #{inspect(reason)}."
    add_verification_error(msg, field, socket)
  end

  defp handle_verification_setup_error({:error, %Jason.DecodeError{}}, field, socket) do
    msg =
      "Failed to start verification: the Discovery Document URI did not return a valid JSON response."

    add_verification_error(msg, field, socket)
  end

  defp handle_verification_setup_error({:error, :invalid_discovery_document_uri}, field, socket) do
    msg = "Failed to start verification: the Discovery Document URI is invalid."
    add_verification_error(msg, field, socket)
  end

  defp handle_verification_setup_error({:error, reason}, field, socket) do
    Logger.warning(
      "Unexpected error during OIDC verification setup",
      subject: socket.assigns.subject,
      reason: reason
    )

    msg = "Failed to start verification: An unexpected error occurred."
    add_verification_error(msg, field, socket)
  end

  defp add_verification_error(msg, field, socket) do
    changeset = add_error(socket.assigns.form.source, field, msg)
    assign(socket, form: to_form(changeset))
  end

  defp provider_type(module) do
    AuthProviders.AuthProvider.type!(module.__struct__)
  end
end
