defmodule PortalAPI.Integrations.WebhookBanditTest do
  use ExUnit.Case, async: true

  alias Portal.EndpointServer

  @acs_secret "acs-secret"
  @entra "/integrations/entra/webhooks"
  @stripe "/integrations/stripe/webhooks"
  @acs "/integrations/azure_communication_services/webhooks"
  @google "/integrations/google/webhooks"
  @report %{
    eventType: "Microsoft.Communication.EmailDeliveryReportReceived",
    data: %{messageId: "message", recipient: "user@example.com", status: "Bounced"}
  }

  # The request process is never allowed into the SQL sandbox, so the first
  # database call after a body read raises like a lost database connection.
  setup do
    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:bandit, :request, :exception], &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    port =
      EndpointServer.start(
        prepare: fn conn ->
          Portal.Config.put_env_override(:portal, :rest_api_url, "http://127.0.0.1")

          Portal.Config.put_env_override(:portal, Portal.AzureCommunicationServices,
            event_grid_webhook_signing_secret: @acs_secret
          )

          conn
        end
      )

    %{port: port}
  end

  for {name, path, headers, body, status, response} <- [
        {"Entra invalid JSON", @entra, [], "{", 400, "Bad Request: invalid JSON"},
        {"Entra missing notifications", @entra, [], "{}", 400,
         "Bad Request: missing notifications"},
        {"Entra oversized batch", @entra, [], JSON.encode!(%{value: List.duplicate(%{}, 1001)}),
         413, "Request Entity Too Large: too many notifications"},
        {"Stripe missing timestamp", @stripe, [{"stripe-signature", "v1=invalid"}], "{}", 400,
         "Bad Request: missing timestamp"},
        {"Stripe missing signatures", @stripe, [{"stripe-signature", "t=0"}], "{}", 400,
         "Bad Request: missing signatures"},
        {"Stripe expired signature", @stripe, [{"stripe-signature", "t=0,v1=invalid"}], "{}",
         400, "Bad Request: expired signature"},
        {"ACS invalid JSON", @acs, [{"aeg-event-type", "Notification"}], "{", 400,
         "Bad Request: invalid JSON"},
        {"ACS invalid secret", @acs, [{"aeg-event-type", "Notification"}], "[]", 401,
         "Unauthorized"},
        {"ACS invalid validation event", @acs, [{"aeg-event-type", "SubscriptionValidation"}],
         "[]", 400, "Bad Request: invalid validation event"},
        {"ACS unsupported event", @acs, [{"aeg-event-type", "Unknown"}], "[]", 400,
         "Bad Request: unsupported aeg-event-type"},
        {"ACS unsubscribe", @acs, [{"aeg-event-type", "Unsubscribe"}], "[]", 200, ""},
        {"ACS dispatch failure", @acs,
         [{"aeg-event-type", "Notification"}, {"aeg-sas-key", @acs_secret}],
         JSON.encode!([%{eventType: @report.eventType, data: "not-a-map"}]), 500,
         "Internal Error"}
      ] do
    test name, %{port: port} do
      response = EndpointServer.request(port, :post, unquote(path), unquote(headers), unquote(body))

      assert response.status == unquote(status)
      assert response.body == unquote(response)
    end
  end

  for {path, headers, size} <- [
        {@entra, [], 1_100_000},
        {@stripe, [{"stripe-signature", "v1=invalid"}], 1_100_000},
        {@acs, [{"aeg-event-type", "Notification"}], 8_100_000}
      ] do
    test "#{path} rejects an oversized body using the updated conn", %{port: port} do
      response =
        EndpointServer.request(
          port,
          :post,
          unquote(path),
          unquote(headers),
          String.duplicate("x", unquote(size))
        )

      assert response.status == 413
      assert response.body == "Request Entity Too Large"
    end
  end

  test "Stripe rejects an invalid signature after reading the body", %{port: port} do
    headers = [{"stripe-signature", "t=#{System.system_time(:second)},v1=invalid"}]
    response = EndpointServer.request(port, :post, @stripe, headers, "{}")

    assert response.status == 400
    assert response.body == "Bad Request: invalid signature"
  end

  test "Stripe returns its fallback response for signed invalid JSON", %{port: port} do
    response = EndpointServer.request(port, :post, @stripe, stripe_headers("{"), "{")

    assert response.status == 500
    assert response.body == "Internal Error"
  end

  for {name, path, headers, body, exception} <- [
        {"Stripe", @stripe, :stripe, "{}", FunctionClauseError},
        {"Entra", @entra <> "?directory_id=#{Ecto.UUID.generate()}", [],
         JSON.encode!(%{value: [%{clientState: "state"}]}), DBConnection.OwnershipError},
        {"Google", @google <> "?directory_id=#{Ecto.UUID.generate()}",
         [{"x-goog-resource-state", "update"}], JSON.encode!(%{id: "user"}),
         DBConnection.OwnershipError},
        {"ACS", @acs, [{"aeg-event-type", "Notification"}, {"aeg-sas-key", @acs_secret}],
         JSON.encode!([@report]), DBConnection.OwnershipError}
      ] do
    test "#{name} renders an exception raised after the body was read", %{port: port} do
      headers =
        case unquote(headers) do
          :stripe -> stripe_headers(unquote(body))
          headers -> headers
        end

      response = EndpointServer.request(port, :post, unquote(path), headers, unquote(body))

      assert response.status == 500

      assert JSON.decode!(response.body) == %{
               "type" => "about:blank",
               "title" => "Internal Server Error",
               "status" => 500
             }

      assert_receive {:bandit_exception, %{exception: %{__struct__: unquote(exception)}}}
    end
  end

  for {path, headers, body} <- [
        {@entra, [], "{"},
        {@stripe, [{"stripe-signature", "v1=invalid"}], "{}"},
        {@acs, [{"aeg-event-type", "Notification"}], "{"}
      ] do
    test "#{path} preserves the next request on the same connection", %{port: port} do
      response =
        EndpointServer.send_raw(port, [
          EndpointServer.raw_request("POST", unquote(path), unquote(headers), unquote(body)),
          EndpointServer.raw_request(
            "POST",
            @entra <> "?validationToken=still-alive",
            [{"Connection", "close"}],
            ""
          )
        ])

      assert response =~ "HTTP/1.1 400"
      assert response =~ "HTTP/1.1 200"
      assert String.ends_with?(response, "still-alive")
      refute response =~ "HTTP/1.1 500"
    end
  end

  def forward(_event, _measurements, metadata, pid), do: send(pid, {:bandit_exception, metadata})

  defp stripe_headers(body) do
    timestamp = System.system_time(:second)
    secret = Portal.Billing.fetch_webhook_signing_secret!()
    signature = PortalAPI.Integrations.Stripe.WebhookController.sign(timestamp, secret, body)
    [{"stripe-signature", "t=#{timestamp},v1=#{signature}"}]
  end
end
