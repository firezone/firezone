defmodule Portal.DirectorySync.ErrorHandlerTest do
  use Portal.DataCase, async: true

  alias Portal.DirectorySync.ErrorHandler

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.OktaDirectoryFixtures

  describe "format_transport_error/1" do
    test "handles DNS lookup failure (nxdomain)" do
      error = %Req.TransportError{reason: :nxdomain}
      result = ErrorHandler.format_transport_error(error)

      assert result == "DNS lookup failed."
    end

    test "handles timeout" do
      error = %Req.TransportError{reason: :timeout}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Connection timed out."
    end

    test "handles connect_timeout" do
      error = %Req.TransportError{reason: :connect_timeout}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Connection timed out."
    end

    test "handles connection refused" do
      error = %Req.TransportError{reason: :econnrefused}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Connection refused."
    end

    test "handles connection closed" do
      error = %Req.TransportError{reason: :closed}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Connection closed unexpectedly."
    end

    test "handles TLS alert" do
      error = %Req.TransportError{reason: {:tls_alert, {:certificate_expired, "test"}}}
      result = ErrorHandler.format_transport_error(error)

      assert result == "TLS error (certificate_expired)."
    end

    test "handles host unreachable" do
      error = %Req.TransportError{reason: :ehostunreach}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Host is unreachable."
    end

    test "handles network unreachable" do
      error = %Req.TransportError{reason: :enetunreach}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Network is unreachable."
    end

    test "handles unknown transport errors" do
      error = %Req.TransportError{reason: :some_unknown_error}
      result = ErrorHandler.format_transport_error(error)

      assert result == "Network error: :some_unknown_error"
    end
  end

  describe "handle_error/1 with Okta SyncError" do
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

    test "classifies check_deletion_threshold errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Okta.SyncError{
        error: {:circuit_breaker, "would delete all identities"},
        directory_id: directory.id,
        step: :check_deletion_threshold
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "would delete all identities"
    end

    test "classifies process_user errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Okta.SyncError{
        error: {:validation, "user 'user_123' missing 'email' field"},
        directory_id: directory.id,
        step: :process_user
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

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

      error = %Portal.Okta.SyncError{
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

      ErrorHandler.handle_error(%{reason: error, job: job})

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

      error = %Portal.Okta.SyncError{
        error: %Req.Response{
          status: 503,
          body: %{"error" => "Service unavailable"}
        },
        directory_id: directory.id,
        step: :list_apps
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

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

      error = %Portal.Okta.SyncError{
        error: %Req.TransportError{reason: :timeout},
        directory_id: directory.id,
        step: :get_access_token
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was NOT disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message == "Connection timed out."
    end

    test "classifies verify_scopes errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Okta.SyncError{
        error: {:scopes, "missing okta.users.read"},
        directory_id: directory.id,
        step: :verify_scopes
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "okta.users.read"
    end
  end

  describe "handle_error/1 with Entra SyncError" do
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

      error = %Portal.Entra.SyncError{
        error:
          {:consent_revoked,
           "Directory Sync app service principal not found. Please re-grant admin consent."},
        directory_id: directory.id,
        step: :fetch_directory_sync_service_principal
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "service principal not found"
    end

    test "classifies HTTP 403 permission errors as client_error and provides helpful message",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Entra.SyncError{
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

      ErrorHandler.handle_error(%{reason: error, job: job})

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

      error = %Portal.Entra.SyncError{
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

      ErrorHandler.handle_error(%{reason: error, job: job})

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
      error = %Portal.Entra.SyncError{
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

      ErrorHandler.handle_error(%{reason: error, job: job})

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
      error = %Portal.Entra.SyncError{
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

      ErrorHandler.handle_error(%{reason: error, job: job})

      # Reload directory and verify it was disabled
      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "Insufficient permissions"
    end
  end
end
