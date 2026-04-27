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

  alias __MODULE__.Database

  import Ecto.Changeset

  require Logger

  @invalid_json_error_message "Discovery document contains invalid JSON. Please verify the Discovery Document URI returns valid OpenID Connect configuration."

  @context_options [
    {"Client Applications and Admin Portal", "clients_and_portal"},
    {"Client Applications Only", "clients_only"},
    {"Admin Portal Only", "portal_only"}
  ]

  @select_type_classes [
    "flex items-center w-full p-4 rounded border transition-colors cursor-pointer",
    "border-[var(--border)] bg-[var(--surface)]",
    "hover:bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)]"
  ]

  @new_types ~w[google entra okta oidc]
  @edit_types @new_types ++ ~w[userpass email_otp]

  @common_fields ~w[name context is_disabled issuer client_session_lifetime_secs portal_session_lifetime_secs]a

  @fields %{
    EmailOTP.AuthProvider => @common_fields,
    Userpass.AuthProvider => @common_fields,
    Google.AuthProvider => @common_fields ++ ~w[is_verified]a,
    Entra.AuthProvider => @common_fields ++ ~w[is_verified email_claim]a,
    Okta.AuthProvider => @common_fields ++ ~w[okta_domain client_id client_secret is_verified]a,
    OIDC.AuthProvider =>
      @common_fields ++ ~w[discovery_document_uri client_id client_secret is_verified is_legacy]a
  }

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Authentication")

    if connected?(socket) do
      :ok = Portal.PubSub.Changes.subscribe(socket.assigns.account.id)
    end

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
    provider = Database.get_provider!(schema, id, socket.assigns.subject)
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

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/authentication")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.live_action in [:select_type, :new, :edit] do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/authentication")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
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

    with {:ok, %{config: config}} <- PortalWeb.OIDC.setup_verification(type, opts),
         verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
         lv_pid_string = self() |> :erlang.pid_to_list() |> to_string(),
         state_token <-
           PortalWeb.OIDC.sign_verification_state(
             lv_pid_string,
             PortalWeb.OIDC.verification_state_type(type)
           ),
         {:ok, uri} <- PortalWeb.OIDC.build_verification_uri(type, config, verifier, state_token) do
      socket =
        assign(socket,
          pending_verification: %{config: config, verifier: verifier}
        )

      {:noreply, push_event(socket, "open_url", %{url: uri})}
    else
      {:error, reason} ->
        error = verification_start_error_message(reason)
        {:noreply, assign(socket, verification_error: error)}
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
      case Database.delete_provider!(provider, socket.assigns.subject) do
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

    case Database.update_provider(changeset, socket.assigns.subject) do
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

        {:noreply, put_flash(socket, :error, extract_disable_error(changeset))}

      {:error, reason} ->
        Logger.info("Failed to toggle authentication provider", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to update authentication provider.")}
    end
  end

  def handle_event("default_provider_change", _params, socket) do
    {:noreply, assign(socket, default_provider_changed: true)}
  end

  def handle_event("request_confirm", %{"id" => id, "action" => action}, socket) do
    {:noreply, assign(socket, pending_confirm: %{id: id, action: action})}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, pending_confirm: nil)}
  end

  def handle_event("set_default_provider", %{"id" => id}, socket) do
    assign_default_provider(id, socket)
  end

  def handle_event("clear_default_provider", _params, socket) do
    clear_default_provider(socket)
  end

  def handle_event("revoke_sessions", %{"id" => id}, socket) do
    provider = socket.assigns.providers |> Enum.find(fn p -> p.id == id end)

    case Database.revoke_sessions_for_provider(provider, socket.assigns.subject) do
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

  def handle_info(%Portal.Changes.Change{struct: %Portal.ClientToken{}}, socket) do
    {:noreply, refresh_session_counts(socket)}
  end

  def handle_info(%Portal.Changes.Change{old_struct: %Portal.ClientToken{}}, socket) do
    {:noreply, refresh_session_counts(socket)}
  end

  def handle_info(%Portal.Changes.Change{struct: %Portal.PortalSession{}}, socket) do
    {:noreply, refresh_session_counts(socket)}
  end

  def handle_info(%Portal.Changes.Change{old_struct: %Portal.PortalSession{}}, socket) do
    {:noreply, refresh_session_counts(socket)}
  end

  # Sent by VerificationController/OIDCController to fetch config+verifier for code exchange
  def handle_info({:get_pending_verification, from}, socket) do
    send(from, {:pending_verification, socket.assigns[:pending_verification]})
    {:noreply, assign(socket, pending_verification: nil)}
  end

  # Sent directly by the OIDC verification controller after code exchange succeeds
  def handle_info({:oidc_verify_complete, issuer, ack_to}, socket) do
    attrs = %{"is_verified" => true, "is_legacy" => false, "issuer" => issuer}

    changeset =
      socket.assigns.form.source
      |> apply_changes()
      |> changeset(attrs, socket)

    maybe_send_verification_ack(ack_to)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_info({:oidc_verify_complete, issuer}, socket) do
    handle_info({:oidc_verify_complete, issuer, nil}, socket)
  end

  # Sent directly by the OIDC verification controller when code exchange fails
  def handle_info({:oidc_verify_failed, reason}, socket) do
    error = "Failed to verify: #{format_verification_error_reason(reason)}"
    {:noreply, assign(socket, verification_error: error)}
  end

  # Sent directly by the Entra auth_provider verification controller
  def handle_info({:entra_verify_complete, issuer, _tenant_id, ack_to}, socket) do
    attrs = %{"is_verified" => true, "issuer" => issuer}

    changeset =
      socket.assigns.form.source
      |> apply_changes()
      |> changeset(attrs, socket)

    maybe_send_verification_ack(ack_to)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_info({:entra_verify_complete, issuer, _tenant_id}, socket) do
    handle_info({:entra_verify_complete, issuer, nil, nil}, socket)
  end

  # Sent directly by the verification controller on any failure
  def handle_info({:verification_failed, reason}, socket) do
    error = "Verification failed: #{format_verification_error_reason(reason)}"
    {:noreply, assign(socket, verification_error: error)}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp maybe_send_verification_ack({pid, ref}) when is_pid(pid) do
    send(pid, {:verification_ack, ref})
    :ok
  end

  defp maybe_send_verification_ack(_), do: :ok

  defp format_verification_error_reason(reason) when is_binary(reason), do: reason
  defp format_verification_error_reason(reason), do: inspect(reason)

  defp verification_start_error_message(:invalid_discovery_document_uri) do
    "The Discovery Document URI is invalid. Please check your provider configuration."
  end

  defp verification_start_error_message(:private_ip_blocked) do
    "The Discovery Document URI must not point to a private or reserved IP address."
  end

  defp verification_start_error_message({404, _body}),
    do: "Discovery document not found (HTTP 404). Please verify the Discovery Document URI."

  defp verification_start_error_message({status, _body})
       when is_integer(status) and status >= 500,
       do: "Identity provider is unavailable (HTTP #{status}). Please try again shortly."

  defp verification_start_error_message({status, _body}) when is_integer(status),
    do:
      "Failed to fetch discovery document (HTTP #{status}). Please verify your provider configuration."

  defp verification_start_error_message(%Req.TransportError{reason: :nxdomain}),
    do:
      "Unable to fetch discovery document: DNS lookup failed. Please verify the provider domain."

  defp verification_start_error_message(%Req.TransportError{reason: :econnrefused}),
    do: "Unable to fetch discovery document: Connection refused by the remote server."

  defp verification_start_error_message(%Req.TransportError{reason: :timeout}),
    do: "Unable to fetch discovery document: Connection timed out."

  defp verification_start_error_message(%Req.TransportError{}),
    do: "Unable to fetch discovery document due to a network error."

  defp verification_start_error_message({:unexpected_end, _}),
    do: @invalid_json_error_message

  defp verification_start_error_message({tag, _, _})
       when tag in [:invalid_byte, :unexpected_sequence],
       do: @invalid_json_error_message

  defp verification_start_error_message(reason) do
    Logger.error("Unhandled verification start error", reason: inspect(reason))
    "Failed to start verification."
  end

  defp clear_verification_if_trigger_fields_changed(changeset) do
    schema = changeset.data.__struct__

    # Provider-specific trigger fields:
    # - Okta: okta_domain is user-editable, discovery_document_uri is computed from it
    # - OIDC: discovery_document_uri is user-editable
    # - Google/Entra: no user-editable OIDC config fields
    fields =
      case schema do
        Okta.AuthProvider -> [:client_id, :client_secret, :okta_domain]
        OIDC.AuthProvider -> [:client_id, :client_secret, :discovery_document_uri]
        _ -> []
      end

    if Enum.any?(fields, &get_change(changeset, &1)) do
      put_change(changeset, :is_verified, false)
    else
      changeset
    end
  end

  defp refresh_session_counts(socket) do
    providers =
      Database.enrich_with_session_counts(socket.assigns.providers, socket.assigns.subject)

    assign(socket, providers: providers)
  end

  defp init(socket) do
    providers =
      Database.list_all_providers(socket.assigns.subject)
      |> Database.enrich_with_session_counts(socket.assigns.subject)

    assign(socket,
      providers: providers,
      verification_error: nil,
      pending_confirm: nil
    )
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-[var(--border)] shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-xs font-semibold text-[var(--text-primary)]">Identity Providers</h2>
            <span class="text-xs text-[var(--text-tertiary)] tabular-nums">{length(@providers)}</span>
          </div>
          <.link
            patch={~p"/#{@account}/settings/authentication/new"}
            class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
          >
            <.icon name="ri-add-line" class="w-3 h-3" /> Add
          </.link>
        </div>

        <div class="flex-1 overflow-auto">
          <table class="w-full text-sm border-collapse">
            <thead class="sticky top-0 z-10 bg-[var(--surface-raised)]">
              <tr class="border-b border-[var(--border-strong)]">
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Provider
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-32">
                  Context
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Issuer
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                  Portal TTL
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                  Client TTL
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-48">
                  Sessions
                </th>
                <th class="px-6 py-2.5 w-14"></th>
              </tr>
            </thead>
            <tbody>
              <.provider_row
                :for={provider <- @providers}
                type={provider_type(provider)}
                account={@account}
                provider={provider}
                pending_confirm={@pending_confirm}
              />
            </tbody>
          </table>
        </div>

    <!-- Add Provider Panel -->
        <div
          id="add-provider-panel"
          class={[
            "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
            "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
            "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
            "transition-transform duration-200 ease-in-out",
            (@live_action in [:select_type, :new] && "translate-x-0") || "translate-x-full"
          ]}
          phx-window-keydown="handle_keydown"
          phx-key="Escape"
        >
          <!-- Select Provider Type -->
          <div :if={@live_action == :select_type} class="flex flex-col h-full overflow-hidden">
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Select Provider Type</h2>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <p class="mb-4 text-xs text-[var(--text-tertiary)]">
                Select an authentication provider type to add:
              </p>
              <ul class="flex flex-col gap-2">
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/authentication/google/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="google" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">Google</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Authenticate users against a Google account.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/authentication/entra/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="entra" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">Entra</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Authenticate users against a Microsoft Entra account.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/authentication/okta/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="okta" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">Okta</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Authenticate users against an Okta account.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/authentication/oidc/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="oidc" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">OIDC</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Authenticate users against any OpenID Connect compliant identity provider.
                    </span>
                  </.link>
                </li>
              </ul>
            </div>
          </div>

    <!-- New Provider Form -->
          <div
            :if={@live_action == :new and assigns[:form] != nil}
            class="flex flex-col h-full overflow-hidden"
          >
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
              <div class="flex items-center gap-2">
                <.link
                  patch={~p"/#{@account}/settings/authentication/new"}
                  class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                  title="Back"
                >
                  <.icon name="ri-arrow-left-line" class="w-4 h-4" />
                </.link>
                <div class="flex items-center gap-2">
                  <.provider_icon type={@type} class="w-5 h-5 shrink-0" />
                  <h2 class="text-sm font-semibold text-[var(--text-primary)]">
                    Add {titleize(@type)} Provider
                  </h2>
                  <.docs_action path={"/authenticate/#{@type}"} />
                </div>
              </div>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <.provider_form
                account_id={@account.id}
                verification_error={@verification_error}
                form={@form}
                type={@type}
                submit_event="submit_provider"
              />
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-[var(--border)]">
              <button
                phx-click="close_panel"
                class="px-3 py-1.5 text-sm rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                Cancel
              </button>
              <button
                form="auth-provider-form"
                type="submit"
                disabled={not @form.source.valid?}
                class="px-3 py-1.5 text-sm rounded bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                Create
              </button>
            </div>
          </div>
        </div>
      </div>

    <!-- Edit Provider Panel -->
      <div
        id="edit-provider-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :edit && assigns[:form] != nil && "translate-x-0") || "translate-x-full"
        ]}
        phx-window-keydown="handle_keydown"
        phx-key="Escape"
      >
        <div
          :if={@live_action == :edit and assigns[:form] != nil}
          class="flex flex-col h-full overflow-hidden"
        >
          <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
            <div class="flex items-center gap-2">
              <.provider_icon type={@type} class="w-5 h-5 shrink-0" />
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">
                Edit {@provider_name}
              </h2>
              <.docs_action path={"/authenticate/#{@type}"} />
            </div>
            <button
              phx-click="close_panel"
              class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
              title="Close (Esc)"
            >
              <.icon name="ri-close-line" class="w-4 h-4" />
            </button>
          </div>
          <div class="flex-1 overflow-y-auto px-5 py-4">
            <.flash :if={assigns[:is_legacy]} kind={:warning_inline} class="mb-4">
              This provider uses legacy configuration. We recommend setting up a new authentication
              provider for your identity service to take advantage of improved security and features.
            </.flash>
            <.provider_form
              account_id={@account.id}
              verification_error={@verification_error}
              form={@form}
              type={@type}
              submit_event="submit_provider"
              is_legacy={assigns[:is_legacy]}
            />
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-[var(--border)]">
            <button
              phx-click="close_panel"
              class="px-3 py-1.5 text-sm rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              form="auth-provider-form"
              type="submit"
              disabled={
                not @form.source.valid? or Enum.empty?(@form.source.changes) or not verified?(@form)
              }
              class="px-3 py-1.5 text-sm rounded bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp provider_row(assigns) do
    assigns =
      assign(assigns, provider_row_state(assigns.provider, assigns.type, assigns.pending_confirm))

    ~H"""
    <tr class={[
      "border-b transition-colors",
      @is_pending_toggle && "border-amber-200 bg-amber-50",
      @is_pending_delete && "border-red-200 bg-red-50",
      @is_pending_revoke && "border-orange-200 bg-orange-50",
      !@is_pending_toggle && !@is_pending_delete && !@is_pending_revoke &&
        "border-[var(--border)] hover:bg-[var(--surface-raised)]",
      @provider.is_disabled && !@is_pending_toggle && !@is_pending_delete && !@is_pending_revoke &&
        "opacity-60"
    ]}>
      <td class="px-6 py-3">
        <div class="flex items-center gap-3">
          <.provider_icon type={@type} class="w-7 h-7 shrink-0" />
          <div>
            <div class="flex items-center gap-1.5">
              <span class={[
                "text-sm font-medium",
                @is_pending_toggle && "text-amber-900",
                @is_pending_delete && "text-red-900",
                @is_pending_revoke && "text-orange-900",
                !@is_pending_toggle && !@is_pending_delete && !@is_pending_revoke &&
                  "text-[var(--text-primary)]"
              ]}>
                {@provider.name}
              </span>
              <span
                :if={@is_default && !@is_pending_toggle && !@is_pending_delete && !@is_pending_revoke}
                class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-[var(--brand-muted)] text-[var(--brand)]"
              >
                Default
              </span>
              <span
                :if={
                  @provider.is_disabled && !@is_pending_toggle && !@is_pending_delete &&
                    !@is_pending_revoke
                }
                class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-[var(--surface-raised)] text-[var(--text-tertiary)] border border-[var(--border)]"
              >
                Disabled
              </span>
              <span
                :if={
                  Map.get(@provider, :is_legacy) && !@is_pending_toggle && !@is_pending_delete &&
                    !@is_pending_revoke
                }
                class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-yellow-100 text-yellow-700"
              >
                Legacy
              </span>
            </div>
            <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">{@provider.id}</div>
          </div>
        </div>
      </td>
      <%= if @is_pending_revoke do %>
        <td colspan="6" class="px-6 py-3">
          <div class="flex items-center gap-4">
            <span class="text-xs text-orange-700">
              Revoke all sessions for this provider? This will immediately sign out all users authenticated this provider.
            </span>
            <div class="flex items-center gap-2 ml-auto shrink-0">
              <button
                phx-click="cancel_confirm"
                class="px-2.5 py-1 text-xs rounded border border-orange-300 bg-white text-orange-800 hover:bg-orange-100 transition-colors"
              >
                Cancel
              </button>
              <button
                phx-click="revoke_sessions"
                phx-value-id={@provider.id}
                class="px-2.5 py-1 text-xs rounded bg-orange-600 text-white hover:bg-orange-700 transition-colors"
              >
                Revoke sessions
              </button>
            </div>
          </div>
        </td>
      <% else %>
        <%= if @is_pending_toggle do %>
          <td colspan="6" class="px-6 py-3">
            <div class="flex items-center gap-4">
              <span class="text-xs text-amber-700">
                {if @provider.is_disabled,
                  do: "Re-enable this provider?",
                  else:
                    "Disable this provider? Users will not be able to sign in while it is disabled."}
              </span>
              <div class="flex items-center gap-2 ml-auto shrink-0">
                <button
                  phx-click="cancel_confirm"
                  class="px-2.5 py-1 text-xs rounded border border-amber-300 bg-white text-amber-800 hover:bg-amber-100 transition-colors"
                >
                  Cancel
                </button>
                <button
                  phx-click="toggle_provider"
                  phx-value-id={@provider.id}
                  class="px-2.5 py-1 text-xs rounded bg-amber-600 text-white hover:bg-amber-700 transition-colors"
                >
                  {if @provider.is_disabled, do: "Enable", else: "Disable"}
                </button>
              </div>
            </div>
          </td>
        <% else %>
          <%= if @is_pending_delete do %>
            <td colspan="6" class="px-6 py-3">
              <div class="flex items-center gap-4">
                <span class="text-xs text-red-700">
                  Delete this provider? This will immediately sign out all users authenticated via this provider and cannot be undone.
                </span>
                <div class="flex items-center gap-2 ml-auto shrink-0">
                  <button
                    phx-click="cancel_confirm"
                    class="px-2.5 py-1 text-xs rounded border border-red-300 bg-white text-red-800 hover:bg-red-100 transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    phx-click="delete_provider"
                    phx-value-id={@provider.id}
                    class="px-2.5 py-1 text-xs rounded bg-red-600 text-white hover:bg-red-700 transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </td>
          <% else %>
            <td class="px-6 py-3">
              <.context_badge context={@provider.context} />
            </td>
            <td class="px-6 py-3">
              <span class="font-mono text-xs text-[var(--text-secondary)]">
                {Map.get(@provider, :issuer) || "—"}
              </span>
            </td>
            <td class="px-6 py-3 text-sm tabular-nums text-[var(--text-secondary)]">
              {@portal_ttl || "—"}
            </td>
            <td class="px-6 py-3 text-sm tabular-nums text-[var(--text-secondary)]">
              {@client_ttl || "—"}
            </td>
            <td class="px-6 py-3">
              <div class="flex items-center gap-2.5 text-xs text-[var(--text-secondary)] tabular-nums">
                <span>
                  <span class="font-medium text-[var(--text-primary)]">
                    {@provider.portal_sessions_count}
                  </span>
                  portal
                </span>
                <span class="w-px h-3 bg-[var(--border-strong)] shrink-0"></span>
                <span>
                  <span class="font-medium text-[var(--text-primary)]">
                    {@provider.client_tokens_count}
                  </span>
                  client
                </span>
              </div>
            </td>
            <td class="px-6 py-3">
              <div class="flex justify-end">
                <.popover placement="bottom" trigger="click">
                  <:target>
                    <button
                      type="button"
                      class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                    >
                      <.icon name="ri-more-2-line" class="w-4 h-4" />
                    </button>
                  </:target>
                  <:content>
                    <div class="flex flex-col py-1 w-44">
                      <button
                        :if={@can_be_default and not @is_default}
                        phx-click="set_default_provider"
                        phx-value-id={@provider.id}
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                      >
                        <.icon name="ri-star-line" class="w-3.5 h-3.5 shrink-0" /> Make default
                      </button>
                      <button
                        :if={@can_be_default and @is_default}
                        phx-click="clear_default_provider"
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                      >
                        <.icon name="ri-star-fill" class="w-3.5 h-3.5 shrink-0" /> Remove default
                      </button>
                      <button
                        :if={not @can_be_default}
                        disabled
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left text-[var(--text-tertiary)] cursor-default"
                      >
                        <.icon name="ri-star-line" class="w-3.5 h-3.5 shrink-0" /> Make default
                      </button>
                      <div class="my-1 border-t border-[var(--border)]"></div>
                      <.link
                        patch={~p"/#{@account}/settings/authentication/#{@type}/#{@provider.id}/edit"}
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                      >
                        <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
                      </.link>
                      <div class="my-1 border-t border-[var(--border)]"></div>
                      <button
                        :if={@has_sessions}
                        phx-click="request_confirm"
                        phx-value-id={@provider.id}
                        phx-value-action="revoke"
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                      >
                        <.icon name="ri-logout-box-r-line" class="w-3.5 h-3.5 shrink-0" />
                        Revoke sessions
                      </button>
                      <button
                        :if={not @has_sessions}
                        disabled
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left text-[var(--text-tertiary)] cursor-default"
                      >
                        <.icon name="ri-logout-box-r-line" class="w-3.5 h-3.5 shrink-0" />
                        Revoke sessions
                      </button>
                      <div class="my-1 border-t border-[var(--border)]"></div>
                      <button
                        phx-click="request_confirm"
                        phx-value-id={@provider.id}
                        phx-value-action="toggle"
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                      >
                        <.icon
                          name={
                            if @provider.is_disabled,
                              do: "ri-checkbox-circle-line",
                              else: "ri-close-circle-line"
                          }
                          class="w-3.5 h-3.5 shrink-0"
                        />
                        {if @provider.is_disabled, do: "Enable", else: "Disable"}
                      </button>
                      <button
                        :if={@can_be_deleted}
                        phx-click="request_confirm"
                        phx-value-id={@provider.id}
                        phx-value-action="delete"
                        class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--status-error)]"
                      >
                        <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Delete
                      </button>
                    </div>
                  </:content>
                </.popover>
              </div>
            </td>
          <% end %>
        <% end %>
      <% end %>
    </tr>
    """
  end

  defp provider_row_state(provider, type, pending_confirm) do
    pending_state = provider_pending_state(provider, pending_confirm)

    %{
      is_default: provider_default?(provider),
      can_be_default: provider_action_allowed?(type),
      can_be_deleted: provider_action_allowed?(type),
      has_sessions: provider_has_sessions?(provider),
      is_pending_toggle: pending_state == :toggle,
      is_pending_delete: pending_state == :delete,
      is_pending_revoke: pending_state == :revoke,
      portal_ttl: provider_portal_ttl(provider),
      client_ttl: provider_client_ttl(provider)
    }
  end

  defp provider_default?(provider), do: Map.get(provider, :is_default, false)

  defp provider_action_allowed?(type), do: type not in ["email_otp", "userpass"]

  defp provider_has_sessions?(provider) do
    provider.client_tokens_count > 0 or provider.portal_sessions_count > 0
  end

  defp provider_pending_state(provider, %{id: id, action: action}) when id == provider.id,
    do: String.to_existing_atom(action)

  defp provider_pending_state(_provider, _pending_confirm), do: nil

  defp provider_portal_ttl(%{context: context} = provider)
       when context in [:clients_and_portal, :portal_only] do
    format_duration(
      Map.get(provider, :portal_session_lifetime_secs) ||
        provider.__struct__.default_portal_session_lifetime_secs()
    )
  end

  defp provider_portal_ttl(_provider), do: nil

  defp provider_client_ttl(%{context: context} = provider)
       when context in [:clients_and_portal, :clients_only] do
    format_duration(
      Map.get(provider, :client_session_lifetime_secs) ||
        provider.__struct__.default_client_session_lifetime_secs()
    )
  end

  defp provider_client_ttl(_provider), do: nil

  attr :account_id, :string, required: true
  attr :form, :any, required: true
  attr :type, :string, required: true
  attr :submit_event, :string, required: true
  attr :verification_error, :any, default: nil
  attr :is_legacy, :boolean, default: false

  defp provider_form(assigns) do
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
      <div class="space-y-5">
        <%!-- General --%>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label
              for={@form[:name].id}
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Name <span class="text-[var(--status-error)]">*</span>
            </label>
            <.input
              field={@form[:name]}
              type="text"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
          </div>
          <div>
            <label
              for={@form[:context].id}
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Context <span class="text-[var(--status-error)]">*</span>
            </label>
            <.input
              field={@form[:context]}
              type="select"
              options={context_options()}
              required
            />
          </div>
        </div>

        <%!-- Session lifetimes --%>
        <div class="pt-4 border-t border-[var(--border)]">
          <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
            Session Lifetimes
          </p>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label
                for={@form[:portal_session_lifetime_secs].id}
                class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
              >
                Portal (seconds)
              </label>
              <.input
                field={@form[:portal_session_lifetime_secs]}
                type="number"
                placeholder="28800"
                phx-debounce="300"
              />
            </div>
            <div>
              <label
                for={@form[:client_session_lifetime_secs].id}
                class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
              >
                Client (seconds)
              </label>
              <.input
                field={@form[:client_session_lifetime_secs]}
                type="number"
                placeholder="604800"
                phx-debounce="300"
              />
            </div>
          </div>
          <p class="mt-2 text-xs text-[var(--text-tertiary)]">
            Portal default: 8 hours · Client default: 7 days
          </p>
        </div>

        <%!-- Entra-specific config --%>
        <div :if={@type == "entra"} class="pt-4 border-t border-[var(--border)] space-y-4">
          <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
            Provider Configuration
          </p>
          <div>
            <label
              for={@form[:email_claim].id}
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Email Claim <span class="text-[var(--status-error)]">*</span>
            </label>
            <.input
              field={@form[:email_claim]}
              type="select"
              options={[
                {"UPN (upn)", "upn"},
                {"Email (email)", "email"},
                {"Preferred Username (preferred_username)", "preferred_username"}
              ]}
              required
            />
            <p class="mt-1 text-xs text-[var(--text-tertiary)]">
              The OIDC claim to use as the user's email address during sign-in.
            </p>
          </div>
        </div>

        <%!-- Provider-specific config (Okta / OIDC) --%>
        <div :if={@type in ["okta", "oidc"]} class="pt-4 border-t border-[var(--border)] space-y-4">
          <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
            Provider Configuration
          </p>

          <div :if={@type == "okta"}>
            <label
              for={@form[:okta_domain].id}
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Okta Domain <span class="text-[var(--status-error)]">*</span>
            </label>
            <.input
              field={@form[:okta_domain]}
              type="text"
              placeholder="example.okta.com"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
          </div>

          <div :if={@type == "oidc"}>
            <label
              for={@form[:discovery_document_uri].id}
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Discovery Document URI <span class="text-[var(--status-error)]">*</span>
            </label>
            <.input
              field={@form[:discovery_document_uri]}
              type="text"
              placeholder="https://example.com/.well-known/openid-configuration"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label
                for={@form[:client_id].id}
                class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
              >
                Client ID <span class="text-[var(--status-error)]">*</span>
              </label>
              <.input
                field={@form[:client_id]}
                type="text"
                autocomplete="off"
                phx-debounce="300"
                data-1p-ignore
                required
              />
            </div>
            <div>
              <label
                for={@form[:client_secret].id}
                class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
              >
                Client Secret <span class="text-[var(--status-error)]">*</span>
              </label>
              <.input
                field={@form[:client_secret]}
                type="password"
                autocomplete="off"
                phx-debounce="300"
                data-1p-ignore
                required
              />
            </div>
          </div>

          <%!-- Redirect URI --%>
          <div>
            <label class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
              Redirect URI
            </label>
            <div
              class="flex items-center gap-2 px-3 py-2 rounded border border-[var(--border)] bg-[var(--surface-raised)]"
              id="redirect-uri"
              phx-hook="CopyClipboard"
            >
              <span id="redirect-uri-text" class="hidden">{@redirect_uri}</span>
              <code class="flex-1 text-xs font-mono text-[var(--text-secondary)] truncate">
                {@redirect_uri}
              </code>
              <button
                type="button"
                data-copy-to-clipboard-target="redirect-uri-text"
                class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
              >
                <span id="redirect-uri-default-message">
                  <.icon name="ri-clipboard-line" class="w-4 h-4" />
                </span>
                <span id="redirect-uri-success-message" class="hidden">
                  <.icon name="ri-check-line" class="w-4 h-4 text-green-600" />
                </span>
              </button>
            </div>
            <p class="mt-1 text-xs text-[var(--text-tertiary)]">
              Add this to your {titleize(@type)} application's allowed redirect URIs.
            </p>
          </div>
        </div>

        <%!-- Verification --%>
        <div
          :if={@type in ["entra", "google", "okta", "oidc"] and not @is_legacy}
          class="pt-4 border-t border-[var(--border)]"
        >
          <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
            Verification
          </p>
          <.flash :if={@verification_error} kind={:error} class="mb-3">
            {@verification_error}
          </.flash>
          <div class="rounded border border-[var(--border)] overflow-hidden">
            <div class="flex items-center justify-between px-4 py-3">
              <p class="text-sm text-[var(--text-secondary)]">
                {verification_help_text(@form, @type)}
              </p>
              <div class="ml-4 shrink-0">
                <.verification_status_badge id="verify-button" form={@form} />
              </div>
            </div>
            <div
              :if={verified?(@form)}
              class="flex items-center justify-between px-4 py-2.5 border-t border-[var(--border)] bg-[var(--surface-raised)]"
            >
              <div class="flex items-center gap-2 min-w-0">
                <span class="text-xs text-[var(--text-tertiary)] shrink-0">Issuer</span>
                <span class="text-xs font-mono text-[var(--text-primary)] truncate">
                  {get_field(@form.source, :issuer)}
                </span>
              </div>
              <button
                type="button"
                phx-click="reset_verification"
                class="ml-4 shrink-0 text-xs text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
              >
                Reset
              </button>
            </div>
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
      "Sign in with your #{titleize(type)} account to verify the configuration."
    end
  end

  defp verification_status_badge(assigns) do
    ~H"""
    <div
      :if={verified?(@form)}
      class="flex items-center gap-1.5 text-xs font-medium text-green-700 bg-green-100 px-2.5 py-1 rounded"
    >
      <.icon name="ri-checkbox-circle-line" class="w-3.5 h-3.5" /> Verified
    </div>
    <.button
      :if={not verified?(@form) and ready_to_verify?(@form)}
      type="button"
      id="verify-button"
      style="primary"
      icon="ri-external-link-line"
      phx-click="start_verification"
      phx-hook="OpenURL"
    >
      Verify Now
    </.button>
    <.button
      :if={not verified?(@form) and not ready_to_verify?(@form)}
      type="button"
      style="primary"
      icon="ri-external-link-line"
      disabled
    >
      Verify Now
    </.button>
    """
  end

  defp submit_provider(%{assigns: %{live_action: :new, form: %{source: changeset}}} = socket) do
    Database.insert_provider(changeset, socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_provider(%{assigns: %{live_action: :edit, form: %{source: changeset}}} = socket) do
    Database.update_provider(changeset, socket.assigns.subject)
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

  defp context_badge(assigns) do
    {label, classes} =
      case assigns.context do
        :clients_and_portal ->
          {"All", "bg-[var(--brand-muted)] text-[var(--brand)]"}

        :clients_only ->
          {"Clients", "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"}

        :portal_only ->
          {"Portal", "bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400"}

        _ ->
          {"—", "text-[var(--text-tertiary)]"}
      end

    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span class={["text-[10px] font-semibold px-1.5 py-0.5 rounded", @classes]}>
      {@label}
    </span>
    """
  end

  defp context_options, do: @context_options

  defp select_type_classes, do: @select_type_classes

  defp titleize("google"), do: "Google"
  defp titleize("entra"), do: "Microsoft Entra"
  defp titleize("okta"), do: "Okta"
  defp titleize("oidc"), do: "OpenID Connect"

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

  defp extract_disable_error(changeset) do
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

  defp provider_type(module) do
    AuthProvider.type!(module.__struct__)
  end

  defp assign_default_provider(provider_id, socket) do
    provider =
      socket.assigns.providers
      |> Enum.find(fn provider -> provider.id == provider_id end)

    with true <- provider_type(provider) not in ["email_otp", "userpass"],
         {:ok, _result} <- Database.set_default_provider(provider, socket.assigns) do
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
    with {:ok, _result} <- Database.clear_default_provider(socket.assigns) do
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

  defmodule Database do
    alias Portal.{AuthProvider, EmailOTP, Userpass, OIDC, Entra, Google, Okta, Safe}
    import Ecto.Query
    import Ecto.Changeset

    def list_all_providers(subject) do
      [
        EmailOTP.AuthProvider |> Safe.scoped(subject, :replica) |> Safe.all(),
        Userpass.AuthProvider |> Safe.scoped(subject, :replica) |> Safe.all(),
        Google.AuthProvider |> Safe.scoped(subject, :replica) |> Safe.all(),
        Entra.AuthProvider |> Safe.scoped(subject, :replica) |> Safe.all(),
        Okta.AuthProvider |> Safe.scoped(subject, :replica) |> Safe.all(),
        OIDC.AuthProvider |> Safe.scoped(subject, :replica) |> Safe.all()
      ]
      |> List.flatten()
    end

    def get_provider!(schema, id, subject) do
      from(p in schema, where: p.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
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
        |> Safe.scoped(subject, :replica)
        |> Safe.one!(fallback_to_primary: true)

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
        try_clear_default(p, subject)
      end)
    end

    defp try_clear_default(p, subject) do
      if Map.has_key?(p, :is_default) && p.is_default do
        changeset = change(p, is_default: false)

        case changeset |> Safe.scoped(subject) |> Safe.update() do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end

    def enrich_with_session_counts(providers, subject) do
      provider_ids = Enum.map(providers, & &1.id)

      client_tokens_counts =
        from(ct in Portal.ClientToken,
          where: ct.auth_provider_id in ^provider_ids,
          group_by: ct.auth_provider_id,
          select: {ct.auth_provider_id, count(ct.id)}
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Map.new()

      portal_sessions_counts =
        from(ps in Portal.PortalSession,
          where: ps.auth_provider_id in ^provider_ids,
          group_by: ps.auth_provider_id,
          select: {ps.auth_provider_id, count(ps.id)}
        )
        |> Safe.scoped(subject, :replica)
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
