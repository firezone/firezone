defmodule PortalWeb.Verification do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :verification}}

  alias Portal.Entra

  def mount(_params, session, socket) do
    # Store verification data from session - uses a single :verification key
    # that contains all verification info with a :type discriminator
    verification = Map.get(session, "verification", %{})

    {:ok, assign(socket, verification: verification)}
  end

  def handle_params(_params, _uri, socket) do
    case socket.assigns.verification do
      %{"type" => "oidc", "token" => token, "code" => code} ->
        handle_oidc_verification(token, code, socket)

      %{"type" => "entra"} = verification ->
        handle_entra_verification(verification, socket)

      _ ->
        {:noreply,
         assign(socket,
           page_title: "Verification",
           verified: false,
           error: "Missing verification information"
         )}
    end
  end

  defp handle_oidc_verification(verification_token, verification_code, socket) do
    socket = assign(socket, page_title: "Verification", verified: false, error: nil)

    # Only broadcast on WebSocket connection, not initial HTTP request
    if connected?(socket) do
      # Broadcast to authentication LiveView
      Portal.PubSub.broadcast(
        "oidc-verification:#{verification_token}",
        {:oidc_verify, self(), verification_code, verification_token}
      )

      # Set a 5-second timeout for verification
      Process.send_after(self(), :timeout, 5_000)
    end

    {:noreply, socket}
  end

  defp handle_entra_verification(verification, socket) do
    token = verification["token"]
    admin_consent = verification["admin_consent"]
    tenant_id = verification["tenant_id"]
    entra_type = verification["entra_type"]
    error_param = verification["error"]
    error_description = verification["error_description"]

    error = detect_consent_error(admin_consent, tenant_id, token, error_param, error_description)

    socket = assign(socket, page_title: "Verification", verified: false, error: error)

    if token && tenant_id && !error && entra_type do
      dispatch_entra_verification(socket, entra_type, token, tenant_id)
    else
      {:noreply, socket}
    end
  end

  defp detect_consent_error(admin_consent, tenant_id, token, error_param, error_description) do
    cond do
      error_param -> error_description || error_param
      admin_consent != "True" -> "Admin consent was not granted"
      !tenant_id -> "Missing tenant information"
      !token -> "Invalid state parameter"
      true -> nil
    end
  end

  defp dispatch_entra_verification(socket, "directory_sync", token, tenant_id) do
    handle_directory_sync_verification(socket, token, tenant_id)
  end

  defp dispatch_entra_verification(socket, "auth_provider", token, tenant_id) do
    handle_auth_provider_verification(socket, token, tenant_id)
  end

  def handle_info(:success, socket) do
    {:noreply, assign(socket, verified: true)}
  end

  def handle_info({:error, reason}, socket) do
    {:noreply, assign(socket, error: inspect(reason))}
  end

  def handle_info(:timeout, socket) do
    # Only show timeout error if not already verified or errored
    if !socket.assigns.verified && !socket.assigns.error do
      {:noreply, assign(socket, error: "Verification timed out. Please try again.")}
    else
      {:noreply, socket}
    end
  end

  defp handle_directory_sync_verification(socket, verification_token, tenant_id) do
    # Only do verification on WebSocket connection, not initial HTTP request
    if connected?(socket) do
      # Verify directory access with client credentials
      config = Portal.Config.fetch_env!(:portal, Entra.APIClient)
      client_id = config[:client_id]

      case verify_directory_access(tenant_id, client_id) do
        {:ok, :verified} ->
          # Broadcast success to DirectorySync LiveView
          Portal.PubSub.broadcast(
            "entra-admin-consent:#{verification_token}",
            {:entra_admin_consent, self(), nil, tenant_id, verification_token}
          )

          # Wait for response from DirectorySync LiveView
          Process.send_after(self(), :timeout, 5_000)
          {:noreply, socket}

        error ->
          error_message = format_entra_verification_error(error)
          {:noreply, assign(socket, error: error_message)}
      end
    else
      # On initial HTTP request, just return socket
      {:noreply, socket}
    end
  end

  defp handle_auth_provider_verification(socket, verification_token, tenant_id) do
    # Only do verification on WebSocket connection, not initial HTTP request
    if connected?(socket) do
      # For auth provider, broadcast success to Authentication LiveView
      issuer = "https://login.microsoftonline.com/#{tenant_id}/v2.0"

      Portal.PubSub.broadcast(
        "entra-verification:#{verification_token}",
        {:entra_admin_consent, self(), issuer, tenant_id, verification_token}
      )

      # Wait for response from Authentication LiveView
      Process.send_after(self(), :timeout, 5_000)
      {:noreply, socket}
    else
      # On initial HTTP request, just return socket
      {:noreply, socket}
    end
  end

  defp verify_directory_access(tenant_id, client_id) do
    with {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
           Entra.APIClient.get_access_token(tenant_id),
         {:ok, %Req.Response{status: 200, body: %{"value" => [service_principal | _]}}} <-
           Entra.APIClient.get_service_principal(access_token, client_id),
         {:ok, %Req.Response{status: 200, body: %{"value" => _assignments}}} <-
           Entra.APIClient.list_app_role_assignments(
             access_token,
             service_principal["id"]
           ),
         :ok <- Entra.APIClient.test_connection(access_token) do
      {:ok, :verified}
    end
  end

  defp format_entra_verification_error({:ok, %Req.Response{status: 401, body: body}}) do
    error_message = get_in(body, ["error", "message"])

    "Unauthorized: #{error_message || "Invalid credentials"}. " <>
      "Ensure the application has the required API permissions."
  end

  defp format_entra_verification_error({:ok, %Req.Response{status: 403, body: body}}) do
    error_message = get_in(body, ["error", "message"]) || "forbidden"

    "Access denied: #{error_message}. " <>
      "Ensure the application has Directory.Read.All and Group.Read.All permissions with admin consent. " <>
      "If you just granted access, please wait a minute or two and try again."
  end

  defp format_entra_verification_error({:ok, %Req.Response{status: status, body: body}})
       when status >= 400 do
    error_message = get_in(body, ["error", "message"]) || body["error_description"]
    "Verification failed (HTTP #{status}): #{error_message || "Unknown error"}"
  end

  defp format_entra_verification_error({:error, reason}) do
    "Failed to verify directory access: #{inspect(reason)}"
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center px-4 sm:px-6 lg:px-8 bg-gray-50">
      <div class="w-full max-w-md">
        <div class="text-center space-y-4">
          <%= if @verified do %>
            <div class="mx-auto flex h-32 w-32 items-center justify-center">
              <.icon name="hero-check-circle" class="h-32 w-32 text-green-600" />
            </div>
            <h2 class="text-4xl font-bold tracking-tight text-gray-900">
              Verification Successful
            </h2>
            <p class="mt-2 text-base text-gray-600">
              You can close this window and return to the application.
            </p>
          <% else %>
            <%= if @error do %>
              <div class="mx-auto flex h-32 w-32 items-center justify-center">
                <.icon name="hero-exclamation-circle" class="h-32 w-32 text-red-600" />
              </div>
              <h2 class="text-4xl font-bold tracking-tight text-gray-900">
                Verification Failed
              </h2>
              <p class="mt-2 text-base text-red-600">
                {@error}
              </p>
            <% else %>
              <div class="mx-auto flex h-32 w-32 items-center justify-center">
                <.icon
                  name="hero-check-circle"
                  class="transition-colors h-32 w-32 text-neutral-100"
                />
              </div>
              <h2 class="text-4xl font-bold tracking-tight text-gray-900">
                Verifying...
              </h2>
              <p class="mt-2 text-base text-gray-600">
                Please wait while we verify your information.
              </p>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
