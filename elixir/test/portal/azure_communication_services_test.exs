defmodule Portal.AzureCommunicationServicesTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.AzureCommunicationServices

  describe "handle_event_grid_events/1" do
    test "updates delivery status to :delivered" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-1",
          recipients: ["delivered@example.com"]
        )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-1", "delivered@example.com", "Delivered")
               ])

      delivery = delivery!(entry, "delivered@example.com")
      assert delivery.status == :delivered
      assert is_nil(delivery.failure_code)
      assert is_nil(delivery.failure_message)
    end

    test "marks a recipient bounced and inserts a suppression" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-2",
          recipients: ["bounced@example.com"]
        )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-2",
                   "bounced@example.com",
                   "Bounced",
                   "Mailbox does not exist"
                 )
               ])

      delivery = delivery!(entry, "bounced@example.com")
      assert delivery.status == :bounced
      assert delivery.failure_code == "Bounced"
      assert delivery.failure_message == "Mailbox does not exist"

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "bounced@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1
    end

    test "marks a recipient suppressed and inserts a suppression" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-3",
          recipients: ["suppressed@example.com"]
        )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-3",
                   "suppressed@example.com",
                   "Suppressed",
                   "Recipient is on the suppression list"
                 )
               ])

      delivery = delivery!(entry, "suppressed@example.com")
      assert delivery.status == :suppressed

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "suppressed@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1
    end

    test "marks a recipient quarantined and inserts a suppression" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-quarantined",
          recipients: ["quarantined@example.com"]
        )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-quarantined",
                   "quarantined@example.com",
                   "Quarantined",
                   "Message was quarantined"
                 )
               ])

      delivery = delivery!(entry, "quarantined@example.com")
      assert delivery.status == :quarantined
      assert delivery.failure_code == "Quarantined"

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "quarantined@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1
    end

    test "marks a recipient filtered_spam and inserts a suppression" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-filtered",
          recipients: ["filtered@example.com"]
        )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-filtered",
                   "filtered@example.com",
                   "FilteredSpam",
                   "Message identified as spam"
                 )
               ])

      delivery = delivery!(entry, "filtered@example.com")
      assert delivery.status == :filtered_spam
      assert delivery.failure_code == "FilteredSpam"

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "filtered@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1
    end

    test "marks a recipient failed and inserts a suppression for unknown status" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-failed",
          recipients: ["failed@example.com"]
        )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-failed",
                   "failed@example.com",
                   "Failed",
                   "Unknown delivery failure"
                 )
               ])

      delivery = delivery!(entry, "failed@example.com")
      assert delivery.status == :failed
      assert delivery.failure_code == "Failed"
      assert delivery.failure_message == "Unknown delivery failure"

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "failed@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1
    end

    test "ignores out-of-order delivery events (stale: already terminal)" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-4",
          recipients: ["ordered@example.com"]
        )

      # First event delivers the recipient
      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-4", "ordered@example.com", "Delivered")
               ])

      assert delivery!(entry, "ordered@example.com").status == :delivered

      # Second event tries to bounce (out-of-order) — stale because status is no longer :pending
      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-4",
                   "ordered@example.com",
                   "Bounced",
                   "Old bounce"
                 )
               ])

      delivery = delivery!(entry, "ordered@example.com")
      assert delivery.status == :delivered

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "ordered@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 0
    end

    test "logs and returns ok for unknown message_id" do
      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("no-such-message", "anyone@example.com", "Delivered")
               ])
    end
  end

  defp delivery!(entry, email) do
    Repo.get_by!(Portal.OutboundEmailDelivery,
      account_id: entry.account_id,
      message_id: entry.message_id,
      email: email
    )
  end

  defp delivery_report_event(message_id, recipient, status, details \\ nil) do
    %{
      "id" => Ecto.UUID.generate(),
      "eventType" => "Microsoft.Communication.EmailDeliveryReportReceived",
      "eventTime" => "2026-03-13T07:00:00Z",
      "data" => %{
        "sender" => "notifications@firez.one",
        "messageId" => message_id,
        "recipient" => recipient,
        "status" => status,
        "deliveryStatusDetails" => if(details, do: %{"statusMessage" => details}),
        "deliveryAttemptTimeStamp" => "2026-03-13T07:00:00Z"
      }
    }
  end
end
