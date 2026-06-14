defmodule PortalAPI.Integrations.AzureCommunicationServices.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  setup do
    Portal.Config.put_env_override(:portal, Portal.AzureCommunicationServices,
      event_grid_webhook_signing_secret: "acs-secret"
    )

    :ok
  end

  describe "handle_webhook/2" do
    test "returns the validation response for subscription validation events", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "SubscriptionValidation")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          validation_payload("abc123")
        )

      assert json_response(conn, 200) == %{"validationResponse" => "abc123"}
    end

    test "returns unauthorized when the webhook secret is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> put_req_header("aeg-sas-key", "wrong")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          notification_payload()
        )

      assert response(conn, 401) == "Unauthorized"
    end

    test "processes notification events", %{conn: conn} do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-1",
          recipients: ["delivered@example.com"]
        )

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> put_req_header("aeg-sas-key", "acs-secret")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          notification_payload()
        )

      assert response(conn, 200) == ""

      delivery =
        Repo.get_by!(Portal.OutboundEmailDelivery,
          account_id: account.id,
          message_id: entry.message_id,
          email: "delivered@example.com"
        )

      assert delivery.status == :delivered
    end

    test "returns 200 for unknown message_id so Event Grid does not retry", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> put_req_header("aeg-sas-key", "acs-secret")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          notification_payload()
        )

      assert response(conn, 200) == ""
    end

    test "returns 400 when the aeg-event-type header is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          notification_payload()
        )

      assert response(conn, 400) == "Bad Request: missing aeg-event-type header"
    end

    test "returns 400 for invalid JSON", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          "{not valid json"
        )

      assert response(conn, 400) == "Bad Request: invalid JSON"
    end

    test "returns 400 for a validation event without a validation code", %{conn: conn} do
      payload = JSON.encode!([%{"data" => %{}}])

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "SubscriptionValidation")
        |> post("/integrations/azure_communication_services/webhooks", payload)

      assert response(conn, 400) == "Bad Request: invalid validation event"
    end

    test "returns 200 for Unsubscribe events", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Unsubscribe")
        |> post("/integrations/azure_communication_services/webhooks", JSON.encode!([]))

      assert response(conn, 200) == ""
    end

    test "returns 400 for unsupported event types", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "SomethingElse")
        |> post("/integrations/azure_communication_services/webhooks", JSON.encode!([]))

      assert response(conn, 400) == "Bad Request: unsupported aeg-event-type"
    end

    test "returns 401 when the webhook secret is not configured", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.AzureCommunicationServices,
        event_grid_webhook_signing_secret: nil
      )

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> put_req_header("aeg-sas-key", "acs-secret")
        |> post(
          "/integrations/azure_communication_services/webhooks",
          notification_payload()
        )

      assert response(conn, 401) == "Unauthorized"
    end

    test "returns 500 when event handling fails so Event Grid will retry", %{conn: conn} do
      import ExUnit.CaptureLog

      payload =
        JSON.encode!([
          %{
            "id" => Ecto.UUID.generate(),
            "eventType" => "Microsoft.Communication.EmailDeliveryReportReceived",
            "eventTime" => "2026-03-13T07:00:00Z",
            "data" => "not-a-map"
          }
        ])

      {conn, _log} =
        with_log(fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("aeg-event-type", "Notification")
          |> put_req_header("aeg-sas-key", "acs-secret")
          |> post("/integrations/azure_communication_services/webhooks", payload)
        end)

      assert response(conn, 500) == "Internal Error"
    end
  end

  defp validation_payload(code) do
    JSON.encode!([
      %{
        "eventType" => "Microsoft.EventGrid.SubscriptionValidationEvent",
        "data" => %{"validationCode" => code}
      }
    ])
  end

  defp notification_payload do
    JSON.encode!([
      %{
        "id" => Ecto.UUID.generate(),
        "eventType" => "Microsoft.Communication.EmailDeliveryReportReceived",
        "eventTime" => "2026-03-13T07:00:00Z",
        "data" => %{
          "sender" => "notifications@firez.one",
          "messageId" => "message-1",
          "recipient" => "delivered@example.com",
          "status" => "Delivered",
          "deliveryStatusDetails" => %{"statusMessage" => "Delivered successfully"},
          "deliveryAttemptTimeStamp" => "2026-03-13T07:00:00Z"
        }
      }
    ])
  end
end
