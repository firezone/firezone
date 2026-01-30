defmodule Portal.Workers.CheckAccountLimitsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Workers.CheckAccountLimits

  describe "perform/1" do
    test "does nothing when limits are not violated" do
      account = provisioned_account_fixture()
      admin_actor_fixture(account: account)

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = Repo.get!(Portal.Account, account.id)
      refute account.users_limit_exceeded
      refute account.seats_limit_exceeded
      refute account.service_accounts_limit_exceeded
      refute account.sites_limit_exceeded
      refute account.admins_limit_exceeded
      refute account.warning_last_sent_at
    end

    test "sets warning when limits are violated" do
      account = provisioned_account_fixture()
      admin_actor_fixture(account: account)

      # Create multiple admins to exceed limit
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = Repo.get!(Portal.Account, account.id)

      assert account.admins_limit_exceeded
      refute account.users_limit_exceeded
      refute account.seats_limit_exceeded
      refute account.service_accounts_limit_exceeded
      refute account.sites_limit_exceeded
      assert account.warning_last_sent_at
    end

    test "sends email to admins when limits are first exceeded" do
      account = provisioned_account_fixture()
      admin1 = admin_actor_fixture(account: account)
      admin2 = admin_actor_fixture(account: account)
      admin3 = admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      # Collect all sent emails
      emails_sent = collect_sent_emails()

      # All 3 admins should receive emails
      assert length(emails_sent) == 3

      email_recipients =
        emails_sent
        |> Enum.flat_map(fn email -> email.to end)
        |> Enum.map(fn
          {_name, email} -> email
          email when is_binary(email) -> email
        end)

      assert admin1.email in email_recipients
      assert admin2.email in email_recipients
      assert admin3.email in email_recipients

      # Verify email content
      [first_email | _] = emails_sent
      assert first_email.subject == "Firezone Account Limits Exceeded"
      assert first_email.text_body =~ "exceeded the following limits"
      assert first_email.text_body =~ "account admins"
    end

    test "does not send email if warning_last_sent_at is less than 3 days ago" do
      account = provisioned_account_fixture()
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      # Set warning_last_sent_at to 2 days ago
      two_days_ago = DateTime.utc_now() |> DateTime.add(-2, :day)

      update_account(account, %{
        admins_limit_exceeded: true,
        warning_last_sent_at: two_days_ago,
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      # No new emails should be sent
      refute_email_sent()

      # warning_last_sent_at should not be updated
      account = Repo.get!(Portal.Account, account.id)
      assert DateTime.compare(account.warning_last_sent_at, two_days_ago) == :eq
    end

    test "sends email again if warning_last_sent_at is more than 3 days ago" do
      account = provisioned_account_fixture()
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      # Set warning_last_sent_at to 4 days ago
      four_days_ago = DateTime.utc_now() |> DateTime.add(-4, :day)

      update_account(account, %{
        admins_limit_exceeded: true,
        warning_last_sent_at: four_days_ago,
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      # Email should be sent again
      assert_email_sent(fn email ->
        assert email.subject == "Firezone Account Limits Exceeded"
      end)

      # warning_last_sent_at should be updated
      account = Repo.get!(Portal.Account, account.id)
      assert DateTime.compare(account.warning_last_sent_at, four_days_ago) == :gt
    end

    test "clears limit flags and warning_last_sent_at when limits are no longer exceeded" do
      account = provisioned_account_fixture()
      admin_actor_fixture(account: account)

      # Set existing limit flags
      update_account(account, %{
        admins_limit_exceeded: true,
        warning_last_sent_at: DateTime.utc_now()
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = Repo.get!(Portal.Account, account.id)
      refute account.users_limit_exceeded
      refute account.seats_limit_exceeded
      refute account.service_accounts_limit_exceeded
      refute account.sites_limit_exceeded
      refute account.admins_limit_exceeded
      refute account.warning_last_sent_at
    end

    test "does not process non-provisioned accounts" do
      # Account without stripe metadata is not provisioned
      account = account_fixture()
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = Repo.get!(Portal.Account, account.id)
      refute Portal.Account.any_limit_exceeded?(account)
      refute_email_sent()
    end

    test "does not process disabled accounts" do
      account = provisioned_account_fixture()
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      # Disable the account
      account
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(), disabled_reason: "Test")
      |> Repo.update!()

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = Repo.get!(Portal.Account, account.id)
      refute Portal.Account.any_limit_exceeded?(account)
      refute_email_sent()
    end

    test "only sends emails to enabled admin actors" do
      account = provisioned_account_fixture()
      admin1 = admin_actor_fixture(account: account)

      # Create disabled admin
      disabled_admin = admin_actor_fixture(account: account)

      disabled_admin
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

      # Create another enabled admin
      admin2 = admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      # Collect all sent emails
      emails_sent = collect_sent_emails()

      # Only 2 enabled admins should receive emails
      assert length(emails_sent) == 2

      email_recipients =
        emails_sent
        |> Enum.flat_map(fn email -> email.to end)
        |> Enum.map(fn {_name, email} -> email end)

      assert admin1.email in email_recipients
      assert admin2.email in email_recipients
      refute disabled_admin.email in email_recipients
    end
  end

  defp provisioned_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)

    account
    |> Ecto.Changeset.cast(
      %{
        metadata: %{
          stripe: %{
            customer_id: "cus_#{System.unique_integer([:positive])}",
            subscription_id: "sub_#{System.unique_integer([:positive])}",
            product_name: "Team"
          }
        }
      },
      []
    )
    |> Ecto.Changeset.cast_embed(:metadata)
    |> Repo.update!()
  end

  defp collect_sent_emails do
    collect_sent_emails([])
  end

  defp collect_sent_emails(acc) do
    receive do
      {:email, email} -> collect_sent_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
