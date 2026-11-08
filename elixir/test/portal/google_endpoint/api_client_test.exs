defmodule Portal.GoogleEndpoint.APIClientTest do
  use ExUnit.Case, async: true

  import Portal.GoogleEndpointFixtures

  alias Portal.GoogleEndpoint.APIClient

  @workload_identity_provider "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/azure-portal/providers/workspace-sync-staging"
  @workload_identity_audience "api://tenant-id/google-workspace-sync-staging"
  @endpoint_service_account "endpoint-posture@project.iam.gserviceaccount.com"

  setup do
    Req.Test.stub(APIClient, fn conn -> Req.Test.json(conn, %{"error" => "not mocked"}) end)
    :ok
  end

  describe "get_access_token/1" do
    test "federates as the endpoint service account and delegates only the devices scope" do
      configure_workload_identity()
      test_pid = self()

      Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "azure-managed-identity-token",
          "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
        })
      end)

      Req.Test.stub(Portal.Google.APIClient, fn conn ->
        case conn.request_path do
          "/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "federated-google-token", "expires_in" => 3600})

          "/v1/projects/-/serviceAccounts/" <> rest ->
            send(test_pid, {:sign_jwt, rest})
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            %{"payload" => payload} = JSON.decode!(body)
            send(test_pid, {:claims, JSON.decode!(payload)})
            Req.Test.json(conn, %{"signedJwt" => "google-signed-jwt"})

          "/token" ->
            Req.Test.json(conn, %{"access_token" => "devices-token", "expires_in" => 3600})
        end
      end)

      assert APIClient.get_access_token("admin@acme.com") == {:ok, "devices-token"}

      assert_received {:sign_jwt, rest}
      assert rest == @endpoint_service_account <> ":signJwt"

      assert_received {:claims, claims}
      assert claims["iss"] == @endpoint_service_account
      assert claims["sub"] == "admin@acme.com"
      assert claims["scope"] == "https://www.googleapis.com/auth/cloud-identity.devices.readonly"
    end

    test "refuses a federation that lacks the endpoint service account" do
      configure_workload_identity()
      Portal.Config.put_env_override(:portal, APIClient, service_account_email: nil)

      assert APIClient.get_access_token("admin@acme.com") ==
               {:error, :incomplete_workload_identity_configuration}
    end

    test "never falls back to the directory service account key" do
      Portal.Config.put_env_override(:portal, Portal.Google.APIClient,
        service_account_key:
          Portal.GoogleAPIClientHelpers.service_account_key_json(
            "directory@test-project.iam.gserviceaccount.com"
          )
      )

      assert APIClient.get_access_token("admin@acme.com") ==
               {:error, :service_account_not_configured}
    end
  end

  describe "verify/1" do
    setup do
      configure_google_endpoint_api_client()
    end

    test "lists one device as the administrator" do
      test_pid = self()

      Req.Test.stub(APIClient, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:params, conn.query_params})
        Req.Test.json(conn, %{"devices" => [google_endpoint_api_device_fixture()]})
      end)

      assert APIClient.verify("admin@acme.com") == :ok
      assert_received {:params, %{"pageSize" => "1", "customer" => "customers/my_customer"}}
    end

    test "returns the Devices API response when the administrator cannot read devices" do
      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => %{"code" => 403, "message" => "Not Authorized"}})
      end)

      assert {:error, %Req.Response{status: 403}} = APIClient.verify("admin@acme.com")
    end

    test "rejects a page token that is not a string" do
      Req.Test.stub(APIClient, fn conn ->
        Req.Test.json(conn, %{"devices" => [], "nextPageToken" => 42})
      end)

      assert {:error, {:invalid_response, "nextPageToken is invalid", _body}} =
               APIClient.verify("admin@acme.com")
    end
  end

  defp configure_workload_identity do
    Portal.Config.put_env_override(:portal, Portal.Google.APIClient,
      workload_identity_provider: @workload_identity_provider,
      workload_identity_audience: @workload_identity_audience,
      service_account_email: "directory-sync@project.iam.gserviceaccount.com"
    )

    Portal.Config.put_env_override(:portal, APIClient, service_account_email: @endpoint_service_account)
  end
end
