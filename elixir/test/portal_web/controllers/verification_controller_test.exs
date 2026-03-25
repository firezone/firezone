defmodule PortalWeb.VerificationControllerTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Mocks

  setup do
    Mocks.OIDC.stub_discovery_document()
    :ok
  end

  describe "oidc/2" do
    test "with valid success result token, sends message to LV and renders success", %{
      conn: conn
    } do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:oidc_verify_complete, issuer, {from, ref}} ->
              send(parent, {:oidc_verify_complete_received, issuer})
              send(from, {:verification_ack, ref})
          end
        end)

      lv_pid_string = lv_pid |> :erlang.pid_to_list() |> to_string()
      token = sign_oidc_result(%{ok: true, issuer: "https://example.com", lv_pid: lv_pid_string})

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"
      assert conn.resp_body =~ "data-auto-close-window-after-ms=\"1000\""
      refute conn.resp_body =~ "setTimeout(function()"
      assert_received {:oidc_verify_complete_received, "https://example.com"}
    end

    test "with failure result token, sends failure message to LV and renders failure", %{
      conn: conn
    } do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      token = sign_oidc_result(%{ok: false, error: "invalid_grant", lv_pid: lv_pid_string})

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "invalid_grant"
      refute conn.resp_body =~ "window.close()"
      assert_received {:oidc_verify_failed, "invalid_grant"}
    end

    test "with nil lv_pid in result token, renders failure without sending message", %{conn: conn} do
      token = sign_oidc_result(%{ok: true, issuer: "https://example.com", lv_pid: nil})

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      refute_received {:oidc_verify_complete, _issuer}
    end

    test "with invalid result token, renders failure", %{conn: conn} do
      conn = get(conn, ~p"/verification/oidc", %{"result" => "invalid-token"})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Invalid or expired"
    end

    test "with missing result param, renders failure", %{conn: conn} do
      conn = get(conn, ~p"/verification/oidc", %{})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
    end
  end

  describe "entra/2 (entra-auth-provider / auth_provider flow)" do
    test "with signed state and admin_consent=True, sends message and renders success", %{
      conn: conn
    } do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:entra_verify_complete, issuer, tenant_id, {from, ref}} ->
              send(parent, {:entra_verify_complete_received, issuer, tenant_id})
              send(from, {:verification_ack, ref})
          end
        end)

      lv_pid_string = lv_pid |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-auth-provider")

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"

      assert_received {:entra_verify_complete_received,
                       "https://login.microsoftonline.com/my-tenant-id/v2.0", "my-tenant-id"}
    end

    test "with invalid state, renders failure", %{conn: conn} do
      params = %{
        "state" => "not-a-signed-token",
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Invalid or expired"
    end

    test "with consent denied (error params), sends failure and renders failure", %{conn: conn} do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-auth-provider")

      params = %{
        "state" => state,
        "admin_consent" => "False",
        "error" => "access_denied",
        "error_description" => "The user denied consent"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "The user denied consent"
      refute conn.resp_body =~ "window.close()"
      assert_received {:verification_failed, "The user denied consent"}
    end

    test "with admin_consent=False and no error params, sends failure and renders failure", %{
      conn: conn
    } do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-auth-provider")

      params = %{"state" => state, "admin_consent" => "False"}

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Admin consent was not granted"
      assert_received {:verification_failed, "Admin consent was not granted"}
    end

    test "with missing admin_consent param, sends failure and renders failure", %{conn: conn} do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-auth-provider")

      params = %{"state" => state, "tenant" => "some-tenant"}

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Missing tenant information"
      assert_received {:verification_failed, "Missing tenant information"}
    end

    # Microsoft always sends error_description alongside error in practice, but it is
    # technically optional per the OAuth 2.0 spec, so we handle the fallback defensively.
    test "with error code but no error_description, sends failure and renders failure", %{
      conn: conn
    } do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-auth-provider")

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "error" => "access_denied"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "access_denied"
      assert_received {:verification_failed, "access_denied"}
    end
  end

  describe "entra/2 (entra-directory-sync / directory_sync flow)" do
    test "with invalid state, renders failure", %{conn: conn} do
      params = %{
        "state" => "not-a-signed-token",
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Invalid or expired"
    end

    test "with consent denied (error params), sends failure and renders failure", %{conn: conn} do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-directory-sync")

      params = %{
        "state" => state,
        "admin_consent" => "False",
        "error" => "access_denied",
        "error_description" => "The user denied consent"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert_received {:verification_failed, "The user denied consent"}
    end

    test "with successful Entra API verification, sends message and renders success", %{
      conn: conn
    } do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:entra_directory_sync_complete, tenant_id, {from, ref}} ->
              send(parent, {:entra_directory_sync_complete_received, tenant_id})
              send(from, {:verification_ack, ref})
          end
        end)

      lv_pid_string = lv_pid |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-directory-sync")

      Req.Test.stub(Portal.Entra.APIClient, fn req_conn ->
        cond do
          req_conn.method == "POST" ->
            Req.Test.json(req_conn, %{"access_token" => "test-token"})

          String.contains?(req_conn.request_path, "appRoleAssignedTo") ->
            Req.Test.json(req_conn, %{"value" => []})

          String.contains?(req_conn.request_path, "servicePrincipals") ->
            Req.Test.json(req_conn, %{"value" => [%{"id" => "sp-id"}]})

          String.contains?(req_conn.request_path, "/users") ->
            Req.Test.json(req_conn, %{"value" => [%{"id" => "user-1"}]})

          String.contains?(req_conn.request_path, "/groups") ->
            Req.Test.json(req_conn, %{"value" => [%{"id" => "group-1"}]})

          true ->
            Req.Test.json(req_conn, %{"error" => "not mocked"})
        end
      end)

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"
      assert_received {:entra_directory_sync_complete_received, "my-tenant-id"}
    end

    test "with Entra API 401 error (nested message body), sends failure and renders failure", %{
      conn: conn
    } do
      # Sign an invalid pid string to cover the deserialize_pid rescue branch
      state = PortalWeb.OIDC.sign_verification_state("not-a-valid-pid", "entra-directory-sync")

      Req.Test.stub(Portal.Entra.APIClient, fn req_conn ->
        req_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          JSON.encode!(%{"error" => %{"message" => "Invalid credentials"}})
        )
      end)

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Unauthorized"
      assert conn.resp_body =~ "Invalid credentials"
    end

    test "with Entra API 403 error (binary error body), sends failure and renders failure", %{
      conn: conn
    } do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-directory-sync")

      Req.Test.stub(Portal.Entra.APIClient, fn req_conn ->
        req_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, JSON.encode!(%{"error" => "Access to resource forbidden"}))
      end)

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Access denied"
      assert conn.resp_body =~ "Access to resource forbidden"
      assert_received {:verification_failed, message}
      assert message =~ "Access denied"
    end

    test "with Entra API 4xx error (empty body), sends failure and renders failure", %{
      conn: conn
    } do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-directory-sync")

      Req.Test.stub(Portal.Entra.APIClient, fn req_conn ->
        req_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, JSON.encode!(%{}))
      end)

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Verification failed (HTTP 404)"
      assert_received {:verification_failed, message}
      assert message =~ "Verification failed (HTTP 404)"
    end

    test "with Entra API transport error, sends failure and renders failure", %{conn: conn} do
      lv_pid_string = self() |> :erlang.pid_to_list() |> to_string()
      state = PortalWeb.OIDC.sign_verification_state(lv_pid_string, "entra-directory-sync")

      Req.Test.stub(Portal.Entra.APIClient, fn req_conn ->
        Req.Test.transport_error(req_conn, :econnrefused)
      end)

      params = %{
        "state" => state,
        "admin_consent" => "True",
        "tenant" => "my-tenant-id"
      }

      conn = get(conn, ~p"/verification/entra", params)

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Failed to verify directory access"
      assert_received {:verification_failed, message}
      assert message =~ "Failed to verify directory access"
    end
  end

  describe "entra/2 with invalid state" do
    test "renders failure for unsigned/unknown state", %{conn: conn} do
      conn =
        get(conn, ~p"/verification/entra", %{
          "state" => "unknown-state",
          "admin_consent" => "True",
          "tenant" => "my-tenant-id"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
    end

    test "renders failure when no state param", %{conn: conn} do
      conn = get(conn, ~p"/verification/entra", %{})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp sign_oidc_result(result) do
    Phoenix.Token.sign(PortalWeb.Endpoint, "oidc-verification-result", result)
  end
end
