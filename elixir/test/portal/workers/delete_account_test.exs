defmodule Portal.Workers.DeleteAccountTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.DeleteAccount

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers

  alias Portal.Mocks.Stripe

  describe "perform/1" do
    test "deletes the account and emails admins when deletion is due" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      admin = admin_actor_fixture(account: account)

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Deletion Complete"
      assert email.text_body =~ account.slug
      assert email.text_body =~ account.id
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [admin.email]
    end

    test "deletes the account without emailing when there are no admin actors" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
      assert collect_queued_emails(account.id) == []
    end

    test "does nothing when the account does not exist" do
      assert :ok = perform_job(DeleteAccount, %{"account_id" => Ecto.UUID.generate()})
    end

    test "does nothing when the account was unscheduled" do
      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: nil
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
      assert collect_queued_emails(account.id) == []
    end

    test "does nothing when the account is not disabled" do
      account =
        update_account(account_fixture(),
          disabled_at: nil,
          scheduled_deletion_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
      assert collect_queued_emails(account.id) == []
    end

    test "cancels the Stripe subscription before deleting the account" do
      subscription_id = "sub_#{System.unique_integer([:positive])}"

      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at,
          metadata: %{stripe: %{subscription_id: subscription_id}}
        )

      Stripe.stub(Stripe.mock_cancel_subscription_endpoint(subscription_id))

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
    end

    test "succeeds when the Stripe subscription is already canceled (idempotency)" do
      subscription_id = "sub_#{System.unique_integer([:positive])}"

      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at,
          metadata: %{stripe: %{subscription_id: subscription_id}}
        )

      Stripe.stub(Stripe.mock_cancel_subscription_endpoint(subscription_id, 404, %{}))

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
    end

    test "fails the job when Stripe subscription cancellation fails" do
      subscription_id = "sub_#{System.unique_integer([:positive])}"

      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at,
          metadata: %{stripe: %{subscription_id: subscription_id}}
        )

      Stripe.stub(Stripe.mock_cancel_subscription_endpoint(subscription_id, 500, %{}))

      assert {:error, _} = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
    end

    test "deletes the account without calling Stripe when billing is disabled" do
      Portal.Config.put_env_override(Portal.Billing, enabled: false)

      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at,
          metadata: %{stripe: %{subscription_id: "sub_should_not_be_called"}}
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
    end

    test "deletes the account without calling Stripe when account has no subscription" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
    end

    test "snoozes the job until the scheduled deletion time when deletion is not yet due" do
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert {:snooze, snooze_seconds} = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert snooze_seconds > 0
      assert fetch_account(account.id)
      assert collect_queued_emails(account.id) == []
    end
  end
end
