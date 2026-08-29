defmodule PortalWeb.OAuthConsent do
  @moduledoc """
  The screen where a person grants an app access to their account.

  The request is checked once on mount and then kept in the socket. What is
  granted is what the server validated, so nothing about the request is read
  back from the browser and there is nothing to re-check on the way in.

  Errors are delivered two different ways on purpose. Until the client and its
  redirect URI have been checked, nothing may be sent to that URI, because doing
  so would make this endpoint a redirector for any URL an attacker chose. Those
  failures render a page instead.
  """

  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :standalone}}

  alias Portal.OAuth
  alias Portal.Scope

  def mount(params, _session, socket) do
    socket = assign(socket, page_title: "Connect an app")

    case OAuth.validate_client(params) do
      {:ok, client, redirect_uri} ->
        mount_request(socket, params, client, redirect_uri)

      {:error, _error, description} ->
        {:ok, assign(socket, request: nil, description: description)}
    end
  end

  def render(%{request: nil} = assigns) do
    ~H"""
    <PortalWeb.OAuthHTML.error description={@description} />
    """
  end

  def render(assigns) do
    ~H"""
    <.flash kind={:error} flash={@flash} />

    <.oauth_client_header client={@request.client} />

    <p class="text-sm text-body mb-6">
      Select the permissions
      <span class="font-semibold text-heading">{@request.client.client_name}</span>
      should be able to access in the
      <span class="font-semibold text-heading">{@account.name}</span>
      organization on behalf of
      <span class="font-semibold text-heading">{@subject.actor.name}</span>.
    </p>

    <.form for={%{}} phx-submit="allow">
      <.scope_picker scopes={@scopes} field_name="scope[]" error={@error} />

      <p class="text-xs text-subtle leading-relaxed my-6">
        You can disconnect this app at any time from Your settings, which immediately
        stops any access it still holds.
      </p>

      <div class="flex gap-2.5">
        <button
          type="button"
          phx-click="deny"
          class="flex-1 px-4 py-2.5 rounded border-2 border-border bg-surface text-sm font-semibold text-heading hover:border-brand transition-all duration-150"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="flex-1 px-4 py-2.5 rounded border-2 border-brand bg-brand text-sm font-semibold text-white hover:opacity-90 transition-all duration-150"
        >
          Connect
        </button>
      </div>
    </.form>

    <p class="text-xs text-subtle text-center mt-6 break-all">
      Returning you to {redirect_host(@request.redirect_uri)}
    </p>
    """
  end

  def handle_event("select_scopes", %{"preset" => preset}, socket) do
    {:noreply, assign(socket, scopes: Scope.preset(preset), error: nil)}
  end

  def handle_event("deny", _params, socket) do
    {:noreply, decline(socket)}
  end

  def handle_event("allow", params, socket) do
    request = socket.assigns.request

    case params |> Map.get("scope", []) |> Scope.encode() |> Scope.parse() do
      {:ok, scopes} ->
        grant(socket, %{request | scopes: scopes})

      {:error, :missing} ->
        {:noreply,
         assign(socket, scopes: [], error: "Select at least one permission to continue.")}

      {:error, {:unknown, unknown}} ->
        {:noreply,
         redirect_to_client(socket, request.redirect_uri, request.state, %{
           "error" => "invalid_scope",
           "error_description" => "Unknown scopes: #{Enum.join(unknown, ", ")}"
         })}
    end
  end

  defp mount_request(socket, params, client, redirect_uri) do
    case OAuth.validate_request(params, client, redirect_uri, OAuth.resource_uri()) do
      {:ok, request} ->
        {:ok, assign(socket, request: request, scopes: request.scopes, error: nil)}

      {:error, error, description} ->
        {:ok,
         redirect_to_client(socket, redirect_uri, params["state"], %{
           "error" => error,
           "error_description" => description
         })}
    end
  end

  defp grant(socket, request) do
    case OAuth.consent(request, socket.assigns.subject) do
      {:ok, code} ->
        {:noreply, redirect_to_client(socket, request.redirect_uri, request.state, %{"code" => code})}

      {:error, _changeset} ->
        {:noreply,
         redirect_to_client(socket, request.redirect_uri, request.state, %{
           "error" => "server_error",
           "error_description" => "The authorization could not be recorded."
         })}
    end
  end

  defp decline(socket) do
    request = socket.assigns.request

    redirect_to_client(socket, request.redirect_uri, request.state, %{
      "error" => "access_denied",
      "error_description" => "The request was declined."
    })
  end

  # `iss` lets a client that talks to several authorization servers detect a
  # response that came back from the wrong one.
  defp redirect_to_client(socket, redirect_uri, state, params) do
    uri = URI.parse(redirect_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(params)
      |> Map.put("state", state)
      |> Map.put("iss", PortalWeb.Endpoint.url())
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    redirect(socket, external: URI.to_string(%{uri | query: query}))
  end

  defp redirect_host(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{host: host, port: port} when is_binary(host) -> "#{host}:#{port}"
      _other -> redirect_uri
    end
  end
end
