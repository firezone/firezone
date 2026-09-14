defmodule PortalAPI.SocketsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PortalAPI.Sockets

  describe "extract_token/2" do
    test "returns token from x-authorization header with Bearer prefix" do
      params = %{}
      connect_info = %{x_headers: [{"x-authorization", "Bearer my-token-123"}]}

      assert Sockets.extract_token(params, connect_info) == {:ok, "my-token-123"}
    end

    test "returns token from params when header is missing" do
      params = %{"token" => "param-token-456"}
      connect_info = %{x_headers: []}

      assert Sockets.extract_token(params, connect_info) == {:ok, "param-token-456"}
    end

    test "returns token from params when x_headers key is missing" do
      params = %{"token" => "param-token-789"}
      connect_info = %{}

      assert Sockets.extract_token(params, connect_info) == {:ok, "param-token-789"}
    end

    test "header takes precedence over params" do
      params = %{"token" => "param-token"}
      connect_info = %{x_headers: [{"x-authorization", "Bearer header-token"}]}

      assert Sockets.extract_token(params, connect_info) == {:ok, "header-token"}
    end

    test "returns error when neither header nor param is present" do
      params = %{}
      connect_info = %{x_headers: []}

      assert Sockets.extract_token(params, connect_info) == {:error, :missing_token}
    end

    test "returns error when header exists but without Bearer prefix" do
      params = %{}
      connect_info = %{x_headers: [{"x-authorization", "my-token"}]}

      assert Sockets.extract_token(params, connect_info) == {:error, :missing_token}
    end

    test "returns error when header exists with wrong prefix" do
      params = %{}
      connect_info = %{x_headers: [{"x-authorization", "Basic my-token"}]}

      assert Sockets.extract_token(params, connect_info) == {:error, :missing_token}
    end

    test "handles multiple x_headers correctly" do
      params = %{}

      connect_info = %{
        x_headers: [
          {"x-forwarded-for", "192.168.1.1"},
          {"x-authorization", "Bearer correct-token"},
          {"x-custom", "value"}
        ]
      }

      assert Sockets.extract_token(params, connect_info) == {:ok, "correct-token"}
    end

    test "falls back to params when header value is empty" do
      params = %{"token" => "fallback-token"}
      connect_info = %{x_headers: [{"x-authorization", ""}]}

      assert Sockets.extract_token(params, connect_info) == {:ok, "fallback-token"}
    end
  end

  describe "handle_error/2" do
    test "returns 401 for invalid_token" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :invalid_token)

      assert result.status == 401
      assert json_body(result)["detail"] == "Invalid token"
      assert_problem_json(result, "invalid_token")
    end

    test "returns 401 for missing_token" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :missing_token)

      assert result.status == 401
      assert json_body(result)["detail"] == "Missing token"
      assert_problem_json(result, "missing_token")
    end

    test "returns 402 for seats_limit_exceeded" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :limits_exceeded)

      assert result.status == 402

      assert json_body(result)["detail"] ==
               "This account is temporarily suspended from client authentication " <>
                 "due to exceeding billing limits. Please contact your administrator to add more seats."

      assert_problem_json(result, "limits_exceeded")
    end

    test "returns 403 for account_disabled" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :account_disabled)

      assert result.status == 403
      assert json_body(result)["detail"] == "The account is disabled"
      assert_problem_json(result, "account_disabled")
    end

    test "returns 403 for unauthenticated" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :unauthenticated)

      assert result.status == 403
      assert json_body(result)["detail"] == "Forbidden"
      assert_problem_json(result, "unauthenticated")
    end

    test "returns 403 for device_untrusted" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :device_untrusted)

      assert result.status == 403
      assert json_body(result)["detail"] =~ "did not present a valid certificate"
      assert_problem_json(result, "device_untrusted")
    end

    test "returns 403 for certificate_revoked" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :certificate_revoked)

      assert result.status == 403
      assert json_body(result)["detail"] =~ "has been revoked"
      assert_problem_json(result, "certificate_revoked")
    end

    test "returns 409 for device_identity_conflict" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :device_identity_conflict)

      assert result.status == 409
      assert json_body(result)["detail"] =~ "reports different hardware"
      assert_problem_json(result, "device_identity_conflict")
    end

    test "returns 409 for conflict" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :conflict)

      assert result.status == 409
      assert json_body(result)["detail"] == "A gateway with this ID is already connected"
      assert_problem_json(result, "gateway_already_connected")
    end

    test "returns a client-facing 403 for an unauthorized X.509 user" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :x509_user_not_authorized)

      assert result.status == 403

      assert json_body(result)["detail"] ==
               "This device's certificate does not identify an active user authorized to access " <>
                 "this Firezone account. Please contact your administrator."

      assert_problem_json(result, "x509_user_not_authorized")
    end

    test "returns distinct client-facing 403 errors for X.509 authentication failures" do
      reasons = [
        :invalid_certificate,
        :invalid_x509_identity,
        :malformed_cert_issuer,
        :malformed_cert_serial,
        :missing_client_auth_eku,
        :missing_digital_signature_key_usage,
        :no_device_identifiers,
        :no_trust_anchors,
        :outside_validity_window,
        :untrusted_chain,
        :x509_account_disabled,
        :x509_account_not_found,
        :x509_authentication_disabled,
        :x509_authentication_not_found,
        :x509_user_disabled,
        :x509_user_not_found,
        :x509_user_type_not_allowed
      ]

      details =
        Enum.map(reasons, fn reason ->
          result = Sockets.handle_error(Plug.Test.conn(:get, "/"), reason)

          assert result.status == 403
          assert_problem_json(result, Atom.to_string(reason))

          detail = json_body(result)["detail"]
          assert is_binary(detail) and detail != ""
          detail
        end)

      assert Enum.uniq(details) == details
    end

    test "returns 503 with retry-after header for rate_limit" do
      conn = Plug.Test.conn(:get, "/")

      result = Sockets.handle_error(conn, :rate_limit)

      assert result.status == 503
      assert json_body(result)["detail"] == "Service Unavailable"
      assert Plug.Conn.get_resp_header(result, "retry-after") == ["1"]
      assert_problem_json(result, "rate_limit")
    end

    test "returns 400 with changeset errors" do
      conn = Plug.Test.conn(:get, "/")

      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{}, [:name])
        |> Ecto.Changeset.validate_required([:name])

      result = Sockets.handle_error(conn, changeset)

      assert result.status == 400
      assert json_body(result)["detail"] =~ "name"
      assert_problem_json(result, "invalid_connect_params")
    end

    test "returns 500 and logs for an unhandled reason" do
      conn = Plug.Test.conn(:get, "/")

      {result, log} = with_log(fn -> Sockets.handle_error(conn, :some_new_reason) end)

      assert result.status == 500
      assert json_body(result)["detail"] == "An unexpected error occurred."
      assert_problem_json(result, "unhandled_connect_error")
      assert log =~ "Unhandled socket connect error"
      assert log =~ "some_new_reason"
    end
  end

  defp json_body(conn), do: JSON.decode!(conn.resp_body)

  defp assert_problem_json(conn, code) do
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"
    body = json_body(conn)
    assert body["type"] == "about:blank"
    assert body["code"] == code
    assert body["status"] == conn.status
    assert is_binary(body["title"])
  end
end
