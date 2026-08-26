defmodule PortalWeb.SentinelConsentController do
  @moduledoc """
  Landing for the Microsoft Sentinel admin consent redirect. Entra requires a
  registered reply address, and the consenting admin is often not a signed-in
  portal user, so the outcome renders as a standalone page that closes itself
  rather than a redirect into the authenticated app.

  A returned admin consent proves nothing on its own: Entra reports it with
  unsigned query parameters, and it can carry an error in the same redirect.
  Consent is therefore followed by the same tenant proof the Entra auth
  provider, directory sync, and Intune flows run. The `tenant` parameter only
  picks the authority the proof is sent to; the tenant Firezone acts on is the
  `tid` claim of a signature-verified ID token, which must match it, and the
  `wids` claim of that token has to carry a tenant-wide admin role. The
  verified tenant is sent back to the log sink form so nobody has to copy it by
  hand.
  """
  use PortalWeb, :controller

  alias PortalWeb.OIDC

  require Logger

  plug :put_root_layout, html: {PortalWeb.Layouts, :verification}
  plug :put_layout, html: false

  # An administrator can spend a while on the Microsoft consent screen signing
  # in and completing MFA, so this state outlives the 5 minutes the OIDC
  # verification flows allow.
  @state_max_age 30 * 60

  @verifier_session_key :sentinel_consent_verifier

  @silent_sso_unavailable_errors ~w[consent_required interaction_required login_required]

  @invalid_response_error "The consent response was missing or invalid."

  @proof_failed_error "Firezone could not verify your Microsoft Entra tenant after consent. Please try again."

  @session_lost_error "This browser lost the consent session before the tenant check finished. Please start the consent again."

  @not_admin_error "Admin consent must be granted by a Global Administrator or a Privileged Role Administrator."

  @tenant_mismatch_error "Firezone could not confirm which Microsoft Entra tenant granted consent. Please start the consent again."

  def callback(conn, %{"state" => state} = params) do
    case OIDC.verify_verification_state(state, max_age: @state_max_age) do
      {:ok, %{type: "sentinel-log-sink"} = verification} ->
        handle_admin_consent(conn, params, verification)

      {:ok, %{type: "sentinel-log-sink-tenant-proof"} = verification} ->
        handle_tenant_proof(conn, params, verification)

      _ ->
        render_declined(conn, error_message(params))
    end
  end

  def callback(conn, params) do
    render_declined(conn, error_message(params))
  end

  # Entra reports a failed consent with `admin_consent=True` and an `error` in
  # the same redirect, so the error has to be matched first.
  defp handle_admin_consent(conn, %{"error" => _error} = params, _verification) do
    render_declined(conn, error_message(params))
  end

  defp handle_admin_consent(
         conn,
         %{"admin_consent" => "True", "tenant" => tenant_id},
         verification
       ) do
    start_tenant_proof(conn, verification, tenant_id, true)
  end

  defp handle_admin_consent(conn, params, _verification) do
    render_declined(conn, error_message(params))
  end

  defp handle_tenant_proof(conn, %{"code" => code}, verification) do
    complete_tenant_proof(conn, code, verification)
  end

  # Entra rejects the silent request when it cannot reuse the session the
  # consent screen created; retry once with an account picker.
  defp handle_tenant_proof(conn, %{"error" => error}, %{silent: true} = verification)
       when error in @silent_sso_unavailable_errors do
    start_tenant_proof(conn, verification, verification.tenant_id, false)
  end

  defp handle_tenant_proof(conn, params, _verification) do
    render_declined(conn, error_message(params))
  end

  defp start_tenant_proof(conn, verification, tenant_id, silent?) do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    state_token =
      OIDC.sign_verification_state(verification.lv_pid, "sentinel-log-sink-tenant-proof", %{
        verification_ref: verification.verification_ref,
        tenant_id: tenant_id,
        silent: silent?
      })

    with {:ok, %{config: config}} <- OIDC.setup_verification("sentinel_log_sink", []),
         {:ok, uri} <-
           OIDC.build_entra_tenant_authorization_uri(config, tenant_id, verifier, state_token,
             prompt: tenant_proof_prompt(silent?),
             redirect_uri: OIDC.sentinel_consent_url()
           ) do
      conn
      |> put_session(@verifier_session_key, verifier)
      |> redirect(external: uri)
    else
      error ->
        log_tenant_proof_error(error)
        render_declined(conn, @proof_failed_error)
    end
  end

  defp complete_tenant_proof(conn, code, verification) do
    verifier = get_session(conn, @verifier_session_key)
    conn = delete_session(conn, @verifier_session_key)

    case verify_tenant_proof(verifier, code, verification.tenant_id) do
      {:ok, tenant_id} ->
        notify_log_sink_form(verification, tenant_id)
        render(conn, :granted, tenant_id: tenant_id)

      {:error, message} ->
        render_declined(conn, message)
    end
  end

  defp verify_tenant_proof(verifier, code, tenant_id) when is_binary(verifier) do
    with {:ok, %{config: config}} <- OIDC.setup_verification("sentinel_log_sink", []),
         {:ok, %{tenant_id: verified_tenant_id, role_ids: role_ids}} <-
           OIDC.verify_entra_callback(config, code, verifier, tenant_id,
             redirect_uri: OIDC.sentinel_consent_url()
           ) do
      if OIDC.entra_setup_admin?(role_ids) do
        {:ok, verified_tenant_id}
      else
        {:error, @not_admin_error}
      end
    else
      {:error, {:invalid_entra_id_token, :tenant_mismatch}} ->
        {:error, @tenant_mismatch_error}

      error ->
        log_tenant_proof_error(error)
        {:error, @proof_failed_error}
    end
  end

  defp verify_tenant_proof(_verifier, _code, _tenant_id), do: {:error, @session_lost_error}

  # Best effort: the administrator who consents is often working in a different
  # browser than the operator who opened the form, so the page also renders the
  # verified tenant for them to copy.
  defp notify_log_sink_form(%{lv_pid: lv_pid, verification_ref: verification_ref}, tenant_id)
       when is_binary(verification_ref) do
    case OIDC.deserialize_pid(lv_pid) do
      pid when is_pid(pid) ->
        send(pid, {:sentinel_log_sink_complete, tenant_id, verification_ref})
        :ok

      _ ->
        :ok
    end
  end

  defp notify_log_sink_form(_verification, _tenant_id), do: :ok

  defp tenant_proof_prompt(true), do: "none"
  defp tenant_proof_prompt(false), do: nil

  defp render_declined(conn, error) do
    render(conn, :declined, error: error)
  end

  defp error_message(%{"error_description" => description})
       when is_binary(description) and description != "" do
    description
  end

  defp error_message(%{"error" => error}) when is_binary(error) and error != "" do
    error
  end

  defp error_message(_params), do: @invalid_response_error

  defp log_tenant_proof_error(error) do
    Logger.warning("Sentinel tenant proof failed", reason: inspect(error))
  end
end
