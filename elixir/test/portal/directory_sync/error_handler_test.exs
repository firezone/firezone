defmodule Portal.DirectorySync.ErrorTest do
  use Portal.DataCase, async: true

  alias Portal.DirectorySync.CommonError
  alias Portal.Okta.SyncError, as: OktaSyncError
  alias Portal.Entra.SyncError, as: EntraSyncError

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.OktaDirectoryFixtures

  describe "Portal.DirectorySync.CommonError.format/1" do
    test "handles DNS lookup failure (nxdomain)" do
      error = %Req.TransportError{reason: :nxdomain}
      result = CommonError.format(error)

      assert result == "DNS lookup failed"
    end

    test "handles timeout" do
      error = %Req.TransportError{reason: :timeout}
      result = CommonError.format(error)

      assert result == "Connection timed out"
    end

    test "handles connect_timeout" do
      error = %Req.TransportError{reason: :connect_timeout}
      result = CommonError.format(error)

      assert result == "Connection timed out"
    end

    test "handles connection refused" do
      error = %Req.TransportError{reason: :econnrefused}
      result = CommonError.format(error)

      assert result == "Connection refused"
    end

    test "handles connection closed" do
      error = %Req.TransportError{reason: :closed}
      result = CommonError.format(error)

      assert result == "Connection closed unexpectedly"
    end

    test "handles TLS alert" do
      error = %Req.TransportError{reason: {:tls_alert, {:certificate_expired, "test"}}}
      result = CommonError.format(error)

      assert result == "TLS error (certificate_expired)"
    end

    test "handles host unreachable" do
      error = %Req.TransportError{reason: :ehostunreach}
      result = CommonError.format(error)

      assert result == "Host is unreachable"
    end

    test "handles network unreachable" do
      error = %Req.TransportError{reason: :enetunreach}
      result = CommonError.format(error)

      assert result == "Network is unreachable"
    end

    test "handles unknown transport errors" do
      error = %Req.TransportError{reason: :some_unknown_error}
      result = CommonError.format(error)

      assert result == "Network error: :some_unknown_error"
    end
  end

  describe "Portal.Okta.SyncError.handle_error/1" do
    setup do
      account = account_fixture(features: %{idp_sync: true})
      %{jwk: jwk, jwks: _jwks, kid: _kid} = Portal.Crypto.JWK.generate_jwk_and_jwks(1024)

      directory =
        okta_directory_fixture(
          account: account,
          private_key_jwk: jwk,
          kid: "test_kid"
        )

      %{account: account, directory: directory}
    end

    test "classifies circuit_breaker errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %OktaSyncError{
        message: "test",
        error: {:circuit_breaker, "would delete all identities"},
        directory_id: directory.id,
        step: :check_deletion_threshold
      }

      OktaSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "delete all identities"
    end

    test "classifies validation errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %OktaSyncError{
        message: "test",
        error: {:validation, "User 'user_123' missing required 'email' field"},
        directory_id: directory.id,
        step: :process_user
      }

      OktaSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "user_123"
    end

    test "classifies HTTP 403 errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %OktaSyncError{
        message: "test",
        error: %Req.Response{
          status: 403,
          body: %{
            "errorCode" => "E0000006",
            "errorSummary" => "Access denied"
          }
        },
        directory_id: directory.id,
        step: :stream_app_users
      }

      OktaSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Access denied"
    end

    test "classifies HTTP 5xx errors as transient and does not disable directory immediately",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %OktaSyncError{
        message: "test",
        error: %Req.Response{
          status: 503,
          body: %{"error" => "Service unavailable"}
        },
        directory_id: directory.id,
        step: :list_apps
      }

      OktaSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was NOT disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message != nil
    end

    test "classifies transport errors as transient", %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %OktaSyncError{
        message: "test",
        error: %Req.TransportError{reason: :timeout},
        directory_id: directory.id,
        step: :get_access_token
      }

      OktaSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was NOT disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message == "Connection timed out"
    end

    test "classifies scopes errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %OktaSyncError{
        message: "test",
        error: {:scopes, "okta.users.read"},
        directory_id: directory.id,
        step: :verify_scopes
      }

      OktaSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "okta.users.read"
    end
  end

  describe "Portal.Entra.SyncError.handle_error/1" do
    setup do
      account = account_fixture(features: %{idp_sync: true})
      directory = entra_directory_fixture(account: account)

      %{account: account, directory: directory}
    end

    test "classifies consent_revoked errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %EntraSyncError{
        message: "test",
        error:
          {:consent_revoked,
           "Directory Sync app service principal not found. Please re-grant admin consent."},
        directory_id: directory.id,
        step: :fetch_directory_sync_service_principal
      }

      EntraSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "consent"
    end

    test "classifies HTTP 403 permission errors as client_error and provides helpful message",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %EntraSyncError{
        message: "test",
        error: %Req.Response{
          status: 403,
          body: %{
            "error" => %{
              "code" => "Authorization_RequestDenied",
              "message" => "Insufficient privileges to complete the operation."
            }
          }
        },
        directory_id: directory.id,
        step: :stream_app_role_assignments
      }

      EntraSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Insufficient permissions"
      assert updated_directory.error_message =~ "re-grant admin consent"
    end

    test "classifies HTTP 401 authentication errors as client_error and provides helpful message",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %EntraSyncError{
        message: "test",
        error: %Req.Response{
          status: 401,
          body: %{
            "error" => %{
              "code" => "InvalidAuthenticationToken",
              "message" => "Access token has expired or is not yet valid."
            }
          }
        },
        directory_id: directory.id,
        step: :stream_groups
      }

      EntraSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Authentication failed"
      assert updated_directory.error_message =~ "re-grant admin consent"
    end

    test "classifies batch_all_failed 403 errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      # This is the exact error format from batch_get_users when all requests fail
      error = %EntraSyncError{
        message: "test",
        error:
          {:batch_all_failed, 403,
           %{
             "error" => %{
               "code" => "Authorization_RequestDenied",
               "message" => "Insufficient privileges to complete the operation."
             }
           }},
        directory_id: directory.id,
        step: :batch_get_users
      }

      EntraSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Insufficient permissions"
      assert updated_directory.error_message =~ "re-grant admin consent"
    end

    test "classifies batch_request_failed 403 errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      # This is the error format when the batch request itself fails
      error = %EntraSyncError{
        message: "test",
        error:
          {:batch_request_failed, 403,
           %{
             "error" => %{
               "code" => "Authorization_RequestDenied",
               "message" => "Insufficient privileges to complete the operation."
             }
           }},
        directory_id: directory.id,
        step: :batch_get_users
      }

      EntraSyncError.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Insufficient permissions"
    end
  end
end
