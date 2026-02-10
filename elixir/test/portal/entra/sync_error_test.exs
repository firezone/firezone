defmodule Portal.Entra.SyncErrorTest do
  use ExUnit.Case, async: true

  alias Portal.Entra.SyncError

  @test_directory_id "12345678-1234-1234-1234-123456789012"

  describe "exception/1" do
    test "creates exception with string error" do
      exception =
        SyncError.exception(
          error: "Failed to authenticate",
          directory_id: @test_directory_id,
          step: :get_access_token
        )

      assert %SyncError{
               error: "Failed to authenticate",
               directory_id: @test_directory_id,
               step: :get_access_token
             } = exception

      assert exception.message =~ "Entra sync failed"
      assert exception.message =~ @test_directory_id
      assert exception.message =~ "get_access_token"
      assert exception.message =~ "Failed to authenticate"
    end

    test "creates exception with exception error" do
      original_error = %RuntimeError{message: "Network timeout"}

      exception =
        SyncError.exception(
          error: original_error,
          directory_id: @test_directory_id,
          step: :stream_groups
        )

      assert %SyncError{
               error: %RuntimeError{message: "Network timeout"},
               directory_id: @test_directory_id,
               step: :stream_groups
             } = exception

      assert exception.message =~ "Entra sync failed"
      assert exception.message =~ @test_directory_id
      assert exception.message =~ "stream_groups"
      assert exception.message =~ "Network timeout"
    end

    test "builds message from HTTP response-like error" do
      http_response = %{status: 403, body: %{"error" => "Forbidden"}}

      exception =
        SyncError.exception(
          error: http_response,
          directory_id: @test_directory_id,
          step: :list_users
        )

      assert exception.message =~ "HTTP 403"
      assert exception.message =~ ~s(%{"error" => "Forbidden"})
      assert exception.message =~ @test_directory_id
      assert exception.message =~ "list_users"
    end

    test "builds message from exception error" do
      original_exception = %ArgumentError{message: "Invalid argument"}

      exception =
        SyncError.exception(
          error: original_exception,
          directory_id: @test_directory_id,
          step: :process_user
        )

      assert exception.message =~ "Invalid argument"
      assert exception.message =~ @test_directory_id
      assert exception.message =~ "process_user"
    end

    test "builds message from arbitrary term" do
      arbitrary_error = {:error, :timeout}

      exception =
        SyncError.exception(
          error: arbitrary_error,
          directory_id: @test_directory_id,
          step: :fetch_groups
        )

      assert exception.message =~ "{:error, :timeout}"
      assert exception.message =~ @test_directory_id
      assert exception.message =~ "fetch_groups"
    end

    test "requires directory_id and step" do
      assert_raise KeyError, fn ->
        SyncError.exception(directory_id: @test_directory_id)
      end

      assert_raise KeyError, fn ->
        SyncError.exception(error: "test", step: :test)
      end

      assert_raise KeyError, fn ->
        SyncError.exception(error: "test", directory_id: @test_directory_id)
      end
    end

    test "stores all fields correctly" do
      error_value = %RuntimeError{message: "Original error"}

      exception =
        SyncError.exception(
          error: error_value,
          directory_id: @test_directory_id,
          step: :sync_all_groups
        )

      assert exception.error == error_value
      assert exception.directory_id == @test_directory_id
      assert exception.step == :sync_all_groups
      assert is_binary(exception.message)
    end

    test "can be raised" do
      assert_raise SyncError, fn ->
        raise SyncError,
          error: "Test error",
          directory_id: @test_directory_id,
          step: :test_step
      end
    end

    test "message includes all context when raised" do
      try do
        raise SyncError,
          error: "Test sync failure",
          directory_id: @test_directory_id,
          step: :batch_upsert_identities
      rescue
        e in SyncError ->
          message = Exception.message(e)
          assert message =~ "Entra sync failed"
          assert message =~ @test_directory_id
          assert message =~ "batch_upsert_identities"
          assert message =~ "Test sync failure"
      end
    end
  end

  describe "message building for different error types" do
    test "formats string error cleanly" do
      exception =
        SyncError.exception(
          error: "User not found",
          directory_id: @test_directory_id,
          step: :fetch_user
        )

      assert exception.message ==
               "Entra sync failed for directory #{@test_directory_id} at fetch_user: User not found"
    end

    test "formats HTTP response with status and body" do
      http_error = %{
        status: 401,
        body: %{
          "error" => "invalid_token",
          "error_description" => "The access token is invalid"
        }
      }

      exception =
        SyncError.exception(
          error: http_error,
          directory_id: @test_directory_id,
          step: :get_access_token
        )

      message = exception.message
      assert message =~ "Entra sync failed for directory #{@test_directory_id}"
      assert message =~ "get_access_token"
      assert message =~ "HTTP 401"
      assert message =~ "invalid_token"
    end

    test "formats exception with Exception.message/1" do
      original = %Postgrex.Error{
        message: "Connection closed",
        connection_id: 123
      }

      exception =
        SyncError.exception(
          error: original,
          directory_id: @test_directory_id,
          step: :batch_upsert_groups
        )

      message = exception.message
      assert message =~ "Entra sync failed for directory #{@test_directory_id}"
      assert message =~ "batch_upsert_groups"
      assert message =~ "Connection closed"
    end

    test "formats arbitrary terms with inspect" do
      error = {:batch_failed, [user_id: "123", error: :not_found]}

      exception =
        SyncError.exception(
          error: error,
          directory_id: @test_directory_id,
          step: :process_batch
        )

      message = exception.message
      assert message =~ "Entra sync failed for directory #{@test_directory_id}"
      assert message =~ "process_batch"
      assert message =~ "{:batch_failed"
      assert message =~ "user_id:"
      assert message =~ "\"123\""
    end
  end
end
