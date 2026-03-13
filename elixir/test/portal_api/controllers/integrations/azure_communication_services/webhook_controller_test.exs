defmodule PortalAPI.Integrations.AzureCommunicationServices.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  setup do
    Portal.Config.put_env_override(:portal, Portal.AzureCommunicationServices,
      event_grid_webhook_secret: "acs-secret"
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
        |> post(
          "/integrations/azure_communication_services/webhooks?secret=wrong",
          notification_payload()
        )

      assert response(conn, 401) == "Unauthorized"
    end

    test "processes notification events", %{conn: conn} do
      account = account_fixture()
      entry = outbound_email_fixture(account, message_id: "message-1")

      Repo.insert!(%Portal.OutboundEmailRecipient{
        account_id: account.id,
        message_id: entry.message_id,
        email: "delivered@example.com",
        status: :pending
      })

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> post(
          "/integrations/azure_communication_services/webhooks?secret=acs-secret",
          notification_payload()
        )

      assert response(conn, 200) == ""

      recipient =
        Repo.get_by!(Portal.OutboundEmailRecipient,
          account_id: account.id,
          message_id: entry.message_id,
          email: "delivered@example.com"
        )

      assert recipient.status == :delivered

      entry =
        Repo.get_by!(Portal.OutboundEmail,
          account_id: account.id,
          message_id: entry.message_id
        )

      assert entry.status == :succeeded
    end

    test "returns 500 when notification handling fails so Event Grid retries", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("aeg-event-type", "Notification")
        |> post(
          "/integrations/azure_communication_services/webhooks?secret=acs-secret",
          notification_payload()
        )

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
          "messageId" => "message-1",
          "recipient" => "delivered@example.com",
          "deliveryStatus" => "Delivered"
        }
      }
    ])
  end
end
