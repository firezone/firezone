defmodule PortalWeb.VerificationController do
  use PortalWeb, :controller

  alias Portal.Entra

  require Logger
  @verification_ack_timeout 5_000
  @verification_ack_error "Could not confirm verification in settings. Please try again."
  @entra_admin_required_error "The Microsoft account completing setup must be a tenant-wide Global Administrator or Privileged Role Administrator."

  # Render standalone HTML pages with minimal layout (CSS only, no portal chrome)
  plug :put_root_layout, html: {PortalWeb.Layouts, :verification}
  plug :put_layout, html: false

  @doc """
  Renders the result of an OIDC verification (Google, Okta, generic OIDC).
  The code exchange and token verification are performed upstream by OIDCController,
  which signs the result and redirects here with a short-lived result token.
  Sends the outcome to the LV PID and renders success or failure.
  """
  def oidc(conn, %{"result" => result_token}) do
    case Phoenix.Token.verify(PortalWeb.Endpoint, "oidc-verification-result", result_token,
           max_age: 60
         ) do
      {:ok, result} ->
        render_oidc_result(conn, result)

      {:error, _} ->
        render_invalid_oidc_result(conn)
    end
  end

  def oidc(conn, _params) do
    render(conn, :failure, error: "Invalid verification request. Please try again.")
  end

  defp render_oidc_result(
         conn,
         %{
           ok: true,
           type: "google-directory-sync",
           domain: domain,
           lv_pid: lv_pid,
           verification_ref: verification_ref
         }
       )
       when is_binary(domain) and is_binary(verification_ref) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid)

    case notify_and_await_ack(
           lv_pid,
           {:google_directory_sync_complete, domain, verification_ref}
         ) do
      :ok -> render(conn, :success)
      {:error, _reason} -> render(conn, :failure, error: @verification_ack_error)
    end
  end

  defp render_oidc_result(
         conn,
         %{
           ok: false,
           type: "google-directory-sync",
           error: error,
           lv_pid: lv_pid,
           verification_ref: verification_ref
         }
       )
       when is_binary(error) and is_binary(verification_ref) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid)
    maybe_notify_verification_failure(lv_pid, verification_ref, error, true)
    render(conn, :failure, error: error)
  end

  defp render_oidc_result(
         conn,
         %{ok: true, issuer: issuer, lv_pid: lv_pid, verification_ref: verification_ref}
       )
       when is_binary(verification_ref) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid)

    case notify_and_await_ack(lv_pid, {:oidc_verify_complete, issuer, verification_ref}) do
      :ok -> render(conn, :success)
      {:error, _reason} -> render(conn, :failure, error: @verification_ack_error)
    end
  end

  defp render_oidc_result(conn, %{ok: true}), do: render_invalid_oidc_result(conn)

  defp render_oidc_result(conn, %{ok: false, error: error, lv_pid: lv_pid}) do
    if pid = PortalWeb.OIDC.deserialize_pid(lv_pid),
      do: send(pid, {:oidc_verify_failed, error})

    render(conn, :failure, error: error)
  end

  defp render_oidc_result(conn, _result), do: render_invalid_oidc_result(conn)

  defp render_invalid_oidc_result(conn) do
    render(conn, :failure, error: "Invalid or expired verification result. Please try again.")
  end

  @doc """
  Renders an Entra verification result. Auth-provider results contain a tenant
  identity verified from an ID token; directory-sync results are accepted only
  after this controller verifies the tenant's app-only Microsoft Graph grant.
  """
  def entra(conn, %{"result" => result_token}) do
    case Phoenix.Token.verify(PortalWeb.Endpoint, "entra-verification-result", result_token,
           max_age: 60
         ) do
      {:ok, result} ->
        render_entra_result(conn, result)

      {:error, _} ->
        render_invalid_entra_result(conn)
    end
  end

  def entra(conn, _params) do
    render(conn, :failure, error: "Invalid verification request. Please try again.")
  end

  defp render_entra_result(
         conn,
         %{
           ok: true,
           type: "entra-auth-provider",
           issuer: issuer,
           tenant_id: tenant_id,
           role_ids: role_ids,
           lv_pid: lv_pid_string,
           verification_ref: verification_ref
         }
       )
       when is_binary(issuer) and is_binary(tenant_id) and is_list(role_ids) and
              is_binary(verification_ref) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid_string)

    if PortalWeb.OIDC.entra_setup_admin?(role_ids) do
      case notify_and_await_ack(
             lv_pid,
             {:entra_verify_complete, issuer, tenant_id, verification_ref}
           ) do
        :ok -> render(conn, :success)
        {:error, _reason} -> render(conn, :failure, error: @verification_ack_error)
      end
    else
      maybe_notify_verification_failure(
        lv_pid,
        verification_ref,
        @entra_admin_required_error,
        true
      )

      render(conn, :failure, error: @entra_admin_required_error)
    end
  end

  defp render_entra_result(
         conn,
         %{
           ok: true,
           type: "entra-directory-sync",
           tenant_id: tenant_id,
           principal_id: principal_id,
           lv_pid: lv_pid_string,
           verification_ref: verification_ref
         }
       )
       when is_binary(tenant_id) and is_binary(principal_id) and is_binary(verification_ref) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid_string)

    case run_entra_directory_sync_verification(
           tenant_id,
           principal_id,
           lv_pid,
           verification_ref
         ) do
      :ok ->
        render(conn, :success)

      {:error, error_message, notify_lv?} ->
        maybe_notify_verification_failure(lv_pid, verification_ref, error_message, notify_lv?)
        render(conn, :failure, error: error_message)
    end
  end

  defp render_entra_result(
         conn,
         %{
           ok: false,
           error: error,
           lv_pid: lv_pid_string,
           verification_ref: verification_ref
         }
       )
       when is_binary(error) and is_binary(verification_ref) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid_string)
    maybe_notify_verification_failure(lv_pid, verification_ref, error, true)
    render(conn, :failure, error: error)
  end

  defp render_entra_result(conn, _result), do: render_invalid_entra_result(conn)

  defp render_invalid_entra_result(conn) do
    render(conn, :failure, error: "Invalid or expired verification result. Please try again.")
  end

  defp maybe_notify_verification_failure(lv_pid, verification_ref, error, true)
       when is_pid(lv_pid) do
    send(lv_pid, {:verification_failed, error, verification_ref})
  end

  defp maybe_notify_verification_failure(_lv_pid, _verification_ref, _error, _notify_lv?),
    do: :ok

  defp run_entra_directory_sync_verification(
         tenant_id,
         principal_id,
         lv_pid,
         verification_ref
       ) do
    with {:ok, :verified} <- verify_directory_access_for_verification(tenant_id, principal_id),
         :ok <-
           notify_and_await_ack(
             lv_pid,
             {:entra_directory_sync_complete, tenant_id, verification_ref}
           ) do
      :ok
    else
      {:error, reason} when reason in [:ack_timeout, :no_receiver] ->
        ack_failure_result()

      {:error, {:directory_verification_error, reason}} ->
        {:error, format_entra_verification_error(reason), true}
    end
  end

  defp verify_directory_access_for_verification(tenant_id, principal_id) do
    case verify_directory_access(tenant_id, principal_id) do
      {:ok, :verified} = result -> result
      error -> {:error, {:directory_verification_error, error}}
    end
  end

  defp ack_failure_result, do: {:error, @verification_ack_error, false}

  defp verify_directory_access(tenant_id, principal_id) do
    config = Portal.Config.fetch_env!(:portal, Entra.APIClient)
    client_id = config[:client_id]

    with {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
           Entra.APIClient.get_access_token(tenant_id),
         {:ok, %Req.Response{status: 200, body: %{"value" => [service_principal | _]}}} <-
           Entra.APIClient.get_service_principal(access_token, client_id),
         {:ok, %Req.Response{status: 200, body: %{"value" => _assignments}}} <-
           Entra.APIClient.list_app_role_assignments(access_token, service_principal["id"]),
         {:ok, %Req.Response{status: 200, body: %{"value" => directory_roles}}} <-
           Entra.APIClient.list_transitive_directory_roles(access_token, principal_id),
         :ok <- verify_entra_setup_admin_role(directory_roles),
         :ok <- Entra.APIClient.test_connection(access_token) do
      {:ok, :verified}
    end
  end

  defp verify_entra_setup_admin_role(directory_roles) when is_list(directory_roles) do
    role_ids = Enum.map(directory_roles, & &1["roleTemplateId"])

    if PortalWeb.OIDC.entra_setup_admin?(role_ids),
      do: :ok,
      else: {:error, :entra_setup_admin_required}
  end

  defp verify_entra_setup_admin_role(_directory_roles),
    do: {:error, :entra_setup_admin_required}

  defp notify_and_await_ack(nil, _msg), do: {:error, :no_receiver}

  defp notify_and_await_ack(pid, msg) do
    ref = make_ref()
    ack_msg = Tuple.insert_at(msg, tuple_size(msg), {self(), ref})
    send(pid, ack_msg)

    receive do
      {:verification_ack, ^ref} -> :ok
    after
      @verification_ack_timeout -> {:error, :ack_timeout}
    end
  end

  defp format_entra_verification_error({:ok, %Req.Response{status: 401, body: body}}) do
    error_message = entra_error_message(body)

    "Unauthorized: #{error_message || "Invalid credentials"}. " <>
      "Ensure the application has the required API permissions."
  end

  defp format_entra_verification_error({:ok, %Req.Response{status: 403, body: body}}) do
    error_message = entra_error_message(body) || "forbidden"

    "Access denied: #{error_message}. " <>
      "Ensure the application has Directory.Read.All and Group.Read.All permissions with admin consent. " <>
      "If you just granted access, please wait a minute or two and try again."
  end

  defp format_entra_verification_error({:ok, %Req.Response{status: status, body: body}})
       when status >= 400 do
    error_message = entra_error_message(body) || body["error_description"]
    "Verification failed (HTTP #{status}): #{error_message || "Unknown error"}"
  end

  defp format_entra_verification_error({:error, %Req.TransportError{reason: :nxdomain}}) do
    "Failed to verify directory access: DNS lookup failed. Please verify the domain and try again."
  end

  defp format_entra_verification_error({:error, %Req.TransportError{reason: :econnrefused}}) do
    "Failed to verify directory access: Connection refused by the remote server."
  end

  defp format_entra_verification_error({:error, %Req.TransportError{reason: :timeout}}) do
    "Failed to verify directory access: Connection timed out."
  end

  defp format_entra_verification_error({:error, %Req.TransportError{}}) do
    "Failed to verify directory access due to a network error."
  end

  defp format_entra_verification_error({:error, :entra_setup_admin_required}),
    do: @entra_admin_required_error

  defp format_entra_verification_error({:error, _reason}) do
    "Failed to verify directory access."
  end

  defp entra_error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp entra_error_message(%{"error" => error}) when is_binary(error), do: error
  defp entra_error_message(_), do: nil
end
