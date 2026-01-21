defmodule Portal.Okta.ErrorCodesTest do
  use ExUnit.Case, async: true

  alias Portal.Okta.ErrorCodes

  describe "format_error/2" do
    test "returns resolution for known error code E0000006" do
      body = %{"errorCode" => "E0000006"}
      result = ErrorCodes.format_error(403, body)

      assert result =~ "Access denied"
      assert result =~ "required scopes"
    end

    test "returns resolution for known error code E0000011" do
      body = %{"errorCode" => "E0000011"}
      result = ErrorCodes.format_error(401, body)

      assert result =~ "Invalid token"
    end

    test "handles invalid_client on 400" do
      body = %{"errorCode" => "invalid_client"}
      result = ErrorCodes.format_error(400, body)

      assert result =~ "Invalid client application"
    end

    test "handles invalid_client on 401" do
      body = %{"errorCode" => "invalid_client"}
      result = ErrorCodes.format_error(401, body)

      assert result =~ "Client authentication failed"
    end

    test "formats OAuth error format" do
      body = %{
        "error" => "invalid_client",
        "error_description" => "Client authentication failed"
      }

      result = ErrorCodes.format_error(401, body)

      assert result =~ "Client authentication failed"
    end

    test "formats error with unknown error code and summary" do
      body = %{
        "errorCode" => "E9999999",
        "errorSummary" => "Unknown error"
      }

      result = ErrorCodes.format_error(500, body)

      assert result =~ "E9999999"
      assert result =~ "Unknown error"
    end

    test "formats 400 with errorSummary only" do
      body = %{"errorSummary" => "Custom error message"}
      result = ErrorCodes.format_error(400, body)

      assert result =~ "Configuration error"
      assert result =~ "Custom error message"
    end

    test "formats 401 with errorSummary only" do
      body = %{"errorSummary" => "Custom 401 error message"}
      result = ErrorCodes.format_error(401, body)

      assert result =~ "Authentication failed"
      assert result =~ "Custom 401 error message"
    end

    test "formats 403 with errorSummary only" do
      body = %{"errorSummary" => "Custom 403 error"}
      result = ErrorCodes.format_error(403, body)

      assert result =~ "Permission denied"
      assert result =~ "Custom 403 error"
    end

    test "formats 404 with errorSummary only" do
      body = %{"errorSummary" => "Custom 404 error"}
      result = ErrorCodes.format_error(404, body)

      assert result =~ "Not found"
      assert result =~ "Custom 404 error"
    end

    test "formats binary body" do
      result = ErrorCodes.format_error(500, "Internal server error")

      assert result == "HTTP 500 - Internal server error"
    end

    test "formats empty string body as fallback" do
      result = ErrorCodes.format_error(401, "")

      assert result =~ "HTTP 401 Unauthorized"
    end

    test "formats nil body with fallback message" do
      result = ErrorCodes.format_error(403, nil)

      assert result =~ "HTTP 403 Forbidden"
    end

    test "formats empty map body with fallback message" do
      result = ErrorCodes.format_error(400, %{})

      assert result =~ "HTTP 400 Bad Request"
    end

    test "formats 5xx with fallback message" do
      result = ErrorCodes.format_error(500, %{})

      assert result =~ "Okta service is currently unavailable"
      assert result =~ "HTTP 500"
    end
  end

  describe "get_resolution/2" do
    test "returns resolution for known authentication errors" do
      assert ErrorCodes.get_resolution("E0000004", 401) =~ "Verify your Okta API credentials"
      assert ErrorCodes.get_resolution("E0000011", 401) =~ "Invalid token"
      assert ErrorCodes.get_resolution("E0000061", 401) =~ "Access denied"
      assert ErrorCodes.get_resolution("E0000015", 401) =~ "requires a higher Okta plan"
    end

    test "returns resolution for invalid_client based on status" do
      assert ErrorCodes.get_resolution("invalid_client", 400) =~ "Invalid client application"
      assert ErrorCodes.get_resolution("invalid_client", 401) =~ "Client authentication failed"
    end

    test "returns resolution for known authorization errors" do
      assert ErrorCodes.get_resolution("E0000006", 403) =~ "Access denied"
      assert ErrorCodes.get_resolution("E0000022", 403) =~ "not be available for your Okta organization"
    end

    test "returns resolution for known validation errors" do
      assert ErrorCodes.get_resolution("E0000001", 400) =~ "API validation failed"
      assert ErrorCodes.get_resolution("E0000003", 400) =~ "request body was invalid"
      assert ErrorCodes.get_resolution("E0000021", 400) =~ "Bad request to Okta API"
    end

    test "returns resolution for rate limit errors" do
      assert ErrorCodes.get_resolution("E0000047", 429) =~ "rate limit has been exceeded"
    end

    test "returns resolution for not found errors" do
      assert ErrorCodes.get_resolution("E0000007", 404) =~ "Resource not found"
      assert ErrorCodes.get_resolution("E0000008", 404) =~ "API endpoint was not found"
      assert ErrorCodes.get_resolution("E0000048", 404) =~ "entity does not exist"
    end

    test "returns resolution for server errors" do
      assert ErrorCodes.get_resolution("E0000009", 500) =~ "Okta experienced an internal error"
      assert ErrorCodes.get_resolution("E0000010", 503) =~ "read-only maintenance mode"
    end

    test "returns nil for unknown error code" do
      assert ErrorCodes.get_resolution("E9999999", 500) == nil
    end

    test "returns nil for nil error code" do
      assert ErrorCodes.get_resolution(nil, 500) == nil
    end
  end

  describe "empty_resource_message/1" do
    test "returns message for apps" do
      result = ErrorCodes.empty_resource_message(:apps)

      assert result =~ "No apps found"
      assert result =~ "OIDC app is created"
      assert result =~ "okta.apps.read"
    end

    test "returns message for users" do
      result = ErrorCodes.empty_resource_message(:users)

      assert result =~ "No users found"
      assert result =~ "users are assigned to the OIDC app"
      assert result =~ "okta.users.read"
    end

    test "returns message for groups" do
      result = ErrorCodes.empty_resource_message(:groups)

      assert result =~ "No groups found"
      assert result =~ "groups are assigned to the OIDC app"
      assert result =~ "okta.groups.read"
    end
  end

  describe "default_resolution/1" do
    test "returns appropriate message for 5xx errors" do
      assert ErrorCodes.default_resolution(500) =~ "service is currently unavailable"
      assert ErrorCodes.default_resolution(502) =~ "service is currently unavailable"
      assert ErrorCodes.default_resolution(503) =~ "service is currently unavailable"
    end

    test "returns appropriate message for 429" do
      assert ErrorCodes.default_resolution(429) =~ "Rate limit exceeded"
    end

    test "returns appropriate message for 404" do
      assert ErrorCodes.default_resolution(404) =~ "verify your Okta domain"
    end

    test "returns appropriate message for 403" do
      assert ErrorCodes.default_resolution(403) =~ "scopes"
    end

    test "returns appropriate message for 401" do
      assert ErrorCodes.default_resolution(401) =~ "Client ID"
      assert ErrorCodes.default_resolution(401) =~ "public key"
    end

    test "returns appropriate message for 400" do
      assert ErrorCodes.default_resolution(400) =~ "verify your Okta domain"
    end

    test "returns generic message for unknown status" do
      assert ErrorCodes.default_resolution(418) =~ "verify your Okta configuration"
    end
  end

  describe "format_transport_error/1" do
    test "handles DNS lookup failure (nxdomain)" do
      error = %Req.TransportError{reason: :nxdomain}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "DNS lookup failed"
      assert result =~ "domain is spelled correctly"
    end

    test "handles timeout" do
      error = %Req.TransportError{reason: :timeout}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "timed out"
      assert result =~ "network connectivity"
    end

    test "handles connect_timeout" do
      error = %Req.TransportError{reason: :connect_timeout}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "timed out"
    end

    test "handles connection refused" do
      error = %Req.TransportError{reason: :econnrefused}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "Connection refused"
      assert result =~ "domain is correct"
    end

    test "handles connection closed" do
      error = %Req.TransportError{reason: :closed}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "closed unexpectedly"
    end

    test "handles TLS alert" do
      error = %Req.TransportError{reason: {:tls_alert, {:certificate_expired, "test"}}}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "TLS error"
      assert result =~ "certificate_expired"
    end

    test "handles host unreachable" do
      error = %Req.TransportError{reason: :ehostunreach}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "Host is unreachable"
    end

    test "handles network unreachable" do
      error = %Req.TransportError{reason: :enetunreach}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "Network is unreachable"
    end

    test "handles unknown transport errors" do
      error = %Req.TransportError{reason: :some_unknown_error}
      result = ErrorCodes.format_transport_error(error)

      assert result =~ "Network error"
      assert result =~ "some_unknown_error"
    end
  end
end
