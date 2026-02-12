defmodule Portal.Workers.CheckAccountLimitsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientSessionFixtures

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

      # Verify account_id and account_slug are present
      assert first_email.text_body =~ account.id
      assert first_email.text_body =~ account.slug

      # Verify count/limit format (3 admins / 1 limit)
      assert first_email.text_body =~ "account admins (3 / 1)"
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
      refute Portal.Billing.any_limit_exceeded?(account)
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
      refute Portal.Billing.any_limit_exceeded?(account)
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

    test "email shows multiple exceeded limits with count/limit format" do
      account = provisioned_account_fixture()
      # Create 3 admins (exceed limit of 1)
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      # Create 2 service accounts (exceed limit of 1)
      actor_fixture(account: account, type: :service_account)
      actor_fixture(account: account, type: :service_account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1,
          service_accounts_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      emails_sent = collect_sent_emails()
      [first_email | _] = emails_sent

      # Verify multiple limits with counts
      assert first_email.text_body =~ "service accounts (2 / 1)"
      assert first_email.text_body =~ "account admins (3 / 1)"
    end

    test "email shows Team plan CTA for Team accounts" do
      account = provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Team"}}})
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{limits: %{account_admin_users_count: 1}})

      assert :ok = perform_job(CheckAccountLimits, %{})

      [first_email | _] = collect_sent_emails()
      assert first_email.text_body =~ "change your paid users"
      assert first_email.text_body =~ "Settings"
      assert first_email.text_body =~ "Billing"
      assert first_email.text_body =~ "Manage"
    end

    test "email shows Starter plan CTA for Starter accounts" do
      account = provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Starter"}}})
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{limits: %{account_admin_users_count: 1}})

      assert :ok = perform_job(CheckAccountLimits, %{})

      [first_email | _] = collect_sent_emails()
      assert first_email.text_body =~ "upgrade to Team"
      assert first_email.text_body =~ "Settings"
      assert first_email.text_body =~ "Billing"
    end

    test "email shows Enterprise plan CTA for Enterprise accounts" do
      account = provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Enterprise"}}})
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{limits: %{account_admin_users_count: 1}})

      assert :ok = perform_job(CheckAccountLimits, %{})

      [first_email | _] = collect_sent_emails()
      assert first_email.text_body =~ "contact your account manager"
    end

    test "logs warning when seats_limit_exceeded transitions from false to true" do
      account = provisioned_account_fixture()
      admin = admin_actor_fixture(account: account)

      # Create a client with recent session to count as active user
      client = Portal.ClientFixtures.client_fixture(account: account, actor: admin)
      client_session_fixture(account: account, actor: admin, client: client)

      # Set a low monthly_active_users_count limit
      update_account(account, %{
        seats_limit_exceeded: false,
        limits: %{monthly_active_users_count: 0}
      })

      log =
        capture_log(fn ->
          assert :ok = perform_job(CheckAccountLimits, %{})
        end)

      assert log =~ "Account seats limit exceeded"
      assert log =~ account.id
      assert log =~ account.slug

      # Verify the flag was set
      account = Repo.get!(Portal.Account, account.id)
      assert account.seats_limit_exceeded
    end

    test "does not log warning when seats_limit_exceeded remains true" do
      account = provisioned_account_fixture()
      admin = admin_actor_fixture(account: account)

      # Create a client with recent session
      client = Portal.ClientFixtures.client_fixture(account: account, actor: admin)
      client_session_fixture(account: account, actor: admin, client: client)

      # Set the flag as already exceeded
      update_account(account, %{
        seats_limit_exceeded: true,
        warning_last_sent_at: DateTime.utc_now(),
        limits: %{monthly_active_users_count: 0}
      })

      log =
        capture_log(fn ->
          assert :ok = perform_job(CheckAccountLimits, %{})
        end)

      refute log =~ "Account seats limit exceeded"

      # Flag should still be true
      account = Repo.get!(Portal.Account, account.id)
      assert account.seats_limit_exceeded
    end
  end

  defp provisioned_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)

    stripe_attrs =
      Map.merge(
        %{
          customer_id: "cus_#{System.unique_integer([:positive])}",
          subscription_id: "sub_#{System.unique_integer([:positive])}",
          product_name: "Team"
        },
        get_in(attrs, [:metadata, :stripe]) || %{}
      )

    account
    |> Ecto.Changeset.cast(%{metadata: %{stripe: stripe_attrs}}, [])
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
