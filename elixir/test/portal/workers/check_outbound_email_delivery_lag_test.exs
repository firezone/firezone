defmodule Portal.Workers.CheckOutboundEmailDeliveryLagTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.OutboundEmailFixtures

  alias Portal.OutboundEmailDelivery
  alias Portal.Workers.CheckOutboundEmailDeliveryLag

  setup do
    %{account: account_fixture()}
  end

  describe "perform/1" do
    test "logs an error when three messages have been pending for over ten minutes", %{
      account: account
    } do
      for _ <- 1..3, do: pending_message(account, minutes_ago: 11)

      log = capture_log(fn -> assert :ok = perform_job(CheckOutboundEmailDeliveryLag, %{}) end)

      assert log =~ "Outbound email delivery reports are lagging"
    end

    test "counts a message with several recipients once", %{account: account} do
      pending_message(account, minutes_ago: 11, recipients: ["a@test.com", "b@test.com"])
      pending_message(account, minutes_ago: 11)

      log = capture_log(fn -> assert :ok = perform_job(CheckOutboundEmailDeliveryLag, %{}) end)

      refute log =~ "Outbound email delivery reports are lagging"
    end

    test "ignores messages that are pending for less than ten minutes", %{account: account} do
      for _ <- 1..3, do: pending_message(account, minutes_ago: 9)

      log = capture_log(fn -> assert :ok = perform_job(CheckOutboundEmailDeliveryLag, %{}) end)

      refute log =~ "Outbound email delivery reports are lagging"
    end

    test "ignores messages sent more than an hour ago", %{account: account} do
      for _ <- 1..3, do: pending_message(account, minutes_ago: 61)

      log = capture_log(fn -> assert :ok = perform_job(CheckOutboundEmailDeliveryLag, %{}) end)

      refute log =~ "Outbound email delivery reports are lagging"
    end

    test "ignores messages that got a delivery report", %{account: account} do
      for _ <- 1..3 do
        message = pending_message(account, minutes_ago: 11)

        from(d in OutboundEmailDelivery, where: d.message_id == ^message.message_id)
        |> Repo.update_all(set: [status: :delivered])
      end

      log = capture_log(fn -> assert :ok = perform_job(CheckOutboundEmailDeliveryLag, %{}) end)

      refute log =~ "Outbound email delivery reports are lagging"
    end
  end

  defp pending_message(account, opts) do
    {minutes_ago, attrs} = Keyword.pop!(opts, :minutes_ago)
    message = outbound_email_fixture(account, attrs)
    inserted_at = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    from(d in OutboundEmailDelivery, where: d.message_id == ^message.message_id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    message
  end
end
