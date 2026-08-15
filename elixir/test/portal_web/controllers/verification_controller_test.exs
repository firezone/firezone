defmodule PortalWeb.VerificationControllerTest do
  use PortalWeb.ConnCase, async: true

  @tenant_id "12345678-1234-1234-1234-123456789012"
  @issuer "https://login.microsoftonline.com/#{@tenant_id}/v2.0"
  @principal_id "87654321-4321-4321-4321-210987654321"
  @global_administrator_role_id "62e90394-69f5-4237-9190-012177145e10"

  describe "oidc/2" do
    test "with valid success result token, sends message to LV and renders success", %{
      conn: conn
    } do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:oidc_verify_complete, issuer, verification_ref, {from, ref}} ->
              send(parent, {:oidc_verify_complete_received, issuer, verification_ref})
              send(from, {:verification_ack, ref})
          end
        end)

      lv_pid_string = PortalWeb.OIDC.serialize_pid(lv_pid)
      verification_ref = Ecto.UUID.generate()

      token =
        sign_oidc_result(%{
          ok: true,
          issuer: "https://example.com",
          lv_pid: lv_pid_string,
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"
      assert conn.resp_body =~ "data-auto-close-window-after-ms=\"1000\""
      refute conn.resp_body =~ "setTimeout(function()"
      assert_received {:oidc_verify_complete_received, "https://example.com", ^verification_ref}
    end

    test "with a Google directory result, sends the verified domain to the active LiveView", %{
      conn: conn
    } do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:google_directory_sync_complete, domain, verification_ref, {from, ref}} ->
              send(
                parent,
                {:google_directory_sync_complete_received, domain, verification_ref}
              )

              send(from, {:verification_ack, ref})
          end
        end)

      verification_ref = Ecto.UUID.generate()

      token =
        sign_oidc_result(%{
          ok: true,
          type: "google-directory-sync",
          domain: "verified.example.com",
          lv_pid: serialize_pid(lv_pid),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"

      assert_received {:google_directory_sync_complete_received, "verified.example.com",
                       ^verification_ref}
    end

    test "with a Google directory failure, notifies only that verification session", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()

      token =
        sign_oidc_result(%{
          ok: false,
          type: "google-directory-sync",
          error: "The Google account is not an administrator",
          lv_pid: serialize_pid(self()),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "not an administrator"

      assert_received {:verification_failed, "The Google account is not an administrator",
                       ^verification_ref}
    end

    test "with failure result token, sends failure message to LV and renders failure", %{
      conn: conn
    } do
      lv_pid_string = PortalWeb.OIDC.serialize_pid(self())
      token = sign_oidc_result(%{ok: false, error: "invalid_grant", lv_pid: lv_pid_string})

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "invalid_grant"
      refute conn.resp_body =~ "window.close()"
      assert_received {:oidc_verify_failed, "invalid_grant"}
    end

    test "with nil lv_pid in result token, renders failure without sending message", %{conn: conn} do
      token =
        sign_oidc_result(%{
          ok: true,
          issuer: "https://example.com",
          lv_pid: nil,
          verification_ref: Ecto.UUID.generate()
        })

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      refute_received {:oidc_verify_complete, _issuer, _verification_ref, _ack_to}
    end

    test "with success result token missing verification_ref, renders failure", %{conn: conn} do
      lv_pid_string = PortalWeb.OIDC.serialize_pid(self())
      token = sign_oidc_result(%{ok: true, issuer: "https://example.com", lv_pid: lv_pid_string})

      conn = get(conn, ~p"/verification/oidc", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
      assert conn.resp_body =~ "Invalid or expired verification result"
      refute_received {:oidc_verify_complete, _issuer, _verification_ref, _ack_to}
    end

    test "with invalid or missing result token, renders failure", %{conn: conn} do
      conn = get(conn, ~p"/verification/oidc", %{"result" => "invalid-token"})
      assert conn.status == 200
      assert conn.resp_body =~ "Invalid or expired"

      conn = get(recycle(conn), ~p"/verification/oidc", %{})
      assert conn.status == 200
      assert conn.resp_body =~ "Verification Failed"
    end
  end

  describe "entra/2 for auth providers" do
    test "uses the tenant identity from the signed result and ignores callback tenant params", %{
      conn: conn
    } do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:entra_verify_complete, issuer, tenant_id, verification_ref, {from, ref}} ->
              send(parent, {:entra_verify_complete_received, issuer, tenant_id, verification_ref})
              send(from, {:verification_ack, ref})
          end
        end)

      verification_ref = Ecto.UUID.generate()

      token =
        sign_entra_result(%{
          ok: true,
          type: "entra-auth-provider",
          issuer: @issuer,
          tenant_id: @tenant_id,
          role_ids: [@global_administrator_role_id],
          lv_pid: serialize_pid(lv_pid),
          verification_ref: verification_ref
        })

      conn =
        get(conn, ~p"/verification/entra", %{
          "result" => token,
          "tenant" => "attacker-controlled-tenant",
          "admin_consent" => "True"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"
      assert_received {:entra_verify_complete_received, @issuer, @tenant_id, ^verification_ref}
    end

    test "rejects a signed-in tenant user who is not an authorized administrator", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()

      token =
        sign_entra_result(%{
          ok: true,
          type: "entra-auth-provider",
          issuer: @issuer,
          tenant_id: @tenant_id,
          role_ids: [],
          lv_pid: serialize_pid(self()),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.resp_body =~ "Global Administrator or Privileged Role Administrator"
      assert_received {:verification_failed, message, ^verification_ref}
      assert message =~ "Global Administrator or Privileged Role Administrator"
      refute_received {:entra_verify_complete, _issuer, _tenant_id, _verification_ref, _ack_to}
    end

    test "renders a signed authorization failure and notifies the active verification", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()

      token =
        sign_entra_result(%{
          ok: false,
          error: "The user denied consent",
          lv_pid: serialize_pid(self()),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "The user denied consent"
      assert_received {:verification_failed, "The user denied consent", ^verification_ref}
    end

    test "rejects a result missing its verification reference", %{conn: conn} do
      token =
        sign_entra_result(%{
          ok: true,
          type: "entra-auth-provider",
          issuer: @issuer,
          tenant_id: @tenant_id,
          lv_pid: serialize_pid(self())
        })

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Invalid or expired verification result"
      refute_received {:entra_verify_complete, _issuer, _tenant_id, _verification_ref, _ack_to}
    end
  end

  describe "entra/2 for directory sync" do
    test "verifies app-only Graph access before returning the signed tenant", %{conn: conn} do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:entra_directory_sync_complete, tenant_id, verification_ref, {from, ref}} ->
              send(parent, {:entra_directory_sync_complete_received, tenant_id, verification_ref})
              send(from, {:verification_ack, ref})
          end
        end)

      stub_directory_access()
      verification_ref = Ecto.UUID.generate()
      token = directory_result_token(lv_pid, verification_ref)

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"

      assert_received {:entra_directory_sync_complete_received, @tenant_id,
                       ^verification_ref}
    end

    test "rejects a non-admin user even when the directory app already has tenant access", %{
      conn: conn
    } do
      verification_ref = Ecto.UUID.generate()

      stub_directory_access([])

      conn =
        get(conn, ~p"/verification/entra", %{
          "result" => directory_result_token(self(), verification_ref)
        })

      assert conn.resp_body =~ "Global Administrator or Privileged Role Administrator"
      assert_received {:verification_failed, message, ^verification_ref}
      assert message =~ "Global Administrator or Privileged Role Administrator"

      refute_received {:entra_directory_sync_complete, _tenant_id, _verification_ref, _ack_to}
    end

    test "looks up directory roles using the principal ID from the signed result", %{conn: conn} do
      principal_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      stub_directory_access()
      lv_pid = verification_ack_process()

      conn =
        get(conn, ~p"/verification/entra", %{
          "result" => directory_result_token(lv_pid, Ecto.UUID.generate(), principal_id)
        })

      assert conn.resp_body =~ "Verification Successful"

      assert "/v1.0/users/#{principal_id}/transitiveMemberOf/microsoft.graph.directoryRole" in
               drain_entra_api_request_paths()
    end

    test "probes required Graph endpoints after verifying the signed principal ID", %{conn: conn} do
      stub_directory_access()
      lv_pid = verification_ack_process()

      conn = get(conn, ~p"/verification/entra", %{"result" => directory_result_token(lv_pid)})

      assert conn.resp_body =~ "Verification Successful"
      paths = drain_entra_api_request_paths()

      role_path =
        "/v1.0/users/#{@principal_id}/transitiveMemberOf/microsoft.graph.directoryRole"

      role_index = Enum.find_index(paths, &(&1 == role_path))
      users_index = Enum.find_index(paths, &(&1 == "/v1.0/users"))
      groups_index = Enum.find_index(paths, &(&1 == "/v1.0/groups"))

      assert is_integer(role_index)
      assert is_integer(users_index)
      assert is_integer(groups_index)
      assert role_index < users_index
      assert users_index < groups_index
    end

    test "renders an Entra API 401 error", %{conn: conn} do
      Req.Test.stub(Portal.Microsoft.Graph.APIClient, fn req_conn ->
        req_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          JSON.encode!(%{"error" => %{"message" => "Invalid credentials"}})
        )
      end)

      conn = get(conn, ~p"/verification/entra", %{"result" => directory_result_token(self())})

      assert conn.resp_body =~ "Unauthorized"
      assert conn.resp_body =~ "Invalid credentials"
    end

    test "renders an Entra API 403 error", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()

      Req.Test.stub(Portal.Microsoft.Graph.APIClient, fn req_conn ->
        req_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, JSON.encode!(%{"error" => "Access to resource forbidden"}))
      end)

      conn =
        get(conn, ~p"/verification/entra", %{
          "result" => directory_result_token(self(), verification_ref)
        })

      assert conn.resp_body =~ "Access denied"
      assert conn.resp_body =~ "Access to resource forbidden"
      assert_received {:verification_failed, message, ^verification_ref}
      assert message =~ "Access denied"
    end

    test "renders an Entra API error with an empty body", %{conn: conn} do
      Req.Test.stub(Portal.Microsoft.Graph.APIClient, fn req_conn ->
        req_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, JSON.encode!(%{}))
      end)

      conn = get(conn, ~p"/verification/entra", %{"result" => directory_result_token(self())})

      assert conn.resp_body =~ "Verification failed (HTTP 404)"
    end

    test "renders an Entra API transport error", %{conn: conn} do
      Req.Test.stub(Portal.Microsoft.Graph.APIClient, fn req_conn ->
        Req.Test.transport_error(req_conn, :econnrefused)
      end)

      conn = get(conn, ~p"/verification/entra", %{"result" => directory_result_token(self())})

      assert conn.resp_body =~ "Failed to verify directory access"
    end
  end

  describe "entra/2 for Intune device integrations" do
    test "accepts a tenant-wide administrator", %{conn: conn} do
      parent = self()

      lv_pid =
        spawn(fn ->
          receive do
            {:intune_device_integration_complete, tenant_id, verification_ref, {from, ref}} ->
              send(parent, {:intune_device_integration_complete_received, tenant_id,
                            verification_ref})

              send(from, {:verification_ack, ref})
          end
        end)

      verification_ref = Ecto.UUID.generate()

      token =
        sign_entra_result(%{
          ok: true,
          type: "intune-device-integration",
          tenant_id: @tenant_id,
          role_ids: [@global_administrator_role_id],
          lv_pid: serialize_pid(lv_pid),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.status == 200
      assert conn.resp_body =~ "Verification Successful"

      assert_received {:intune_device_integration_complete_received, @tenant_id,
                       ^verification_ref}
    end

    # The Intune app registration has no directory read, so wids is the only
    # proof of role available. A tenant user without one must not be able to
    # attach their tenant to a Firezone account.
    test "rejects a tenant user who holds no authorized directory role", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()

      token =
        sign_entra_result(%{
          ok: true,
          type: "intune-device-integration",
          tenant_id: @tenant_id,
          role_ids: [],
          lv_pid: serialize_pid(self()),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.resp_body =~ "Global Administrator or Privileged Role Administrator"
      assert_received {:verification_failed, message, ^verification_ref}
      assert message =~ "Global Administrator or Privileged Role Administrator"
      refute_received {:intune_device_integration_complete, _tenant_id, _ref, _ack_to}
    end

    test "rejects an unrelated directory role", %{conn: conn} do
      verification_ref = Ecto.UUID.generate()

      token =
        sign_entra_result(%{
          ok: true,
          type: "intune-device-integration",
          tenant_id: @tenant_id,
          # Intune Administrator: manages Intune, but cannot grant the tenant-wide
          # Graph consent this setup depends on.
          role_ids: ["3a2c62db-5318-420d-8d74-23affee5d9d5"],
          lv_pid: serialize_pid(self()),
          verification_ref: verification_ref
        })

      conn = get(conn, ~p"/verification/entra", %{"result" => token})

      assert conn.resp_body =~ "Global Administrator or Privileged Role Administrator"
      refute_received {:intune_device_integration_complete, _tenant_id, _ref, _ack_to}
    end
  end

  describe "entra/2 with an invalid result" do
    test "rejects raw admin-consent callback parameters", %{conn: conn} do
      conn =
        get(conn, ~p"/verification/entra", %{
          "state" => "attacker-controlled-state",
          "admin_consent" => "True",
          "tenant" => "attacker-controlled-tenant"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Invalid verification request"
    end

    test "rejects invalid or missing result tokens", %{conn: conn} do
      conn = get(conn, ~p"/verification/entra", %{"result" => "invalid-token"})
      assert conn.resp_body =~ "Invalid or expired verification result"

      conn = get(recycle(conn), ~p"/verification/entra", %{})
      assert conn.resp_body =~ "Invalid verification request"
    end
  end

  defp stub_directory_access(
         directory_roles \\ [%{"roleTemplateId" => @global_administrator_role_id}]
       ) do
    test_pid = self()

    Req.Test.stub(Portal.Microsoft.Graph.APIClient, fn req_conn ->
      send(test_pid, {:entra_api_request, req_conn.request_path})

      cond do
        req_conn.method == "POST" ->
          Req.Test.json(req_conn, %{"access_token" => "test-token"})

        String.contains?(req_conn.request_path, "appRoleAssignedTo") ->
          Req.Test.json(req_conn, %{"value" => []})

        String.contains?(req_conn.request_path, "transitiveMemberOf") ->
          Req.Test.json(req_conn, %{"value" => directory_roles})

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
  end

  defp directory_result_token(
         lv_pid,
         verification_ref \\ Ecto.UUID.generate(),
         principal_id \\ @principal_id
       ) do
    sign_entra_result(%{
      ok: true,
      type: "entra-directory-sync",
      issuer: @issuer,
      tenant_id: @tenant_id,
      principal_id: principal_id,
      lv_pid: serialize_pid(lv_pid),
      verification_ref: verification_ref
    })
  end

  defp verification_ack_process do
    spawn(fn ->
      receive do
        {:entra_directory_sync_complete, _tenant_id, _verification_ref, {from, ref}} ->
          send(from, {:verification_ack, ref})
      end
    end)
  end

  defp drain_entra_api_request_paths(paths \\ []) do
    receive do
      {:entra_api_request, path} -> drain_entra_api_request_paths([path | paths])
    after
      0 -> Enum.reverse(paths)
    end
  end

  defp serialize_pid(pid), do: PortalWeb.OIDC.serialize_pid(pid)

  defp sign_oidc_result(result) do
    Phoenix.Token.sign(PortalWeb.Endpoint, "oidc-verification-result", result)
  end

  defp sign_entra_result(result) do
    Phoenix.Token.sign(PortalWeb.Endpoint, "entra-verification-result", result)
  end
end
