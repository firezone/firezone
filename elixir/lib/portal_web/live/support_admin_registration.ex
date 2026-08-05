defmodule PortalWeb.SupportAdminRegistration do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database

  def mount(%{"token" => token}, _session, socket) do
    token_hash = Portal.Crypto.hash(:sha256, token)

    case Database.fetch_admin_by_registration_token(token_hash) do
      nil ->
        raise PortalWeb.LiveErrors.NotFoundError

      support_admin ->
        socket =
          assign(socket,
            support_admin: support_admin,
            token_hash: token_hash,
            challenge: Portal.Crypto.WebAuthn.registration_challenge(),
            state: :ready,
            error: nil,
            page_title: "Register Passkey"
          )

        {:ok, socket}
    end
  end

  def mount(_params, _session, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-xl font-semibold text-heading mb-2">
      Firezone Support passkey
    </h1>

    <div :if={@state == :success}>
      <p class="text-sm text-body mb-6">
        Passkey registered for <strong class="text-heading">{@support_admin.email}</strong>.
        You're now enabled for support sign-in. You can close this tab.
      </p>
    </div>

    <div :if={@state == :ready}>
      <p class="text-sm text-body mb-6">
        Register a passkey for <strong class="text-heading">{@support_admin.email}</strong>
        to enable support sign-in.
      </p>

      <p :if={@support_admin.passkey_registered_at} class="text-sm text-body mb-6">
        A passkey is already registered for this address. Completing this registration
        replaces it.
      </p>

      <p :if={@error} class="text-sm text-red-600 dark:text-red-400 mb-6">
        {@error}
      </p>

      <button
        id="webauthn-register"
        type="button"
        phx-hook="WebAuthnRegister"
        phx-update="ignore"
        data-challenge={Base.url_encode64(@challenge.bytes, padding: false)}
        data-rp-id={@challenge.rp_id}
        data-rp-name="Firezone"
        data-user-id={Base.url_encode64(@support_admin.id, padding: false)}
        data-user-name={@support_admin.email}
        class="w-full px-3 py-2.5 rounded-md text-sm font-medium bg-brand text-white hover:bg-brand-dark transition-colors"
      >
        <%= if @support_admin.passkey_registered_at do %>
          Replace passkey
        <% else %>
          Create passkey
        <% end %>
      </button>
    </div>
    """
  end

  def handle_event("verify_registration", params, socket) do
    %{
      "attestation_object" => attestation_object,
      "client_data_json" => client_data_json
    } = params

    with {:ok, attestation_object} <- Base.url_decode64(attestation_object, padding: false),
         {:ok, client_data_json} <- Base.url_decode64(client_data_json, padding: false),
         {:ok, passkey} <-
           Portal.Crypto.WebAuthn.verify_registration(
             socket.assigns.challenge,
             attestation_object,
             client_data_json
           ),
         :ok <-
           Database.complete_registration(
             socket.assigns.support_admin,
             socket.assigns.token_hash,
             passkey
           ) do
      {:noreply, assign(socket, state: :success, error: nil)}
    else
      {:error, :stale_token} ->
        raise PortalWeb.LiveErrors.NotFoundError

      _other ->
        socket =
          assign(socket,
            challenge: Portal.Crypto.WebAuthn.registration_challenge(),
            error: "Passkey registration failed. Try again."
          )

        {:noreply, socket}
    end
  end

  def handle_event("registration_failed", %{"error" => error}, socket) do
    socket =
      assign(socket,
        challenge: Portal.Crypto.WebAuthn.registration_challenge(),
        error: registration_error_message(error)
      )

    {:noreply, socket}
  end

  defp registration_error_message("unsupported"), do: "This browser doesn't support passkeys."

  defp registration_error_message("NotAllowedError"),
    do: "Passkey registration was cancelled or timed out. Try again."

  defp registration_error_message("InvalidStateError"),
    do: "This device already has a passkey registered for this address."

  defp registration_error_message(_other), do: "Passkey registration failed. Try again."

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.SupportAdmin

    def fetch_admin_by_registration_token(token_hash) do
      from(sa in SupportAdmin,
        where: sa.registration_token_hash == ^token_hash,
        where: sa.registration_token_expires_at > ^DateTime.utc_now()
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def complete_registration(%SupportAdmin{} = support_admin, token_hash, passkey) do
      from(sa in SupportAdmin,
        where: sa.id == ^support_admin.id,
        where: sa.registration_token_hash == ^token_hash,
        update: [
          set: [
            passkey_credential_id: ^passkey.credential_id,
            passkey_public_key: ^passkey.public_key,
            passkey_sign_count: ^passkey.sign_count,
            passkey_registered_at: ^DateTime.utc_now(),
            registration_token_hash: nil,
            registration_token_expires_at: nil,
            otp_code_hash: nil,
            otp_expires_at: nil,
            otp_attempts: 0
          ]
        ]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
      |> case do
        {1, _} -> :ok
        {0, _} -> {:error, :stale_token}
      end
    end
  end
end
