defmodule PortalWeb.OAuthConsent do
  @moduledoc """
  The screen where a person grants an app access to their account.

  The request is checked once on mount and then kept in the socket. The browser
  posts the person's selection, which is checked again against the validated
  request before a grant is recorded.

  Errors are delivered two different ways on purpose. Until the client and its
  redirect URI have been checked, nothing may be sent to that URI, because doing
  so would make this endpoint a redirector for any URL an attacker chose. Those
  failures render a page instead.
  """

  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :standalone}}

  alias Portal.Authentication
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
      <.scope_picker
        scopes={@scopes}
        allowed_scopes={@request.requested_scopes}
        field_name="scope[]"
        error={@error}
      />

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
    scopes = within_request(Scope.preset(preset), socket.assigns.request)
    {:noreply, assign(socket, scopes: scopes, error: nil)}
  end

  def handle_event("deny", _params, socket) do
    {:noreply, decline(socket)}
  end

  def handle_event("allow", params, socket) do
    request = socket.assigns.request

    case params |> Map.get("scope", []) |> Scope.encode() |> Scope.parse() do
      {:ok, scopes} ->
        if within_request?(scopes, request) do
          grant(socket, %{request | scopes: scopes})
        else
          {:noreply,
           assign(socket,
             scopes: within_request(scopes, request),
             error: "Select only permissions requested by this app."
           )}
        end

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

  defp within_request(scopes, request) do
    Enum.filter(Scope.expand(scopes), &(&1 in request.requested_scopes))
  end

  defp within_request?(scopes, request) do
    scopes
    |> MapSet.new()
    |> MapSet.subset?(MapSet.new(request.requested_scopes))
  end

  # Nothing disconnects this socket when its session expires, so it is checked
  # again here rather than only on mount.
  defp grant(socket, request) do
    subject = socket.assigns.subject

    with {:ok, _session} <-
           Authentication.fetch_portal_session(subject.account.id, subject.credential.id),
         :ok <-
           Authentication.consume_portal_session(
             subject.account.id,
             subject.actor.id,
             subject.credential.id
           ),
         {:ok, code} <- OAuth.consent(request, subject) do
      {:noreply, redirect_to_client(socket, request.redirect_uri, request.state, %{"code" => code})}
    else
      {:error, :not_found} ->
        {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/sign_in?as=oauth")}

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
    subject = socket.assigns.subject

    # Cancel means the step-up proof is abandoned, not left behind for another
    # authorization request in this browser to reuse.
    Authentication.consume_portal_session(
      subject.account.id,
      subject.actor.id,
      subject.credential.id
    )

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

    redirect(socket, external: external_destination(URI.to_string(%{uri | query: query})))
  end

  # LiveView refuses a scheme it does not recognise when it is handed a plain
  # string, and a native app registers exactly that (RFC 8252 section 7.1), so
  # the scheme is passed apart from the rest to say it is deliberate. Only the
  # schemes a client's metadata document is allowed to carry reach this point.
  defp external_destination(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        url

      %URI{scheme: scheme} when is_binary(scheme) ->
        {scheme, String.replace_prefix(url, scheme <> ":", "")}

      _other ->
        url
    end
  end

  defp redirect_host(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{host: host, port: port} when is_binary(host) -> "#{host}:#{port}"
      _other -> redirect_uri
    end
  end
end
