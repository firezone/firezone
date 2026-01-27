defmodule Portal.DirectorySync.ErrorHandlerTest do
  use ExUnit.Case, async: true

  alias Portal.DirectorySync.ErrorHandler

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
end
