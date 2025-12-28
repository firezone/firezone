defmodule PortalWeb.Settings.Authentication do
  use PortalWeb, :live_view

  alias Portal.{
    AuthProvider,
    EmailOTP,
    Userpass,
    OIDC,
    Entra,
    Google,
    Okta
  }

  alias __MODULE__.DB

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

  @common_fields ~w[name context is_disabled issuer client_session_lifetime_secs portal_session_lifetime_secs]a

  @fields %{
    EmailOTP.AuthProvider => @common_fields,
    Userpass.AuthProvider => @common_fields,
    Google.AuthProvider => @common_fields ++ ~w[is_verified]a,
    Entra.AuthProvider => @common_fields ++ ~w[is_verified]a,
    Okta.AuthProvider => @common_fields ++ ~w[okta_domain client_id client_secret is_verified]a,
    OIDC.AuthProvider =>
      @common_fields ++ ~w[discovery_document_uri client_id client_secret is_verified is_legacy]a
  }

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Authentication")

    {:ok, init(socket)}
  end

  # New Auth Provider
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @new_types do
    schema = AuthProvider.module!(type)
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
    schema = AuthProvider.module!(type)
    provider = DB.get_provider!(schema, id, socket.assigns.subject)
    is_legacy = Map.get(provider, :is_legacy, false)

    # Legacy providers can't be verified (must be deleted and recreated)
    changeset = changeset(provider, %{is_verified: not is_legacy}, socket)

    {:noreply,
     assign(socket,
       provider_name: provider.name,
       type: type,
       form: to_form(changeset),
       is_legacy: is_legacy
     )}
  end

  # Default handler
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/authentication")}
  end

  def handle_event("validate", %{"auth_provider" => attrs}, socket) do
    # Get the original struct (the data field contains the original provider)
    original_struct = socket.assigns.form.source.data

    # Preserve is_verified and issuer from the current changeset
    # is_verified is virtual, issuer gets set during verification
    current_is_verified = get_field(socket.assigns.form.source, :is_verified)
    current_issuer = get_field(socket.assigns.form.source, :issuer)

    attrs =
      attrs
      |> Map.put("is_verified", current_is_verified)
      |> Map.put("issuer", current_issuer)

    changeset =
      original_struct
      |> changeset(attrs, socket)
      |> clear_verification_if_trigger_fields_changed()
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

    with {:ok, verification} <- PortalWeb.OIDC.setup_verification(type, opts) do
      # Subscribe to verification PubSub topic if connected
      # For Entra, use "entra-verification:" topic; for others use "oidc-verification:"
      topic =
        if type == "entra" do
          "entra-verification:#{verification.token}"
        else
          "oidc-verification:#{verification.token}"
        end

      :ok = Portal.PubSub.subscribe(topic)

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
      |> apply_changes()
      |> changeset(
        %{
          "is_verified" => false,
          "issuer" => nil
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

    # Load providers again to ensure we have the latest state
    socket = init(socket)

    if id == socket.assigns.subject.credential.auth_provider_id do
      {:noreply,
       put_flash(
         socket,
         :error,
         "You cannot delete the provider you are currently signed in with."
       )}
    else
      case DB.delete_provider!(provider, socket.assigns.subject) do
        {:ok, _provider} ->
          {:noreply,
           socket
           |> init()
           |> put_flash(:success, "Authentication provider deleted successfully.")
           |> push_patch(to: ~p"/#{socket.assigns.account}/settings/authentication")}

        {:error, reason} ->
          Logger.info("Failed to delete authentication provider", reason: reason)
          {:noreply, put_flash(socket, :error, "Failed to delete authentication provider.")}
      end
    end
  end

  def handle_event("toggle_provider", %{"id" => id}, socket) do
    provider = socket.assigns.providers |> Enum.find(fn p -> p.id == id end)
    new_disabled_state = not provider.is_disabled

    can_disable =
      id != socket.assigns.subject.credential.auth_provider_id or not new_disabled_state

    changeset =
      if can_disable do
        provider
        |> change(is_disabled: new_disabled_state)
        |> validate_not_disabling_default_provider()
      else
        provider
        |> change(is_disabled: new_disabled_state)
        |> add_error(
          :is_disabled,
          "You cannot disable the provider you are currently signed in with."
        )
      end

    case DB.update_provider(changeset, socket.assigns.subject) do
      {:ok, _provider} ->
        action = if new_disabled_state, do: "disabled", else: "enabled"

        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "Authentication provider #{action} successfully.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.info("Failed to toggle authentication provider",
          errors: inspect(changeset.errors),
          changes: inspect(changeset.changes)
        )

        error_message =
          case Keyword.get(changeset.errors, :is_disabled) do
            {msg, _} ->
              msg

            nil ->
              # Get the first error message if is_disabled is not the issue
              case changeset.errors do
                [{_field, {msg, _}} | _] -> msg
                [] -> "Failed to update authentication provider."
              end
          end

        {:noreply, put_flash(socket, :error, error_message)}

      {:error, reason} ->
        Logger.info("Failed to toggle authentication provider", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to update authentication provider.")}
    end
  end

  def handle_event("default_provider_change", _params, socket) do
    {:noreply, assign(socket, default_provider_changed: true)}
  end

  def handle_event("revoke_sessions", %{"id" => id}, socket) do
    provider = socket.assigns.providers |> Enum.find(fn p -> p.id == id end)

    case DB.revoke_sessions_for_provider(provider, socket.assigns.subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "All sessions for #{provider.name} have been revoked.")}

      {:error, reason} ->
        Logger.info("Failed to revoke sessions for provider", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to revoke sessions.")}
    end
  end

  def handle_event("default_provider_save", %{"provider_id" => ""}, socket) do
    clear_default_provider(socket)
  end

  def handle_event("default_provider_save", %{"provider_id" => provider_id}, socket) do
    assign_default_provider(provider_id, socket)
  end

  # Sent by the Entra admin consent verification process from another browser tab
  def handle_info({:entra_admin_consent, pid, issuer, _tenant_id, state_token}, socket) do
    :ok = Portal.PubSub.unsubscribe("entra-verification:#{state_token}")

    stored_token = socket.assigns.verification.token

    # Verify the state token matches
    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      send(pid, :success)

      attrs = %{
        "is_verified" => true,
        "issuer" => issuer
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
    :ok = Portal.PubSub.unsubscribe("oidc-verification:#{state_token}")

    stored_token = socket.assigns.verification.token

    # Verify the state token matches
    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      code_verifier = socket.assigns.verification.verifier
      config = socket.assigns.verification.config

      case PortalWeb.OIDC.verify_callback(config, code, code_verifier) do
        {:ok, claims} ->
          send(pid, :success)

          attrs = %{
            "is_verified" => true,
            "is_legacy" => false,
            "issuer" => claims["iss"]
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
    providers =
      DB.list_all_providers(socket.assigns.subject)
      |> DB.enrich_with_session_counts(socket.assigns.subject)

    assign(socket,
      providers: providers,
      verification_error: nil,
      default_provider_changed: false
    )
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
      <:action><.docs_action path="/authenticate" /></:action>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/authentication/select_type"}>
          Add Provider
        </.add_button>
      </:action>
      <:help>
        Authentication providers authenticate your users with an external source.
      </:help>
      <:content>
        <div class="pb-8 px-1">
          <div class="text-lg text-neutral-600 mb-4">
            Default Authentication Provider
          </div>
          <.default_provider_form
            providers={@providers}
            default_provider_changed={@default_provider_changed}
          />
        </div>

        <div class="text-lg text-neutral-600 mb-4 px-1">
          All Authentication Providers
        </div>
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
      <:title icon={@type}>
        Add {titleize(@type)} Provider <.docs_action path={"/authenticate/#{@type}"} />
      </:title>
      <:body>
        <.provider_form
          account_id={@account.id}
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
      confirm_disabled={
        not @form.source.valid? or Enum.empty?(@form.source.changes) or not verified?(@form)
      }
    >
      <:title icon={@type}>
        Edit {@provider_name} <.docs_action path={"/authenticate/#{@type}"} />
      </:title>
      <:body>
        <.flash :if={assigns[:is_legacy]} kind={:warning_inline}>
          This provider uses legacy configuration. We recommend setting up a new authentication provider
          for your identity service to take advantage of improved security and features.
        </.flash>
        <.provider_form
          account_id={@account.id}
          verification_error={@verification_error}
          form={@form}
          type={@type}
          submit_event="submit_provider"
          is_legacy={assigns[:is_legacy]}
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

  attr :providers, :list, required: true
  attr :default_provider_changed, :boolean, required: true

  defp default_provider_form(assigns) do
    options =
      assigns.providers
      |> Enum.filter(fn provider ->
        # Exclude email_otp and userpass from being default
        provider_type(provider) not in ["email_otp", "userpass"]
      end)
      |> Enum.map(fn provider ->
        {provider.name, provider.id}
      end)

    options = [{"None", ""} | options]

    value =
      case Enum.find(assigns.providers, fn provider ->
             # Only check is_default if the field exists (OIDC, Entra, etc.)
             Map.has_key?(provider, :is_default) && provider.is_default
           end) do
        nil -> ""
        provider -> provider.id
      end

    assigns = assign(assigns, options: options, value: value)

    ~H"""
    <.form
      id="default-provider-form"
      phx-submit="default_provider_save"
      phx-change="default_provider_change"
      for={nil}
    >
      <div class="flex gap-2 items-center">
        <.input
          id="default-provider-select"
          name="provider_id"
          type="select"
          options={@options}
          value={@value}
        />
        <.submit_button
          phx-disable-with="Saving..."
          {if @default_provider_changed, do: [], else: [disabled: true, style: "disabled"]}
          icon="hero-identification"
        >
          Make Default
        </.submit_button>
      </div>
      <p class="text-xs text-neutral-500 mt-2">
        When selected, users signing in from the Firezone client will be taken directly to this provider for authentication.
      </p>
    </.form>
    """
  end

  defp provider_card(assigns) do
    ~H"""
    <div class="flex flex-col bg-neutral-50 rounded-lg p-4" style="width: 28rem;">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center flex-1 min-w-0 gap-2">
          <.provider_icon type={@type} class="w-7 h-7 flex-shrink-0" />
          <div class="flex flex-col min-w-0">
            <span class="font-medium text-xl truncate" title={@provider.name}>
              {@provider.name}
            </span>
            <span class="text-xs text-neutral-500 font-mono">
              ID: {@provider.id}
            </span>
          </div>
          <%= if Map.has_key?(@provider, :is_default) && @provider.is_default do %>
            <.badge type="primary" class="flex-shrink-0">DEFAULT</.badge>
          <% end %>
          <%= if Map.get(@provider, :is_legacy) do %>
            <.badge type="warning" class="flex-shrink-0">LEGACY</.badge>
          <% end %>
        </div>
        <div class="flex items-center gap-1">
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
                    <p>
                      Are you sure you want to delete <strong>{@provider.name}</strong>? This action cannot be undone.
                    </p>
                    <p>
                      This will immediately sign out all users authenticated via this provider.
                    </p>
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

        <div class="flex items-center gap-2">
          <.icon name="hero-window" class="w-5 h-5" title="Portal Session Lifetime" />
          <span class="font-medium">
            <%= if @provider.context in [:clients_and_portal, :portal_only] do %>
              Portal: {format_duration(
                Map.get(@provider, :portal_session_lifetime_secs) ||
                  @provider.__struct__.default_portal_session_lifetime_secs()
              )}
              <%= if is_nil(Map.get(@provider, :portal_session_lifetime_secs)) do %>
                <span class="text-neutral-400 text-xs">(default)</span>
              <% end %>
            <% else %>
              <span class="text-neutral-400">Portal: disabled</span>
            <% end %>
          </span>
        </div>

        <div class="flex items-center gap-2">
          <.icon name="hero-device-phone-mobile" class="w-5 h-5" title="Client Session Lifetime" />
          <span class="font-medium">
            <%= if @provider.context in [:clients_and_portal, :clients_only] do %>
              Clients: {format_duration(
                Map.get(@provider, :client_session_lifetime_secs) ||
                  @provider.__struct__.default_client_session_lifetime_secs()
              )}
              <%= if is_nil(Map.get(@provider, :client_session_lifetime_secs)) do %>
                <span class="text-neutral-400 text-xs">(default)</span>
              <% end %>
            <% else %>
              <span class="text-neutral-400">Client: disabled</span>
            <% end %>
          </span>
        </div>

        <div class="flex items-center gap-2">
          <.icon name="hero-clock" class="w-5 h-5" />
          <span class="font-medium">
            updated <.relative_datetime datetime={@provider.updated_at} />
          </span>
        </div>

        <div class="pt-3 mt-1 border-t border-neutral-200">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class="flex items-center gap-1">
                <.icon name="hero-device-phone-mobile" class="w-4 h-4" title="Client Sessions" />
                <span class="font-medium">
                  {@provider.client_tokens_count} client {ngettext(
                    "session",
                    "sessions",
                    @provider.client_tokens_count
                  )}
                </span>
              </div>
              <div class="flex items-center gap-1">
                <.icon name="hero-window" class="w-4 h-4" title="Portal Sessions" />
                <span class="font-medium">
                  {@provider.portal_sessions_count} portal {ngettext(
                    "session",
                    "sessions",
                    @provider.portal_sessions_count
                  )}
                </span>
              </div>
            </div>
            <.button_with_confirmation
              :if={@provider.client_tokens_count > 0 or @provider.portal_sessions_count > 0}
              id={"revoke-sessions-#{@provider.id}"}
              on_confirm="revoke_sessions"
              on_confirm_id={@provider.id}
              style="danger"
              size="xs"
            >
              Revoke All
              <:dialog_title>Revoke All Sessions</:dialog_title>
              <:dialog_content>
                <p>
                  Are you sure you want to revoke all sessions for <strong>{@provider.name}</strong>?
                </p>
                <p class="mt-2">
                  This will immediately end {@provider.client_tokens_count} client {ngettext(
                    "session",
                    "sessions",
                    @provider.client_tokens_count
                  )} and {@provider.portal_sessions_count} admin portal {ngettext(
                    "session",
                    "sessions",
                    @provider.portal_sessions_count
                  )}.
                </p>
              </:dialog_content>
              <:dialog_confirm_button>Revoke All Sessions</:dialog_confirm_button>
              <:dialog_cancel_button>Cancel</:dialog_cancel_button>
            </.button_with_confirmation>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :account_id, :string, required: true
  attr :form, :any, required: true
  attr :type, :string, required: true
  attr :submit_event, :string, required: true
  attr :verification_error, :any, default: nil
  attr :is_legacy, :boolean, default: false

  defp provider_form(assigns) do
    # Build the redirect URI based on legacy status
    redirect_uri =
      if assigns[:is_legacy] do
        account_id = assigns.account_id
        provider_id = Ecto.Changeset.get_field(assigns.form.source, :id)

        PortalWeb.Endpoint.url() <>
          "/#{account_id}/sign_in/providers/#{provider_id}/handle_callback"
      else
        PortalWeb.Endpoint.url() <> "/auth/oidc/callback"
      end

    assigns = assign(assigns, :redirect_uri, redirect_uri)

    ~H"""
    <.form
      id="auth-provider-form"
      for={@form}
      phx-change="validate"
      phx-submit={@submit_event}
    >
      <div class="space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
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
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <.input
              field={@form[:portal_session_lifetime_secs]}
              type="number"
              label="Portal Session Lifetime (seconds)"
              placeholder="28800"
              phx-debounce="300"
            />
            <p class="mt-1 text-xs text-neutral-600">
              Session lifetime for Admin Portal users (5 minutes to 24 hours). Default: 8 hours (28800).
            </p>
          </div>

          <div>
            <.input
              field={@form[:client_session_lifetime_secs]}
              type="number"
              label="Client Session Lifetime (seconds)"
              placeholder="604800"
              phx-debounce="300"
            />
            <p class="mt-1 text-xs text-neutral-600">
              Session lifetime for Client applications (1 hour to 90 days). Default: 7 days (604800).
            </p>
          </div>
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

        <div :if={@type in ["okta", "oidc"]} class="grid grid-cols-1 md:grid-cols-2 gap-6">
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
            <p class="mt-1 text-xs text-neutral-600">
              Enter the Client ID from your {titleize(@type)} application settings.
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
            <p class="mt-1 text-xs text-neutral-600">
              Enter the Client Secret from your {titleize(@type)} application settings.
            </p>
          </div>
        </div>

        <div :if={@type in ["okta", "oidc"]}>
          <label class="block text-sm text-neutral-900 mb-2">Redirect URI</label>
          <div class="flex" id="redirect-uri" phx-hook="CopyClipboard">
            <span id="redirect-uri-text" class="hidden">{@redirect_uri}</span>
            <input
              type="text"
              readonly
              value={@redirect_uri}
              class="block w-full rounded-l-md border-0 py-1.5 text-neutral-900 shadow-sm ring-1 ring-inset ring-neutral-300 bg-neutral-50 cursor-default sm:text-sm sm:leading-6"
            />
            <button
              type="button"
              data-copy-to-clipboard-target="redirect-uri-text"
              class="inline-flex items-center rounded-r-md border border-l-0 border-neutral-300 bg-white px-3 text-neutral-500 hover:bg-neutral-50 hover:text-neutral-700"
            >
              <span id="redirect-uri-default-message">
                <.icon name="hero-clipboard-document" class="h-5 w-5" />
              </span>
              <span id="redirect-uri-success-message" class="hidden">
                <.icon name="hero-check" class="h-5 w-5 text-green-600" />
              </span>
            </button>
          </div>
          <p class="mt-1 text-xs text-neutral-600">
            Copy this URI into your {titleize(@type)} application's allowed redirect URIs.
          </p>
        </div>

        <div
          :if={@type in ["entra", "google", "okta", "oidc"] and not @is_legacy}
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

  defp verification_fields_status(assigns) do
    ~H"""
    <div class="flex justify-between items-center">
      <label class="text-sm font-medium text-neutral-700">Issuer</label>
      <div class="text-right">
        <p class="text-sm font-semibold text-neutral-900">
          {verification_field_display(@form.source, :issuer)}
        </p>
      </div>
    </div>
    """
  end

  defp verification_field_display(changeset, field) do
    if get_field(changeset, :is_verified) do
      get_field(changeset, field)
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
    DB.insert_provider(changeset, socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(%{assigns: %{live_action: :edit, form: %{source: changeset}}} = socket) do
    DB.update_provider(changeset, socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp handle_submit({:ok, _provider}, socket) do
    {:noreply,
     socket
     |> init()
     |> put_flash(:success, "Authentication provider saved successfully.")
     |> push_patch(to: ~p"/#{socket.assigns.account}/settings/authentication")}
  end

  defp handle_submit({:error, changeset}, socket) do
    verification_error = verification_errors(changeset)
    {:noreply, assign(socket, verification_error: verification_error, form: to_form(changeset))}
  end

  defp verification_errors(changeset) do
    changeset.errors
    |> Enum.filter(fn {field, _error} -> field in [:issuer] end)
    |> Enum.map_join(" ", fn {_field, {message, _opts}} -> message end)
  end

  defp ready_to_verify?(form) do
    Enum.all?(form.source.errors, fn
      # We'll set these fields during verification
      {excluded, _errors} when excluded in [:is_verified, :issuer] ->
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
      # Get the type based on the schema module
      type = AuthProvider.type!(changeset.data.__struct__) |> String.to_existing_atom()

      changeset
      |> put_change(:id, id)
      |> put_assoc(:auth_provider, %AuthProvider{id: id, account_id: account_id, type: type})
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

  defp validate_not_disabling_default_provider(changeset) do
    # Only run this validation if is_disabled is being changed
    case get_change(changeset, :is_disabled) do
      true ->
        data = changeset.data

        # Check if the provider is currently the default
        if Map.has_key?(data, :is_default) && data.is_default do
          add_error(
            changeset,
            :is_disabled,
            "Cannot disable the default authentication provider. Please set a different provider as default first."
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp verified?(form) do
    schema = form.source.data.__struct__

    # Email/OTP and Userpass providers don't require verification
    if schema in [EmailOTP.AuthProvider, Userpass.AuthProvider] do
      true
    else
      get_field(form.source, :is_verified) == true
    end
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
    Logger.info(
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
    AuthProvider.type!(module.__struct__)
  end

  defp assign_default_provider(provider_id, socket) do
    provider =
      socket.assigns.providers
      |> Enum.find(fn provider -> provider.id == provider_id end)

    with true <- provider_type(provider) not in ["email_otp", "userpass"],
         {:ok, _result} <- DB.set_default_provider(provider, socket.assigns) do
      socket =
        socket
        |> put_flash(:success, "Default authentication provider set to #{provider.name}")
        |> init()

      {:noreply, socket}
    else
      false ->
        socket =
          socket
          |> put_flash(:error, "Email and userpass providers cannot be set as default.")

        {:noreply, socket}

      error ->
        Logger.info("Failed to set default auth provider",
          error: inspect(error)
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Failed to update default auth provider. Contact support if this issue persists."
          )

        {:noreply, socket}
    end
  end

  defp clear_default_provider(socket) do
    with {:ok, _result} <- DB.clear_default_provider(socket.assigns) do
      socket =
        socket
        |> put_flash(:success, "Default authentication provider cleared")
        |> init()

      {:noreply, socket}
    else
      error ->
        Logger.info("Failed to clear default auth provider",
          error: inspect(error)
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Failed to update default auth provider. Contact support if this issue persists."
          )

        {:noreply, socket}
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3_600 do
    minutes = div(seconds, 60)
    "#{minutes}m"
  end

  defp format_duration(seconds) when seconds < 86_400 do
    hours = div(seconds, 3_600)
    "#{hours}h"
  end

  defp format_duration(seconds) do
    days = div(seconds, 86_400)
    "#{days}d"
  end

  defmodule DB do
    alias Portal.{AuthProvider, EmailOTP, Userpass, OIDC, Entra, Google, Okta, Safe}
    import Ecto.Query
    import Ecto.Changeset

    def list_all_providers(subject) do
      [
        EmailOTP.AuthProvider |> Safe.scoped(subject) |> Safe.all(),
        Userpass.AuthProvider |> Safe.scoped(subject) |> Safe.all(),
        Google.AuthProvider |> Safe.scoped(subject) |> Safe.all(),
        Entra.AuthProvider |> Safe.scoped(subject) |> Safe.all(),
        Okta.AuthProvider |> Safe.scoped(subject) |> Safe.all(),
        OIDC.AuthProvider |> Safe.scoped(subject) |> Safe.all()
      ]
      |> List.flatten()
    end

    def get_provider!(schema, id, subject) do
      from(p in schema, where: p.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def insert_provider(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update_provider(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_provider!(provider, subject) do
      # Delete the parent auth_provider, which will CASCADE delete the child and tokens
      parent =
        from(p in AuthProvider, where: p.id == ^provider.id)
        |> Safe.scoped(subject)
        |> Safe.one!()

      parent |> Safe.scoped(subject) |> Safe.delete()
    end

    def set_default_provider(provider, assigns) do
      Safe.transact(fn ->
        with :ok <- clear_all_defaults(assigns.providers, assigns.subject) do
          # Then set is_default on the selected provider
          changeset = change(provider, is_default: true)
          changeset |> Safe.scoped(assigns.subject) |> Safe.update()
        end
      end)
    end

    def clear_default_provider(assigns) do
      Safe.transact(fn ->
        case clear_all_defaults(assigns.providers, assigns.subject) do
          :ok -> {:ok, :cleared}
          error -> error
        end
      end)
    end

    defp clear_all_defaults(providers, subject) do
      Enum.reduce_while(providers, :ok, fn p, _acc ->
        if Map.has_key?(p, :is_default) && p.is_default do
          changeset = change(p, is_default: false)

          case changeset |> Safe.scoped(subject) |> Safe.update() do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, :ok}
        end
      end)
    end

    def enrich_with_session_counts(providers, subject) do
      provider_ids = Enum.map(providers, & &1.id)

      client_tokens_counts =
        from(ct in Portal.ClientToken,
          where: ct.auth_provider_id in ^provider_ids,
          group_by: ct.auth_provider_id,
          select: {ct.auth_provider_id, count(ct.id)}
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Map.new()

      portal_sessions_counts =
        from(ps in Portal.PortalSession,
          where: ps.auth_provider_id in ^provider_ids,
          group_by: ps.auth_provider_id,
          select: {ps.auth_provider_id, count(ps.id)}
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Map.new()

      Enum.map(providers, fn provider ->
        provider
        |> Map.put(:client_tokens_count, Map.get(client_tokens_counts, provider.id, 0))
        |> Map.put(:portal_sessions_count, Map.get(portal_sessions_counts, provider.id, 0))
      end)
    end

    # Already handled by cascade delete
    def revoke_sessions_for_provider(nil, _subject), do: {:ok, 0}

    def revoke_sessions_for_provider(provider, subject) do
      Safe.transact(fn ->
        {client_tokens_deleted, _} =
          from(ct in Portal.ClientToken, where: ct.auth_provider_id == ^provider.id)
          |> Safe.scoped(subject)
          |> Safe.delete_all()

        {portal_sessions_deleted, _} =
          from(ps in Portal.PortalSession, where: ps.auth_provider_id == ^provider.id)
          |> Safe.scoped(subject)
          |> Safe.delete_all()

        {:ok, client_tokens_deleted + portal_sessions_deleted}
      end)
    end
  end
end
