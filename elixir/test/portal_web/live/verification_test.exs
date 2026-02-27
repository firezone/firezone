defmodule PortalWeb.VerificationTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.AuthenticationCache
  alias Portal.Entra

  setup do
    Req.Test.stub(Entra.APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    :ok
  end

  test "shows missing verification information when session is empty", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Verification Failed"
    assert html =~ "Missing verification information"
  end

  test "OIDC verification broadcasts code and consumes cache", %{conn: conn} do
    token = unique_token()
    key = verification_key(token)

    :ok =
      AuthenticationCache.put(key, %{"type" => "oidc", "token" => token, "code" => "test-code"})

    :ok = Portal.PubSub.subscribe("oidc-verification:#{token}")

    conn = put_session(conn, :verification, %{"type" => "oidc", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Verifying..."
    assert_receive {:oidc_verify, _pid, "test-code", ^token}
    assert :error = AuthenticationCache.get(key)
  end

  test "OIDC verification shows missing/expired when cache entry is absent", %{conn: conn} do
    token = unique_token()
    conn = put_session(conn, :verification, %{"type" => "oidc", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Missing or expired verification information"
  end

  test "OIDC verification shows invalid verification information for mismatched token", %{
    conn: conn
  } do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "oidc",
        "token" => "other-token",
        "code" => "test-code"
      })

    conn = put_session(conn, :verification, %{"type" => "oidc", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Invalid verification information"
  end

  test "handle_info(:success) updates the screen", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/verification")

    send(lv.pid, :success)

    assert render(lv) =~ "Verification Successful"
  end

  test "handle_info({:error, reason}) renders inspected reason", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/verification")

    send(lv.pid, {:error, :boom})

    assert render(lv) =~ ":boom"
  end

  test "handle_info(:timeout) shows timeout only when no prior result", %{conn: conn} do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "oidc",
        "token" => token,
        "code" => "test-code"
      })

    conn = put_session(conn, :verification, %{"type" => "oidc", "token" => token})

    {:ok, lv, _html} = live(conn, ~p"/verification")

    send(lv.pid, :timeout)

    assert render(lv) =~ "Verification timed out. Please try again."
  end

  test "handle_info(:timeout) does not overwrite success", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/verification")

    send(lv.pid, :success)
    send(lv.pid, :timeout)

    html = render(lv)
    assert html =~ "Verification Successful"
    refute html =~ "Verification timed out"
  end

  test "Entra verification shows missing/expired when cache entry is absent", %{conn: conn} do
    token = unique_token()
    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Missing or expired verification information"
  end

  test "Entra verification shows invalid verification information for wrong type", %{conn: conn} do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "oidc",
        "token" => token
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Invalid verification information"
  end

  test "Entra verification shows invalid verification information for mismatched token", %{
    conn: conn
  } do
    token = unique_token()
    key = verification_key(token)

    :ok =
      AuthenticationCache.put(key, %{
        "type" => "entra",
        "entra_type" => "auth_provider",
        "token" => "other-token",
        "admin_consent" => "True",
        "tenant_id" => "tenant-123"
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Invalid verification information"
    assert :error = AuthenticationCache.get(key)
  end

  test "Entra auth_provider verification broadcasts issuer and consumes cache", %{conn: conn} do
    token = unique_token()
    key = verification_key(token)

    :ok =
      AuthenticationCache.put(key, %{
        "type" => "entra",
        "entra_type" => "auth_provider",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    :ok = Portal.PubSub.subscribe("entra-verification:#{token}")

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, _html} = live(conn, ~p"/verification")

    assert_receive {:entra_admin_consent, _pid,
                    "https://login.microsoftonline.com/tenant-123/v2.0", "tenant-123", ^token}

    assert :error = AuthenticationCache.get(key)
  end

  test "Entra directory_sync verification broadcasts success when API checks pass", %{conn: conn} do
    token = unique_token()

    Req.Test.stub(Entra.APIClient, fn conn ->
      case conn.request_path do
        path ->
          if String.ends_with?(path, "/oauth2/v2.0/token") do
            Req.Test.json(conn, %{"access_token" => "access-token"})
          else
            case path do
              "/v1.0/servicePrincipals" ->
                Req.Test.json(conn, %{"value" => [%{"id" => "sp-id"}]})

              "/v1.0/servicePrincipals/sp-id/appRoleAssignedTo" ->
                Req.Test.json(conn, %{"value" => []})

              "/v1.0/users" ->
                Req.Test.json(conn, %{"value" => []})

              "/v1.0/groups" ->
                Req.Test.json(conn, %{"value" => []})

              _ ->
                Req.Test.json(conn, %{})
            end
          end
      end
    end)

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "directory_sync",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    :ok = Portal.PubSub.subscribe("entra-admin-consent:#{token}")

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, _html} = live(conn, ~p"/verification")

    assert_receive {:entra_admin_consent, _pid, nil, "tenant-123", ^token}
  end

  test "Entra verification shows provided error_description", %{conn: conn} do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "auth_provider",
        "token" => token,
        "admin_consent" => "False",
        "tenant_id" => "tenant-123",
        "error" => "access_denied",
        "error_description" => "User denied consent"
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "User denied consent"
  end

  test "Entra verification shows admin consent not granted", %{conn: conn} do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "auth_provider",
        "token" => token,
        "admin_consent" => "False",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Admin consent was not granted"
  end

  test "Entra verification shows missing tenant information", %{conn: conn} do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "auth_provider",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => nil,
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Missing tenant information"
  end

  test "Entra verification shows invalid verification information when token is missing", %{
    conn: conn
  } do
    token = unique_token()

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "auth_provider",
        "token" => nil,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Invalid verification information"
  end

  test "Entra directory_sync formats 401 errors", %{conn: conn} do
    token = unique_token()

    Req.Test.stub(Entra.APIClient, fn conn ->
      case conn.request_path do
        path ->
          if String.ends_with?(path, "/oauth2/v2.0/token") do
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"error" => %{"message" => "Unauthorized"}})
          else
            Req.Test.json(conn, %{})
          end
      end
    end)

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "directory_sync",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Unauthorized: Unauthorized"
  end

  test "Entra directory_sync formats 401 errors when error is a string", %{conn: conn} do
    token = unique_token()

    Req.Test.stub(Entra.APIClient, fn conn ->
      case conn.request_path do
        path ->
          if String.ends_with?(path, "/oauth2/v2.0/token") do
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"error" => "invalid_client"})
          else
            Req.Test.json(conn, %{})
          end
      end
    end)

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "directory_sync",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Unauthorized: invalid_client"
  end

  test "Entra directory_sync formats 403 errors", %{conn: conn} do
    token = unique_token()

    Req.Test.stub(Entra.APIClient, fn conn ->
      case conn.request_path do
        path ->
          if String.ends_with?(path, "/oauth2/v2.0/token") do
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error" => %{"message" => "Forbidden"}})
          else
            Req.Test.json(conn, %{})
          end
      end
    end)

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "directory_sync",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Access denied: Forbidden"
  end

  test "Entra directory_sync formats generic HTTP errors", %{conn: conn} do
    token = unique_token()

    Req.Test.stub(Entra.APIClient, fn conn ->
      case conn.request_path do
        path ->
          if String.ends_with?(path, "/oauth2/v2.0/token") do
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"error_description" => "Validation failed"})
          else
            Req.Test.json(conn, %{})
          end
      end
    end)

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "directory_sync",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Verification failed (HTTP 422): Validation failed"
  end

  test "Entra directory_sync formats transport errors", %{conn: conn} do
    token = unique_token()

    Req.Test.stub(Entra.APIClient, fn conn ->
      case conn.request_path do
        path ->
          if String.ends_with?(path, "/oauth2/v2.0/token") do
            Req.Test.transport_error(conn, :timeout)
          else
            Req.Test.json(conn, %{})
          end
      end
    end)

    :ok =
      AuthenticationCache.put(verification_key(token), %{
        "type" => "entra",
        "entra_type" => "directory_sync",
        "token" => token,
        "admin_consent" => "True",
        "tenant_id" => "tenant-123",
        "error" => nil,
        "error_description" => nil
      })

    conn = put_session(conn, :verification, %{"type" => "entra", "token" => token})

    {:ok, _lv, html} = live(conn, ~p"/verification")

    assert html =~ "Failed to verify directory access"
  end

  defp verification_key(token), do: AuthenticationCache.verification_key(token)

  defp unique_token do
    "verification-token-#{System.unique_integer([:positive, :monotonic])}"
  end
end
