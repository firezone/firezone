defmodule Web.Verification do
  use Web, {:live_view, layout: {Web.Layouts, :verification}}

  alias Domain.Entra

  def mount(_params, session, socket) do
    require Logger

    # Store session data for later use in handle_params
    socket =
      assign(socket,
        session_verification_token: Map.get(session, "verification_token"),
        session_verification_code: Map.get(session, "verification_code")
      )

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    require Logger
    Logger.info("handle_params called with params: #{inspect(params)}")

    # Check if this is an Entra admin consent callback (has admin_consent or state params)
    if Map.has_key?(params, "admin_consent") || Map.has_key?(params, "tenant") do
      # Entra admin consent from Microsoft redirect
      Logger.info("Entra admin consent verification")
      handle_entra_admin_consent(params, socket)
    else
      # Check if this is an OIDC verification (from session)
      verification_token = socket.assigns[:session_verification_token]
      verification_code = socket.assigns[:session_verification_code]

      if verification_token && verification_code do
        Logger.info("OIDC verification")
        handle_oidc_verification(verification_token, verification_code, socket)
      else
        Logger.warning("No verification data found in session or params")

        {:noreply,
         assign(socket,
           page_title: "Verification",
           verified: false,
           error: "Missing verification information"
         )}
      end
    end
  end

  defp handle_oidc_verification(verification_token, verification_code, socket) do
    socket =
      assign(socket,
        page_title: "Verification",
        verified: false,
        error: nil,
        verification_type: :oidc
      )

    # Only broadcast on WebSocket connection, not initial HTTP request
    if connected?(socket) do
      # Broadcast to authentication LiveView
      Domain.PubSub.broadcast(
        "oidc-verification:#{verification_token}",
        {:oidc_verify, self(), verification_code, verification_token}
      )

      # Set a 5-second timeout for verification
      Process.send_after(self(), :timeout, 5_000)
    end

    {:noreply, socket}
  end

  defp handle_entra_admin_consent(params, socket) do
    require Logger
    Logger.info("mount_entra_admin_consent called with params: #{inspect(params)}")

    # Extract parameters from Microsoft's admin consent callback
    tenant_id = params["tenant"]
    admin_consent = params["admin_consent"]
    state = params["state"]
    error_param = params["error"]
    error_description = params["error_description"]

    # Extract token and type from state
    # Format: "entra-admin-consent:{token}" for directory sync
    # Format: "entra-verification:{token}" for auth provider
    {verification_token, verification_type} =
      case String.split(state || "", ":") do
        ["entra-admin-consent", token] -> {token, :directory_sync}
        ["entra-verification", token] -> {token, :auth_provider}
        _ -> {nil, nil}
      end

    Logger.info("Extracted token: #{verification_token}, type: #{verification_type}")

    # Determine error message
    error =
      cond do
        error_param -> error_description || error_param
        admin_consent != "True" && !error_param -> "Admin consent was not granted"
        !tenant_id && !error_param -> "Missing tenant information"
        !verification_token && !error_param -> "Invalid state parameter"
        true -> nil
      end

    socket =
      assign(socket,
        page_title: "Verification",
        verified: false,
        error: error,
        verification_type: verification_type
      )

    # Broadcast to the appropriate LiveView
    if verification_token && tenant_id && !error && verification_type do
      case verification_type do
        :directory_sync ->
          # Verify directory access with client credentials
          handle_directory_sync_verification(socket, verification_token, tenant_id)

        :auth_provider ->
          # For auth provider, just broadcast success (no additional verification needed)
          handle_auth_provider_verification(socket, verification_token, tenant_id)
      end
    else
      # Error already set in socket assigns
      {:noreply, socket}
    end
  end

  def handle_info(:success, socket) do
    require Logger
    Logger.info("Received :success message in Verification LiveView")
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
    require Logger

    # Only do verification on WebSocket connection, not initial HTTP request
    if connected?(socket) do
      # Verify directory access with client credentials
      config = Domain.Config.fetch_env!(:domain, Entra.APIClient)
      client_id = config[:client_id]

      case verify_directory_access(tenant_id, client_id) do
        {:ok, _} ->
          # Broadcast success to DirectorySync LiveView
          Logger.info(
            "Broadcasting to entra-admin-consent:#{verification_token} from PID #{inspect(self())}"
          )

          Domain.PubSub.broadcast(
            "entra-admin-consent:#{verification_token}",
            {:entra_admin_consent, self(), tenant_id, verification_token}
          )

          # Wait for response from DirectorySync LiveView
          Process.send_after(self(), :timeout, 5_000)
          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           assign(socket, error: "Failed to verify directory access: #{inspect(reason)}")}
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

      Domain.PubSub.broadcast(
        "entra-verification:#{verification_token}",
        {:entra_verification, self(), issuer, tenant_id, verification_token}
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
           ) do
      {:ok, :verified}
    end
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
