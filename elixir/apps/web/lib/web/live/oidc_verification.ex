defmodule Web.OIDCVerification do
  use Web, {:live_view, layout: false}

  def mount(_params, session, socket) do
    verification_token = Map.get(session, "verification_token")
    verification_code = Map.get(session, "verification_code")

    socket =
      assign(socket,
        page_title: "Provider Verification",
        verified: false,
        error: nil
      )

    # Broadcast to modal on connected mount
    if connected?(socket) do
      if verification_token && verification_code do
        Domain.PubSub.broadcast(
          "oidc-verification:#{verification_token}",
          {:oidc_verify, self(), verification_code, verification_token}
        )

        # Set a 5-second timeout for verification
        Process.send_after(self(), :timeout, 5_000)

        {:ok, socket}
      else
        {:ok, assign(socket, error: "Missing verification information")}
      end
    else
      {:ok, socket}
    end
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

  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <.live_title>
          {@page_title}
        </.live_title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body class="h-screen bg-gray-50">
        <div class="min-h-screen flex items-center justify-center px-4 sm:px-6 lg:px-8">
          <div class="w-full max-w-md">
            <div class="text-center space-y-4">
              <%= if @verified do %>
                <div class="mx-auto flex h-32 w-32 items-center justify-center">
                  <.icon name="hero-check-circle" class="h-32 w-32 text-green-600" />
                </div>
                <h2 class="text-4xl font-bold tracking-tight text-gray-900">
                  Provider Verified
                </h2>
                <p class="mt-2 text-base text-gray-600">
                  You can close this window and return to the migration wizard.
                </p>
              <% else %>
                <%= if @error do %>
                  <h2 class="text-4xl font-bold tracking-tight text-gray-900">
                    Verification Failed
                  </h2>
                  <p class="mt-2 text-base text-red-600">
                    {@error}
                  </p>
                <% else %>
                  <h2 class="text-4xl font-bold tracking-tight text-gray-900">
                    Verifying Provider...
                  </h2>
                  <p class="mt-2 text-base text-gray-600">
                    Please wait while we verify your identity provider.
                  </p>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      </body>
    </html>
    """
  end
end
