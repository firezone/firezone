defmodule Portal.EmailDeliverabilityTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.EmailDeliverability

  describe "recipient deliverability" do
    test "marks a single recipient as delivered without touching the queue row" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "msg-delivered"
        )

      recipient =
        Repo.insert!(%Portal.OutboundEmailRecipient{
          account_id: account.id,
          outbound_email_id: entry.id,
          kind: :bcc,
          email: "recipient@example.com",
          status: :pending
        })

      assert {:ok, 1} =
               EmailDeliverability.mark_delivered("msg-delivered", " Recipient@Example.com ")

      delivered = Repo.get!(Portal.OutboundEmailRecipient, recipient.id)
      assert delivered.status == :delivered
      assert delivered.last_event_at != nil
      assert is_nil(delivered.failure_code)
      assert is_nil(delivered.failure_message)

      queue_entry = Repo.get_by!(Portal.OutboundEmail, id: entry.id)
      assert queue_entry.status == :running
    end

    test "marks a bounced recipient and inserts an internal suppression" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "msg-bounced"
        )

      recipient =
        Repo.insert!(%Portal.OutboundEmailRecipient{
          account_id: account.id,
          outbound_email_id: entry.id,
          kind: :to,
          email: "bounce@example.com",
          status: :pending
        })

      assert {:ok, 1} =
               EmailDeliverability.mark_bounced("msg-bounced", "bounce@example.com",
                 failure_code: "MailboxDoesNotExist",
                 failure_message: "Hard bounce"
               )

      bounced = Repo.get!(Portal.OutboundEmailRecipient, recipient.id)
      assert bounced.status == :bounced
      assert bounced.failure_code == "MailboxDoesNotExist"
      assert bounced.failure_message == "Hard bounce"

      suppression =
        Repo.get!(
          Portal.EmailSuppression,
          Portal.EmailSuppression.normalize_email("bounce@example.com")
        )

      assert suppression.email == "bounce@example.com"
    end

    test "marks a failed recipient without suppressing it" do
      account = account_fixture()

      entry =
        outbound_email_fixture(account,
          priority: :later,
          status: :running,
          message_id: "msg-failed"
        )

      recipient =
        Repo.insert!(%Portal.OutboundEmailRecipient{
          account_id: account.id,
          outbound_email_id: entry.id,
          kind: :to,
          email: "failed@example.com",
          status: :pending
        })

      assert {:ok, 1} =
               EmailDeliverability.mark_failed("msg-failed", "failed@example.com",
                 failure_code: "MailboxTemporarilyUnavailable",
                 failure_message: "Transient failure"
               )

      failed = Repo.get!(Portal.OutboundEmailRecipient, recipient.id)
      assert failed.status == :failed
      assert failed.failure_code == "MailboxTemporarilyUnavailable"
      assert failed.failure_message == "Transient failure"
      refute Repo.get(Portal.EmailSuppression, "failed@example.com")
    end
  end
end
