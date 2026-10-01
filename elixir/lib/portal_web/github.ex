defmodule PortalWeb.GitHub do
  @moduledoc """
  OAuth 2.0 client for signing in with GitHub.

  GitHub does not implement OpenID Connect, so there is no ID token to verify.
  Instead the authorization code is exchanged for an access token that reads the
  user and their email addresses from the GitHub API. The result is shaped like
  OIDC claims so the rest of the sign-in and sign-up flows can treat GitHub like
  any other provider.
  """

  # /user needs no scope for the public profile; user:email reads /user/emails.
  @scope "user:email"
  @api_version "2026-03-10"

  # GitHub's largest page size. A page limit keeps a misbehaving response from
  # looping forever; 1,000 addresses is far beyond any real account.
  @emails_per_page 100
  @max_email_pages 10

  @type config :: %{
          required(:provider) => :github,
          required(:client_id) => String.t() | nil,
          required(:client_secret) => String.t() | nil,
          required(:redirect_uri) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Returns the GitHub OAuth App configuration with the redirect URI set.
  """
  @spec config(String.t()) :: config()
  def config(redirect_uri) do
    Portal.Config.fetch_env!(:portal, Portal.GitHub.AuthProvider)
    |> Enum.into(%{provider: :github, redirect_uri: redirect_uri})
  end

  @doc """
  Builds the GitHub authorization URI for an authorization code flow with PKCE.

  Options:
  - `:prompt` - Set to `"select_account"` to show the GitHub account picker
  """
  @spec authorization_uri(config(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :missing_client_id}
  def authorization_uri(config, state, verifier, opts \\ [])

  def authorization_uri(%{client_id: client_id} = config, state, verifier, opts)
      when is_binary(client_id) and client_id != "" do
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    params =
      %{
        client_id: client_id,
        redirect_uri: config.redirect_uri,
        scope: @scope,
        state: state,
        code_challenge: challenge,
        code_challenge_method: "S256"
      }
      |> maybe_put(:prompt, Keyword.get(opts, :prompt))

    {:ok, config.authorize_endpoint <> "?" <> URI.encode_query(params)}
  end

  def authorization_uri(_config, _state, _verifier, _opts), do: {:error, :missing_client_id}

  @doc """
  Checks the callback's issuer, exchanges the authorization code and reads the
  GitHub user.

  GitHub sends its issuer as the `iss` callback parameter (RFC 9207) and
  advertises that it always does, so a missing or different value means the
  response did not come from GitHub and is rejected before the code is used.

  Returns `{:ok, claims, {:ok, %{}}}` to match `PortalWeb.OIDC.verify_callback/4`.
  The claims carry the primary email in `"email"`, whether GitHub verified it in
  `"email_verified"`, and every verified address in `"verified_emails"`.
  """
  @spec verify_callback(config(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map(), {:ok, map()}} | {:error, term()}
  def verify_callback(config, code, verifier, iss) do
    with :ok <- verify_issuer(iss),
         {:ok, access_token} <- exchange_code(config, code, verifier),
         {:ok, user} <- fetch(config, access_token, "/user"),
         {:ok, emails} <- fetch_emails(config, access_token),
         {:ok, claims} <- build_claims(user, emails) do
      {:ok, claims, {:ok, %{}}}
    end
  end

  defp verify_issuer(iss) do
    if iss == Portal.GitHub.AuthProvider.issuer() do
      :ok
    else
      {:error, :github_issuer_mismatch}
    end
  end

  defp exchange_code(config, code, verifier) do
    form = %{
      client_id: config.client_id,
      client_secret: config.client_secret,
      code: code,
      code_verifier: verifier,
      redirect_uri: config.redirect_uri
    }

    [url: config.token_endpoint, form: form, headers: [accept: "application/json"]]
    |> Keyword.merge(config[:req_opts] || [])
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}}
      when is_binary(token) and token != "" ->
        {:ok, token}

      # GitHub reports a rejected code with a 200 response and an error body.
      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:github_oauth_error, error}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(config, access_token, path) do
    with {:ok, response} <- get(config, access_token, config.api_endpoint <> path) do
      {:ok, response.body}
    end
  end

  # The email list is paginated, and the address that matches an actor may be on
  # any page, so every page is read.
  defp fetch_emails(config, access_token) do
    url = config.api_endpoint <> "/user/emails?per_page=#{@emails_per_page}"
    fetch_email_pages(config, access_token, url, [], @max_email_pages)
  end

  defp fetch_email_pages(_config, _access_token, _url, emails, 0), do: {:ok, emails}

  defp fetch_email_pages(config, access_token, url, emails, pages_left) do
    case get(config, access_token, url) do
      {:ok, %Req.Response{body: page} = response} when is_list(page) ->
        emails = emails ++ page

        case next_page_url(config, response) do
          nil -> {:ok, emails}
          next_url -> fetch_email_pages(config, access_token, next_url, emails, pages_left - 1)
        end

      {:ok, %Req.Response{}} ->
        {:error, :invalid_github_user}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only follows links back to the GitHub API, so the access token is never sent
  # to another host.
  defp next_page_url(config, response) do
    with [link | _] <- Req.Response.get_header(response, "link"),
         [_, next_url] <- Regex.run(~r/<([^>]+)>;\s*rel="next"/, link),
         true <- same_origin?(next_url, config.api_endpoint) do
      next_url
    else
      _ -> nil
    end
  end

  defp same_origin?(url, api_endpoint) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    api = URI.parse(api_endpoint)
    {scheme, host, port} == {api.scheme, api.host, api.port}
  end

  defp get(config, access_token, url) do
    [
      url: url,
      auth: {:bearer, access_token},
      headers: [accept: "application/vnd.github+json", x_github_api_version: @api_version]
    ]
    |> Keyword.merge(config[:req_opts] || [])
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_claims(%{"id" => id} = user, emails) when is_integer(id) and is_list(emails) do
    emails = Enum.filter(emails, &valid_email_entry?/1)
    primary = Enum.find(emails, & &1["primary"])

    claims = %{
      "iss" => Portal.GitHub.AuthProvider.issuer(),
      "sub" => Integer.to_string(id),
      "email" => primary && primary["email"],
      "email_verified" => primary != nil and primary["verified"] == true,
      "verified_emails" => for(%{"verified" => true, "email" => email} <- emails, do: email),
      "name" => user["name"],
      "preferred_username" => user["login"],
      "profile" => user["html_url"],
      "picture" => user["avatar_url"]
    }

    {:ok, claims}
  end

  defp build_claims(_user, _emails), do: {:error, :invalid_github_user}

  defp valid_email_entry?(%{"email" => email}) when is_binary(email), do: true
  defp valid_email_entry?(_entry), do: false

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
