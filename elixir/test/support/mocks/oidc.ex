defmodule PortalWeb.Mocks.OIDC do
  @moduledoc """
  Mock server for OpenID Connect discovery and token endpoints.
  Uses Req.Test to simulate an OIDC provider for testing.

  ## Usage

  In your test setup:

      Mocks.OIDC.stub_discovery_document()

  For custom token exchange responses:

      Mocks.OIDC.set_token_response(%{"access_token" => "...", "id_token" => "..."})

  For custom userinfo responses:

      Mocks.OIDC.set_userinfo_response(%{"sub" => "...", "email" => "..."})

  For error scenarios:

      Mocks.OIDC.set_token_error(400, %{"error" => "invalid_grant"})
  """

  @mock_endpoint "https://mock.oidc.test"

  def mock_endpoint, do: @mock_endpoint

  def discovery_document_uri, do: "#{@mock_endpoint}/.well-known/openid-configuration"

  @doc """
  Sets up a Req.Test stub for a complete OIDC server.
  Returns the mock endpoint URL for use in tests.
  """
  def stub_discovery_document do
    test_pid = self()

    Req.Test.stub(PortalWeb.OIDC, fn conn ->
      handle_request(conn, test_pid)
    end)

    @mock_endpoint
  end

  @doc """
  Sets up a Req.Test stub that returns a specific HTTP error for the discovery document.
  """
  def stub_discovery_error(status, body \\ "") do
    Req.Test.stub(PortalWeb.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)

    @mock_endpoint
  end

  @doc """
  Sets up a Req.Test stub that returns invalid JSON for the discovery document.
  """
  def stub_invalid_json(body \\ "this is not json{") do
    Req.Test.stub(PortalWeb.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    @mock_endpoint
  end

  @doc """
  Sets up a Req.Test stub that simulates a connection refused error.
  """
  def stub_connection_refused do
    Req.Test.stub(PortalWeb.OIDC, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    @mock_endpoint
  end

  @doc """
  Sets up a Req.Test stub that simulates a DNS lookup failure (nxdomain).
  """
  def stub_dns_error do
    Req.Test.stub(PortalWeb.OIDC, fn conn ->
      Req.Test.transport_error(conn, :nxdomain)
    end)

    @mock_endpoint
  end

  @doc """
  Sets a custom token exchange response. Call this before making the token exchange request.
  The response should be a map that will be JSON encoded.
  """
  def set_token_response(response) do
    Process.put(:oidc_mock_token_response, {:ok, response})
  end

  @doc """
  Sets a token exchange error response. Call this before making the token exchange request.
  """
  def set_token_error(status, body) do
    Process.put(:oidc_mock_token_response, {:error, status, body})
  end

  @doc """
  Sets a custom userinfo response. Call this before making the userinfo request.
  The response should be a map that will be JSON encoded.
  """
  def set_userinfo_response(response) do
    Process.put(:oidc_mock_userinfo_response, {:ok, response})
  end

  @doc """
  Sets a userinfo error response. Call this before making the userinfo request.
  """
  def set_userinfo_error(status, body) do
    Process.put(:oidc_mock_userinfo_response, {:error, status, body})
  end

  @doc """
  Clears any custom token or userinfo responses.
  """
  def clear_custom_responses do
    Process.delete(:oidc_mock_token_response)
    Process.delete(:oidc_mock_userinfo_response)
  end

  defp handle_request(conn, test_pid) do
    conn = fetch_conn_params(conn)
    send(test_pid, {:oidc_request, conn.request_path, conn})

    case conn.request_path do
      "/.well-known/openid-configuration" ->
        Req.Test.json(conn, discovery_document())

      "/.well-known/jwks.json" ->
        Req.Test.json(conn, %{"keys" => [jwks()]})

      "/oauth/token" ->
        handle_token_request(conn, test_pid)

      "/userinfo" ->
        handle_userinfo_request(conn, test_pid)

      _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"error": "not_found"}))
    end
  end

  defp handle_token_request(conn, test_pid) do
    case Process.get(:oidc_mock_token_response) do
      {:ok, response} ->
        # Clear after use so subsequent requests get default behavior
        Process.delete(:oidc_mock_token_response)
        Req.Test.json(conn, response)

      {:error, status, body} ->
        Process.delete(:oidc_mock_token_response)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, JSON.encode!(body))

      nil ->
        # Check if the test process has a custom response set
        case get_from_test_process(test_pid, :oidc_mock_token_response) do
          {:ok, response} ->
            Req.Test.json(conn, response)

          {:error, status, body} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(status, JSON.encode!(body))

          nil ->
            # Default response
            Req.Test.json(conn, %{
              "access_token" => "test_access_token",
              "token_type" => "Bearer",
              "expires_in" => 3600,
              "id_token" => sign_openid_connect_token(default_claims())
            })
        end
    end
  end

  defp handle_userinfo_request(conn, test_pid) do
    case Process.get(:oidc_mock_userinfo_response) do
      {:ok, response} ->
        Process.delete(:oidc_mock_userinfo_response)
        Req.Test.json(conn, response)

      {:error, status, body} ->
        Process.delete(:oidc_mock_userinfo_response)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, JSON.encode!(body))

      nil ->
        # Check if the test process has a custom response set
        case get_from_test_process(test_pid, :oidc_mock_userinfo_response) do
          {:ok, response} ->
            Req.Test.json(conn, response)

          {:error, status, body} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(status, JSON.encode!(body))

          nil ->
            # Default response
            Req.Test.json(conn, default_userinfo())
        end
    end
  end

  defp get_from_test_process(test_pid, key) do
    # Try to get the value from the test process's dictionary
    # This is used when the stub runs in a different process than the test
    try do
      {:dictionary, dict} = Process.info(test_pid, :dictionary)
      Keyword.get(dict, key)
    rescue
      _ -> nil
    end
  end

  def discovery_document, do: discovery_document(@mock_endpoint)

  def discovery_document(port) when is_integer(port),
    do: discovery_document("http://localhost:#{port}")

  def discovery_document(base_url) do
    %{
      "issuer" => "#{base_url}/",
      "authorization_endpoint" => "#{base_url}/authorize",
      "token_endpoint" => "#{base_url}/oauth/token",
      "client_authorization_endpoint" => "#{base_url}/oauth/client/code",
      "userinfo_endpoint" => "#{base_url}/userinfo",
      "mfa_challenge_endpoint" => "#{base_url}/mfa/challenge",
      "jwks_uri" => "#{base_url}/.well-known/jwks.json",
      "registration_endpoint" => "#{base_url}/oidc/register",
      "revocation_endpoint" => "#{base_url}/oauth/revoke",
      "end_session_endpoint" => "https://example.com",
      "scopes_supported" => [
        "openid",
        "profile",
        "offline_access",
        "name",
        "given_name",
        "family_name",
        "nickname",
        "email",
        "email_verified",
        "picture",
        "created_at",
        "identities",
        "phone",
        "address"
      ],
      "response_types_supported" => [
        "code",
        "token",
        "id_token",
        "code token",
        "code id_token",
        "token id_token",
        "code token id_token"
      ],
      "code_challenge_methods_supported" => [
        "S256",
        "plain"
      ],
      "response_modes_supported" => [
        "query",
        "fragment",
        "form_post"
      ],
      "subject_types_supported" => [
        "public"
      ],
      "id_token_signing_alg_values_supported" => [
        "HS256",
        "RS256"
      ],
      "token_endpoint_auth_methods_supported" => [
        "client_secret_basic",
        "client_secret_post"
      ],
      "claims_supported" => [
        "aud",
        "auth_time",
        "created_at",
        "email",
        "email_verified",
        "exp",
        "family_name",
        "given_name",
        "iat",
        "identities",
        "iss",
        "name",
        "nickname",
        "phone_number",
        "picture",
        "sub"
      ],
      "request_uri_parameter_supported" => false,
      "request_parameter_supported" => false
    }
  end

  def default_claims, do: default_claims(@mock_endpoint)

  def default_claims(port) when is_integer(port), do: default_claims("http://localhost:#{port}")

  def default_claims(base_url) do
    %{
      "iss" => "#{base_url}/",
      "sub" => "353690423699814251281",
      "aud" => "test-client",
      "exp" => System.os_time(:second) + 3600,
      "iat" => System.os_time(:second),
      "email" => "ada@example.com",
      "email_verified" => true,
      "name" => "Ada Lovelace"
    }
  end

  def default_userinfo do
    %{
      "sub" => "353690423699814251281",
      "name" => "Ada Lovelace",
      "given_name" => "Ada",
      "family_name" => "Lovelace",
      "picture" =>
        "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg",
      "email" => "ada@example.com",
      "email_verified" => true,
      "locale" => "en"
    }
  end

  def sign_openid_connect_token(claims) do
    {_alg, token} =
      jwks()
      |> JOSE.JWK.from()
      |> JOSE.JWS.sign(JSON.encode!(claims), %{"alg" => "RS256"})
      |> JOSE.JWS.compact()

    token
  end

  def jwks do
    %{
      "alg" => "RS256",
      "d" =>
        "X8TM24Zqbiha9geYYk_vZpANu16IadJLJLJ7ucTc3JaMbK8NCYNcHMoXKnNYPFxmq-UWAEIwh-2" <>
          "txOiOxuChVrblpfyE4SBJio1T0AUcCwmm8U6G-CsSHMMzWTt2dMTnArHjdyAIgOVRW5SVzhTT" <>
          "taf4JY-47S-fbcJ7g0hmBbVih5i1sE2fad4I4qFHT-YFU_pnUHbteR6GQuRW4r03Eon8Aje6a" <>
          "l2AxcYnfF8_cSOIOpkDgGavTtGYhhZPi2jZ7kPm6QGkNW5CyfEq5PGB6JOihw-XIFiiMzYgx0" <>
          "52rnzoqALoLheXrI0By4kgHSmcqOOmq7aiOff45rlSbpsR",
      "e" => "AQAB",
      "kid" => "example@firezone.dev",
      "kty" => "RSA",
      "n" =>
        "qlKll8no4lPYXNSuTTnacpFHiXwPOv_htCYvIXmiR7CWhiiOHQqj7KWXIW7TGxyoLVIyeRM4mwv" <>
          "kLI-UgsSMYdEKTT0j7Ydjrr0zCunPu5Gxr2yOmcRaszAzGxJL5DwpA0V40RqMlm5OuwdqS4To" <>
          "_p9LlLxzMF6RZe1OqslV5RZ4Y8FmrWq6BV98eIziEHL0IKdsAIrrOYkkcLDdQeMNuTp_yNB8X" <>
          "l2TdWSdsbRomrs2dCtCqZcXTsy2EXDceHvYhgAB33nh_w17WLrZQwMM-7kJk36Kk54jZd7i80" <>
          "AJf_s_plXn1mEh-L5IAL1vg3a9EOMFUl-lPiGqc3td_ykH",
      "use" => "sig"
    }
  end

  @doc false
  def __fetch_conn_params__(conn) do
    opts = Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)

    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Parsers.call(opts)
  end

  defp fetch_conn_params(conn), do: __fetch_conn_params__(conn)
end
