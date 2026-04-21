defmodule Portal.DirectorySync.ErrorHandlerTest do
  use Portal.DataCase, async: true

  import ExUnit.CaptureLog

  alias Portal.DirectorySync.ErrorHandler

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GoogleDirectoryFixtures
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

  describe "handle_error/1 shared behavior" do
    test "returns default sentry context for unknown workers" do
      job = %Oban.Job{
        id: 123,
        args: %{"directory_id" => Ecto.UUID.generate()},
        meta: %{"attempt" => 1},
        queue: "test_queue",
        worker: "Portal.Unknown.Sync"
      }

      error = RuntimeError.exception("boom")

      context = ErrorHandler.handle_error(%{reason: error, job: job})

      assert context == Map.take(job, [:id, :args, :meta, :queue, :worker])
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

    test "does not update directory state for internal batch upsert errors", %{
      directory: directory
    } do
      job = sync_job("Portal.Okta.Sync", directory.id)

      error = %Portal.Okta.SyncError{
        error: "Failed to upsert identities: %Postgrex.Error{}",
        directory_id: directory.id,
        step: :batch_upsert_identities
      }

      context = ErrorHandler.handle_error(%{reason: error, job: job})
      assert context.step == :batch_upsert_identities

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at == nil
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
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

    test "classifies 3-tuple errors as transient and does not disable directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Okta.Sync",
        args: %{"directory_id" => directory.id}
      }

      # An unexpected 3-tuple error (e.g. from a future API response shape) should
      # be treated as transient, not a permanent client error.
      error = %Portal.Okta.SyncError{
        error: {:invalid_response, "Expected array, got map", %{"errorCode" => "E0000001"}},
        directory_id: directory.id,
        step: :stream_app_users
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message == "Expected array, got map"
    end

    test "formats HTTP responses with binary bodies", %{directory: directory} do
      job = sync_job("Portal.Okta.Sync", directory.id)

      error = %Portal.Okta.SyncError{
        error: %Req.Response{status: 502, body: "Bad gateway"},
        directory_id: directory.id,
        step: :list_apps
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "HTTP 502 - Bad gateway"
    end

    test "formats HTTP responses without bodies and disables after 24 hours", %{
      directory: directory
    } do
      directory = set_errored_at_hours_ago(directory, 25)
      job = sync_job("Portal.Okta.Sync", directory.id)

      error = %Portal.Okta.SyncError{
        error: %Req.Response{status: 503, body: nil},
        directory_id: directory.id,
        step: :list_apps
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false

      assert updated_directory.error_message ==
               "Okta service is currently unavailable (HTTP 503). Please try again later."
    end

    test "classifies nil sync errors as transient with unknown message", %{directory: directory} do
      job = sync_job("Portal.Okta.Sync", directory.id)

      error = %Portal.Okta.SyncError{
        error: nil,
        directory_id: directory.id,
        step: :list_apps
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "Unknown error occurred"
    end

    test "classifies binary sync errors as transient with literal message", %{
      directory: directory
    } do
      job = sync_job("Portal.Okta.Sync", directory.id)

      error = %Portal.Okta.SyncError{
        error: "plain okta failure",
        directory_id: directory.id,
        step: :list_apps
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "plain okta failure"
    end

    test "handles generic exceptions and missing directories" do
      directory_id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          assert :ok =
                   Portal.Okta.ErrorHandler.handle(
                     RuntimeError.exception("boom"),
                     directory_id
                   )
        end)

      assert log =~ "Directory not found, skipping error update"
      assert log =~ directory_id
    end

    test "handles generic non-exception errors by inspecting them", %{directory: directory} do
      assert {:ok, _directory} =
               Portal.Okta.ErrorHandler.handle(%{reason: :bad_shape}, directory.id)

      updated_directory = Portal.Repo.get!(Portal.Okta.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "%{reason: :bad_shape}"
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

    test "does not update directory state for internal batch upsert errors", %{
      directory: directory
    } do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: {:database, "failed to upsert identities: %Postgrex.Error{}"},
        directory_id: directory.id,
        step: :batch_upsert_identities
      }

      context = ErrorHandler.handle_error(%{reason: error, job: job})
      assert context.step == :batch_upsert_identities

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at == nil
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
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

    test "classifies 3-tuple errors as transient and does not disable directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Entra.Sync",
        args: %{"directory_id" => directory.id}
      }

      # {missing_key, msg, body} is produced by the Entra API client when the API response
      # is missing the expected "value" key, e.g. due to an undocumented API change.
      error = %Portal.Entra.SyncError{
        error:
          {:missing_key, "Expected key 'value' not found in response",
           %{"@odata.context" => "https://graph.microsoft.com/v1.0/$metadata#groups"}},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message == "Expected key 'value' not found in response"
    end

    test "classifies HTTP 5xx binary responses as transient and disables after 24 hours", %{
      directory: directory
    } do
      directory = set_errored_at_hours_ago(directory, 25)
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{status: 503, body: "gateway unavailable"},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message == "HTTP 503 - gateway unavailable"
    end

    test "classifies transport errors as transient", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.TransportError{reason: :timeout},
        directory_id: directory.id,
        step: :get_access_token
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "Connection timed out."
    end

    test "formats HTTP 403 forbidden code responses", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{
          status: 403,
          body: %{"error" => %{"code" => "Forbidden", "message" => "No access"}}
        },
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.error_message =~ "Access forbidden"
    end

    test "formats HTTP 403 unknown code responses with a permission denied message", %{
      directory: directory
    } do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{
          status: 403,
          body: %{"error" => %{"code" => "SomethingElse", "message" => "No access"}}
        },
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.error_message =~ "Permission denied"
    end

    test "formats generic error responses with inner codes", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{
          status: 429,
          body: %{
            "error" => %{
              "code" => "TooManyRequests",
              "message" => "Slow down",
              "innerError" => %{"code" => "Throttled"}
            }
          }
        },
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.error_message ==
               "HTTP 429 - Code: TooManyRequests - Inner Code: Throttled - Slow down"
    end

    test "formats 403 responses without bodies", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{status: 403, body: nil},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.error_message =~ "Permission denied"
      assert updated_directory.error_message =~ "re-grant admin consent"
    end

    test "formats 401 responses without bodies", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{status: 401, body: nil},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)

      assert updated_directory.error_message ==
               "Authentication failed. Please re-grant admin consent in Microsoft Entra."
    end

    test "formats plain responses without error payloads", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: %Req.Response{status: 500, body: nil},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.error_message == "Entra API returned HTTP 500"
    end

    test "classifies batch_all_failed 5xx errors as transient", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: {:batch_all_failed, 500, %{"error" => %{"message" => "Internal error"}}},
        directory_id: directory.id,
        step: :batch_get_users
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "HTTP 500 - Internal error"
    end

    test "classifies batch_request_failed 5xx errors as transient", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: {:batch_request_failed, 500, %{"error" => %{"message" => "Internal error"}}},
        directory_id: directory.id,
        step: :batch_get_users
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "HTTP 500 - Internal error"
    end

    test "classifies nil sync errors as transient with unknown message", %{directory: directory} do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: nil,
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "Unknown error occurred"
    end

    test "classifies binary sync errors as transient with literal message", %{
      directory: directory
    } do
      job = sync_job("Portal.Entra.Sync", directory.id)

      error = %Portal.Entra.SyncError{
        error: "plain entra failure",
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "plain entra failure"
    end

    test "handles generic exceptions and missing directories" do
      directory_id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          assert :ok =
                   Portal.Entra.ErrorHandler.handle(
                     RuntimeError.exception("boom"),
                     directory_id
                   )
        end)

      assert log =~ "Directory not found, skipping error update"
      assert log =~ directory_id
    end

    test "handles generic non-exception errors by inspecting them", %{directory: directory} do
      assert {:ok, _directory} =
               Portal.Entra.ErrorHandler.handle(%{reason: :bad_shape}, directory.id)

      updated_directory = Portal.Repo.get!(Portal.Entra.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "%{reason: :bad_shape}"
    end
  end

  describe "handle_error/1 with Google SyncError" do
    setup do
      account = account_fixture(features: %{idp_sync: true})
      directory = google_directory_fixture(account: account)

      %{account: account, directory: directory}
    end

    test "classifies HTTP 4xx errors as client_error and disables directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Google.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Google.SyncError{
        error: %Req.Response{
          status: 403,
          body: %{
            "error" => %{
              "code" => 403,
              "message" => "Request had insufficient authentication scopes.",
              "errors" => [%{"reason" => "insufficientPermissions"}]
            }
          }
        },
        directory_id: directory.id,
        step: :stream_users
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)

      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message =~ "insufficientPermissions"
    end

    test "does not update directory state for internal batch upsert errors", %{
      directory: directory
    } do
      job = sync_job("Portal.Google.Sync", directory.id)

      error = %Portal.Google.SyncError{
        error: {:database, "failed to upsert identities: %Postgrex.Error{}"},
        directory_id: directory.id,
        step: :batch_upsert_identities
      }

      context = ErrorHandler.handle_error(%{reason: error, job: job})
      assert context.step == :batch_upsert_identities

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at == nil
      assert updated_directory.error_message == nil
      assert updated_directory.error_email_count == 0
    end

    test "classifies HTTP 5xx errors as transient and does not disable directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Google.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Google.SyncError{
        error: %Req.Response{
          status: 500,
          body: %{"error" => %{"message" => "Internal error encountered."}}
        },
        directory_id: directory.id,
        step: :list_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message != nil
    end

    test "classifies 3-tuple errors as transient and does not disable directory",
         %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Google.Sync",
        args: %{"directory_id" => directory.id}
      }

      # {missing_key, msg, body} is produced by the Google API client when a mandatory
      # key (e.g. "groups") is absent from a paginated response, indicating an unexpected
      # API format change rather than a permanent auth/permission failure.
      error = %Portal.Google.SyncError{
        error:
          {:missing_key, "Expected key 'groups' not found in response",
           %{"kind" => "admin#directory#groups"}},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message == "Expected key 'groups' not found in response"
    end

    test "classifies transport errors as transient", %{directory: directory} do
      job = %Oban.Job{
        worker: "Portal.Google.Sync",
        args: %{"directory_id" => directory.id}
      }

      error = %Portal.Google.SyncError{
        error: %Req.TransportError{reason: :timeout},
        directory_id: directory.id,
        step: :get_access_token
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)

      assert updated_directory.is_disabled == false
      assert updated_directory.errored_at != nil
      assert updated_directory.error_message == "Connection timed out."
    end

    test "classifies tuple validation errors as client_error", %{directory: directory} do
      job = sync_job("Portal.Google.Sync", directory.id)

      error = %Portal.Google.SyncError{
        error: {:scopes, "missing google groups scope"},
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.is_disabled == true
      assert updated_directory.error_message == "missing google groups scope"
    end

    test "formats HTTP responses with binary bodies and disables after 24 hours", %{
      directory: directory
    } do
      directory = set_errored_at_hours_ago(directory, 25)
      job = sync_job("Portal.Google.Sync", directory.id)

      error = %Portal.Google.SyncError{
        error: %Req.Response{status: 500, body: "backend exploded"},
        directory_id: directory.id,
        step: :list_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.is_disabled == true
      assert updated_directory.disabled_reason == "Sync error"
      assert updated_directory.is_verified == false
      assert updated_directory.error_message == "HTTP 500 - backend exploded"
    end

    test "formats HTTP responses without error bodies", %{directory: directory} do
      job = sync_job("Portal.Google.Sync", directory.id)

      error = %Portal.Google.SyncError{
        error: %Req.Response{status: 502, body: nil},
        directory_id: directory.id,
        step: :list_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "Google API returned HTTP 502"
    end

    test "classifies nil sync errors as transient with unknown message", %{directory: directory} do
      job = sync_job("Portal.Google.Sync", directory.id)

      error = %Portal.Google.SyncError{
        error: nil,
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "Unknown error occurred"
    end

    test "classifies binary sync errors as transient with literal message", %{
      directory: directory
    } do
      job = sync_job("Portal.Google.Sync", directory.id)

      error = %Portal.Google.SyncError{
        error: "plain google failure",
        directory_id: directory.id,
        step: :stream_groups
      }

      ErrorHandler.handle_error(%{reason: error, job: job})

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "plain google failure"
    end

    test "handles generic exceptions and missing directories" do
      directory_id = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          assert :ok =
                   Portal.Google.ErrorHandler.handle(
                     RuntimeError.exception("boom"),
                     directory_id
                   )
        end)

      assert log =~ "Directory not found, skipping error update"
      assert log =~ directory_id
    end

    test "handles generic non-exception errors by inspecting them", %{directory: directory} do
      assert {:ok, _directory} =
               Portal.Google.ErrorHandler.handle(%{reason: :bad_shape}, directory.id)

      updated_directory = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated_directory.is_disabled == false
      assert updated_directory.error_message == "%{reason: :bad_shape}"
    end
  end

  defp sync_job(worker, directory_id) do
    %Oban.Job{
      id: 123,
      worker: worker,
      queue: "test_queue",
      meta: %{},
      args: %{"directory_id" => directory_id}
    }
  end

  defp set_errored_at_hours_ago(directory, hours) do
    directory
    |> Ecto.Changeset.change(errored_at: DateTime.add(DateTime.utc_now(), -hours, :hour))
    |> Portal.Repo.update!()
  end
end
