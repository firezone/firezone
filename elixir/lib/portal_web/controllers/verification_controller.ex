defmodule PortalWeb.VerificationController do
  use PortalWeb, :controller

  alias Portal.Entra

  require Logger
  @verification_ack_timeout 5_000
  @verification_ack_error "Could not confirm verification in settings. Please try again."

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
      {:ok, %{ok: true, issuer: issuer, lv_pid: lv_pid}} ->
        lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid)

        case notify_and_await_ack(lv_pid, {:oidc_verify_complete, issuer}) do
          :ok ->
            render(conn, :success)

          {:error, _reason} ->
            if lv_pid, do: send(lv_pid, {:verification_failed, @verification_ack_error})
            render(conn, :failure, error: @verification_ack_error)
        end

      {:ok, %{ok: false, error: error, lv_pid: lv_pid}} ->
        if pid = PortalWeb.OIDC.deserialize_pid(lv_pid),
          do: send(pid, {:oidc_verify_failed, error})

        render(conn, :failure, error: error)

      {:error, _} ->
        render(conn, :failure, error: "Invalid or expired verification result. Please try again.")
    end
  end

  def oidc(conn, _params) do
    render(conn, :failure, error: "Invalid verification request. Please try again.")
  end

  @doc """
  Handles an Entra verification callback (both auth_provider and directory_sync flows).
  Reads the LV PID and flow type from the signed state token passed through by OIDCController,
  extracts tenant_id from params, sends result to LV PID, and renders success or failure.
  """
  def entra(conn, %{"state" => state} = params) do
    case PortalWeb.OIDC.verify_verification_state(state) do
      {:ok, %{type: "entra-auth-provider", lv_pid: lv_pid_string}} ->
        handle_entra_auth_provider(conn, params, lv_pid_string)

      {:ok, %{type: "entra-directory-sync", lv_pid: lv_pid_string}} ->
        handle_entra_directory_sync(conn, params, lv_pid_string)

      {:error, _} ->
        render(conn, :failure, error: "Invalid or expired verification state. Please try again.")
    end
  end

  def entra(conn, _params) do
    render(conn, :failure, error: "Invalid verification request. Please try again.")
  end

  defp handle_entra_auth_provider(conn, params, lv_pid_string) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid_string)

    case extract_tenant_id(params) do
      {:ok, tenant_id} ->
        issuer = "https://login.microsoftonline.com/#{tenant_id}/v2.0"

        case notify_and_await_ack(lv_pid, {:entra_verify_complete, issuer, tenant_id}) do
          :ok -> render(conn, :success)
          {:error, _reason} -> render(conn, :failure, error: @verification_ack_error)
        end

      {:error, reason} ->
        error_message = format_consent_error(reason, params)
        if lv_pid, do: send(lv_pid, {:verification_failed, error_message})
        render(conn, :failure, error: error_message)
    end
  end

  defp handle_entra_directory_sync(conn, params, lv_pid_string) do
    lv_pid = PortalWeb.OIDC.deserialize_pid(lv_pid_string)

    case extract_tenant_id(params) do
      {:ok, tenant_id} ->
        case verify_directory_access(tenant_id) do
          {:ok, :verified} ->
            case notify_and_await_ack(lv_pid, {:entra_directory_sync_complete, tenant_id}) do
              :ok -> render(conn, :success)
              {:error, _reason} -> render(conn, :failure, error: @verification_ack_error)
            end

          error ->
            error_message = format_entra_verification_error(error)
            if lv_pid, do: send(lv_pid, {:verification_failed, error_message})
            render(conn, :failure, error: error_message)
        end

      {:error, reason} ->
        error_message = format_consent_error(reason, params)
        if lv_pid, do: send(lv_pid, {:verification_failed, error_message})
        render(conn, :failure, error: error_message)
    end
  end

  defp extract_tenant_id(%{"admin_consent" => "True", "tenant" => tenant_id})
       when is_binary(tenant_id) and tenant_id != "" do
    {:ok, tenant_id}
  end

  defp extract_tenant_id(%{"error" => _error, "error_description" => desc})
       when is_binary(desc) and desc != "" do
    {:error, desc}
  end

  defp extract_tenant_id(%{"error" => error}) when is_binary(error) and error != "" do
    {:error, error}
  end

  defp extract_tenant_id(%{"admin_consent" => admin_consent})
       when admin_consent != "True" do
    {:error, :consent_not_granted}
  end

  defp extract_tenant_id(_), do: {:error, :missing_tenant}

  defp format_consent_error(:consent_not_granted, _params), do: "Admin consent was not granted"
  defp format_consent_error(:missing_tenant, _params), do: "Missing tenant information"
  defp format_consent_error(reason, _params) when is_binary(reason), do: reason

  defp verify_directory_access(tenant_id) do
    config = Portal.Config.fetch_env!(:portal, Entra.APIClient)
    client_id = config[:client_id]

    with {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
           Entra.APIClient.get_access_token(tenant_id),
         {:ok, %Req.Response{status: 200, body: %{"value" => [service_principal | _]}}} <-
           Entra.APIClient.get_service_principal(access_token, client_id),
         {:ok, %Req.Response{status: 200, body: %{"value" => _assignments}}} <-
           Entra.APIClient.list_app_role_assignments(access_token, service_principal["id"]),
         :ok <- Entra.APIClient.test_connection(access_token) do
      {:ok, :verified}
    end
  end

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

  defp format_entra_verification_error({:error, _reason}) do
    "Failed to verify directory access."
  end

  defp entra_error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp entra_error_message(%{"error" => error}) when is_binary(error), do: error
  defp entra_error_message(_), do: nil
end
