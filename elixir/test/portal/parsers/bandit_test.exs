defmodule Portal.Parsers.BanditTest do
  use ExUnit.Case, async: true

  alias Portal.EndpointServer

  @form "application/x-www-form-urlencoded"
  @json "application/json"

  describe "PortalWeb.Endpoint" do
    setup do
      %{port: EndpointServer.start()}
    end

    for {name, content_type, body, status, reason} <- [
          {"invalid UTF-8 form", @form, "a=%FF", 400, "Bad Request"},
          {"oversized form", @form, String.duplicate("a", 1_000_001), 413,
           "Request Entity Too Large"},
          {"malformed JSON", @json, "{", 400, "Bad Request"},
          {"oversized JSON", @json, String.duplicate(" ", 8_000_001), 413,
           "Request Entity Too Large"}
        ] do
      test "#{name} renders #{status} with the conn returned by the body read", %{port: port} do
        response =
          EndpointServer.send_raw(
            port,
            EndpointServer.raw_request(
              "POST",
              "/",
              [{"Content-Type", unquote(content_type)}],
              unquote(body),
              "localhost"
            )
          )

        assert response =~ "HTTP/1.1 #{unquote(status)}"
        assert String.ends_with?(response, unquote(reason))
      end
    end
  end

  describe "PortalOps.Endpoint" do
    setup do
      %{port: EndpointServer.start(endpoint: PortalOps.Endpoint)}
    end

    for {name, body, status, reason} <- [
          {"invalid UTF-8 form", "a=%FF", 400, "Bad Request"},
          {"oversized form", String.duplicate("a", 1_000_001), 413, "Request Entity Too Large"}
        ] do
      test "#{name} renders #{status} with the conn returned by the body read", %{port: port} do
        response =
          EndpointServer.send_raw(
            port,
            EndpointServer.raw_request("POST", "/", [{"Content-Type", @form}], unquote(body))
          )

        assert response =~ "HTTP/1.1 #{unquote(status)}"
        assert String.ends_with?(response, unquote(reason))
      end
    end
  end
end
