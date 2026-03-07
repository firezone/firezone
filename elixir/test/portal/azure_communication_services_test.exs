defmodule Portal.AzureCommunicationServicesTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.AzureCommunicationServices

  describe "handle_event_grid_events/1" do
    test "marks a message succeeded once all recipients are delivered" do
      account = account_fixture()
      entry = outbound_email_fixture(account, message_id: "message-1")
      recipient_fixture(entry, email: "delivered@example.com")

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-1", "delivered@example.com", "Delivered")
               ])

      recipient = recipient!(entry, "delivered@example.com")
      assert recipient.status == :delivered
      assert recipient.last_event_at == ~U[2026-03-13 07:00:00.000000Z]
      assert is_nil(recipient.failure_code)
      assert is_nil(recipient.failure_message)

      entry = entry!(entry)
      assert entry.status == :succeeded
      assert is_nil(entry.failed_at)
      assert entry.response["delivery_state"] == "Succeeded"
    end

    test "keeps the message running until all recipients are terminal" do
      account = account_fixture()
      entry = outbound_email_fixture(account, message_id: "message-pending")
      recipient_fixture(entry, email: "first@example.com")
      recipient_fixture(entry, email: "second@example.com")

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-pending", "first@example.com", "Delivered")
               ])

      assert recipient!(entry, "first@example.com").status == :delivered
      assert recipient!(entry, "second@example.com").status == :pending

      entry = entry!(entry)
      assert entry.status == :running
      assert is_nil(entry.failed_at)
      assert entry.response["delivery_state"] == "Running"
      assert entry.response["recipient_counts"] == %{"failed" => 0, "pending" => 1}
    end

    test "marks a message failed when any recipient ends in a failed state" do
      account = account_fixture()
      entry = outbound_email_fixture(account, message_id: "message-2")
      recipient_fixture(entry, email: "bounced@example.com")

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-2",
                   "bounced@example.com",
                   "Bounced",
                   "Mailbox does not exist"
                 )
               ])

      recipient = recipient!(entry, "bounced@example.com")
      assert recipient.status == :bounced
      assert recipient.failure_code == "Bounced"
      assert recipient.failure_message == "Mailbox does not exist"

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "bounced@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1

      entry = entry!(entry)
      assert entry.status == :failed
      assert entry.failed_at == ~U[2026-03-13 07:00:00.000000Z]
      assert entry.response["delivery_state"] == "Failed"
    end

    test "marks a recipient suppressed and inserts a suppression" do
      account = account_fixture()
      entry = outbound_email_fixture(account, message_id: "message-3")
      recipient_fixture(entry, email: "suppressed@example.com")

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-3",
                   "suppressed@example.com",
                   "Suppressed",
                   "Recipient is on the suppression list"
                 )
               ])

      recipient = recipient!(entry, "suppressed@example.com")
      assert recipient.status == :suppressed

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "suppressed@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 1

      entry = entry!(entry)
      assert entry.status == :failed
      assert entry.failed_at == ~U[2026-03-13 07:00:00.000000Z]
    end

    test "ignores out-of-order recipient events" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          message_id: "message-4",
          status: :succeeded,
          response: %{"delivery_state" => "Succeeded"}
        )

      recipient_fixture(entry,
        email: "ordered@example.com",
        status: :delivered,
        last_event_at: ~U[2026-03-13 07:00:00.000000Z]
      )

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event(
                   "message-4",
                   "ordered@example.com",
                   "Bounced",
                   "Old bounce",
                   "2026-03-13T06:59:00Z"
                 )
               ])

      recipient = recipient!(entry, "ordered@example.com")
      assert recipient.status == :delivered
      assert recipient.last_event_at == ~U[2026-03-13 07:00:00.000000Z]

      entry = entry!(entry)
      assert entry.status == :succeeded

      suppressed =
        from(s in Portal.EmailSuppression, where: s.email == "ordered@example.com")
        |> Repo.aggregate(:count, :email)

      assert suppressed == 0
    end

    test "returns an error when the tracked recipient row is missing" do
      account = account_fixture()
      _entry = outbound_email_fixture(account, message_id: "message-5")

      assert {:error, {:unknown_recipient, "message-5", "missing@example.com"}} =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-5", "missing@example.com", "Delivered")
               ])
    end

    test "marks a message failed once the last pending recipient resolves unsuccessfully" do
      account = account_fixture()
      entry = outbound_email_fixture(account, message_id: "message-6")
      recipient_fixture(entry, email: "delivered@example.com")
      recipient_fixture(entry, email: "failed@example.com")

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-6", "failed@example.com", "Bounced", "No mailbox")
               ])

      assert entry!(entry).status == :running

      assert :ok =
               AzureCommunicationServices.handle_event_grid_events([
                 delivery_report_event("message-6", "delivered@example.com", "Delivered")
               ])

      entry = entry!(entry)
      assert entry.status == :failed
      assert entry.failed_at == ~U[2026-03-13 07:00:00.000000Z]
      assert entry.response["recipient_counts"] == %{"failed" => 1, "pending" => 0}
    end
  end

  defp recipient_fixture(entry, attrs) do
    defaults = [
      account_id: entry.account_id,
      message_id: entry.message_id,
      email: "recipient@example.com",
      status: :pending
    ]

    Repo.insert!(struct(Portal.OutboundEmailRecipient, Keyword.merge(defaults, attrs)))
  end

  defp recipient!(entry, email) do
    Repo.get_by!(Portal.OutboundEmailRecipient,
      account_id: entry.account_id,
      message_id: entry.message_id,
      email: email
    )
  end

  defp entry!(entry) do
    Repo.get_by!(Portal.OutboundEmail,
      account_id: entry.account_id,
      message_id: entry.message_id
    )
  end

  defp delivery_report_event(
         message_id,
         recipient,
         status,
         details \\ nil,
         event_time \\ "2026-03-13T07:00:00Z"
       ) do
    %{
      "id" => Ecto.UUID.generate(),
      "eventType" => "Microsoft.Communication.EmailDeliveryReportReceived",
      "eventTime" => event_time,
      "data" => %{
        "messageId" => message_id,
        "recipient" => recipient,
        "deliveryStatus" => status,
        "deliveryStatusDetails" => details
      }
    }
  end
end
