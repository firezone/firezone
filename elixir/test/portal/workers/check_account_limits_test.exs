defmodule Portal.Workers.CheckAccountLimitsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.ClientSessionFixtures

  alias Portal.Workers.CheckAccountLimits

  describe "perform/1" do
    test "count batching returns zero counts for accounts without counted records" do
      account = provisioned_account_fixture()

      assert %{
               account.id => %{
                 users: 0,
                 active_users: 0,
                 service_accounts: 0,
                 sites: 0,
                 admins: 0
               }
             } == CheckAccountLimits.Database.fetch_counts_for_accounts([account])
    end

    test "counts active service accounts as monthly active users" do
      account = provisioned_account_fixture()
      user = actor_fixture(account: account, type: :account_user)
      service_account = actor_fixture(account: account, type: :service_account)

      for actor <- [user, service_account] do
        client = Portal.DeviceFixtures.client_fixture(account: account, actor: actor)
        client_session_fixture(account: account, actor: actor, client: client)
      end

      assert %{active_users: 2} =
               CheckAccountLimits.Database.fetch_counts_for_accounts([account])[account.id]
    end

    test "counts only service accounts beyond service_account_seats as monthly active users" do
      account =
        update_account(provisioned_account_fixture(), %{limits: %{service_account_seats: 1}})

      for type <- [:account_user, :service_account, :service_account] do
        actor = actor_fixture(account: account, type: type)
        client = Portal.DeviceFixtures.client_fixture(account: account, actor: actor)
        client_session_fixture(account: account, actor: actor, client: client)
      end

      assert %{active_users: 2} =
               CheckAccountLimits.Database.fetch_counts_for_accounts([account])[account.id]
    end

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
      emails_sent = collect_queued_emails(account.id)

      # One batched email should be queued with all 3 admins in BCC
      assert length(emails_sent) == 1

      email_recipients =
        emails_sent
        |> Enum.flat_map(fn email -> email.bcc end)
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

    test "sets limit flags but sends no email for an account with no session logs" do
      account = dormant_provisioned_account_fixture()
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      refute_email_queued(account.id)

      account = Repo.get!(Portal.Account, account.id)
      assert account.admins_limit_exceeded
      # The reminder clock only starts once there is somebody to remind.
      refute account.warning_last_sent_at
    end

    test "sends email to a paid account with no session logs" do
      account =
        dormant_provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Team"}}})

      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{
        limits: %{
          account_admin_users_count: 1
        }
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert [_email] = collect_queued_emails(account.id)

      account = Repo.get!(Portal.Account, account.id)
      assert account.warning_last_sent_at
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
      refute_email_queued(account.id)

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
      assert_email_queued(account.id, fn email ->
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
      refute_email_queued(account.id)
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
      |> Ecto.Changeset.change(is_disabled: true, disabled_reason: "Test")
      |> Repo.update!()

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = Repo.get!(Portal.Account, account.id)
      refute Portal.Billing.any_limit_exceeded?(account)
      refute_email_queued(account.id)
    end

    test "processes accounts beyond the first batch" do
      warning_last_sent_at = DateTime.utc_now()

      account_ids =
        for _ <- 1..101 do
          account =
            provisioned_account_fixture()
            |> update_account(%{
              limits: %{account_admin_users_count: 0},
              warning_last_sent_at: warning_last_sent_at
            })

          admin_actor_fixture(account: account)
          account.id
        end

      assert :ok = perform_job(CheckAccountLimits, %{})

      exceeded_count =
        from(a in Portal.Account,
          where: a.id in ^account_ids,
          where: a.admins_limit_exceeded
        )
        |> Repo.aggregate(:count)

      assert exceeded_count == 101
    end

    test "only sends emails to enabled admin actors" do
      account = provisioned_account_fixture()
      admin1 = admin_actor_fixture(account: account)

      # Create disabled admin
      disabled_admin = admin_actor_fixture(account: account)

      disabled_admin
      |> Ecto.Changeset.change(is_disabled: true)
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
      emails_sent = collect_queued_emails(account.id)

      # One batched email should be queued with only the enabled admins in BCC
      assert length(emails_sent) == 1

      email_recipients =
        emails_sent
        |> Enum.flat_map(fn email -> email.bcc end)
        |> Enum.map(fn {_name, email} -> email end)

      assert admin1.email in email_recipients
      assert admin2.email in email_recipients
      refute disabled_admin.email in email_recipients
    end

    test "logs and does not enqueue email when no admins can receive exceeded limit warning" do
      account = provisioned_account_fixture()
      actor_fixture(account: account, type: :account_user)
      update_account(account, %{limits: %{users_count: 0}})

      log =
        capture_log(fn ->
          assert :ok = perform_job(CheckAccountLimits, %{})
        end)

      assert log =~ "No admin actors found for account"
      assert log =~ account.id
      refute_email_queued(account.id)
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

      emails_sent = collect_queued_emails(account.id)
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

      [first_email | _] = collect_queued_emails(account.id)
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

      [first_email | _] = collect_queued_emails(account.id)
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

      [first_email | _] = collect_queued_emails(account.id)
      assert first_email.text_body =~ "contact your account manager"
    end

    test "email shows Business plan CTA for Business accounts" do
      account = provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Business"}}})
      admin_actor_fixture(account: account)
      admin_actor_fixture(account: account)

      update_account(account, %{limits: %{account_admin_users_count: 1}})

      assert :ok = perform_job(CheckAccountLimits, %{})

      [first_email | _] = collect_queued_emails(account.id)
      assert first_email.text_body =~ "Settings -> Account"
    end

    test "logs warning when seats_limit_exceeded transitions from false to true" do
      account = provisioned_account_fixture()
      admin = admin_actor_fixture(account: account)

      # Create a client with recent session to count as active user
      client = Portal.DeviceFixtures.client_fixture(account: account, actor: admin)
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
      client = Portal.DeviceFixtures.client_fixture(account: account, actor: admin)
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

  describe "seat warning emails" do
    setup do
      account = provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Business"}}})
      admin = admin_actor_fixture(account: account)

      account = update_account(account, %{limits: %{monthly_active_users_count: 10}})
      %{account: account, admin: admin}
    end

    defp make_seats_active(account, count) do
      for _ <- 1..count do
        actor = actor_fixture(account: account)
        client = Portal.DeviceFixtures.client_fixture(account: account, actor: actor)
        client_session_fixture(account: account, actor: actor, client: client)
      end
    end

    test "sends the approaching email when fewer than 10% of seats remain", %{
      account: account,
      admin: admin
    } do
      account = update_account(account, %{limits: %{monthly_active_users_count: 20}})
      make_seats_active(account, 19)

      assert :ok = perform_job(CheckAccountLimits, %{})

      [email] = collect_queued_emails(account.id)
      assert email.subject == "You are approaching your seat limit"
      assert email.reply_to == [{"", "support@firezone.dev"}]
      assert email.text_body =~ "Current monthly active users: 19"
      assert email.text_body =~ "Seats in your subscription: 20"
      assert email.text_body =~ "Seats remaining: 1"
      assert email.text_body =~ "Settings -> Account"

      assert admin.email in Enum.map(email.bcc, fn
               {_name, address} -> address
               address -> address
             end)

      account = fetch_account!(account.id)
      assert account.seats_warning_level == :approaching
      assert account.seats_warning_last_sent_at
    end

    test "sends the at limit email when every seat is used", %{account: account} do
      make_seats_active(account, 10)

      assert :ok = perform_job(CheckAccountLimits, %{})

      [email] = collect_queued_emails(account.id)
      assert email.subject == "You have reached your seat limit"
      assert email.text_body =~ "Seats remaining: 0"
      assert email.text_body =~ "New users cannot sign in or connect"
      assert fetch_account!(account.id).seats_warning_level == :at_limit
    end

    test "does not repeat the same level within a week", %{account: account} do
      make_seats_active(account, 10)

      update_account(account, %{
        seats_warning_level: :at_limit,
        seats_warning_last_sent_at: DateTime.add(DateTime.utc_now(), -6, :day)
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert collect_queued_emails(account.id) == []
    end

    test "repeats the same level after a week", %{account: account} do
      make_seats_active(account, 10)

      update_account(account, %{
        seats_warning_level: :at_limit,
        seats_warning_last_sent_at: DateTime.add(DateTime.utc_now(), -8, :day)
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert [_email] = collect_queued_emails(account.id)
    end

    test "sends the at limit email right away after an approaching email", %{account: account} do
      make_seats_active(account, 10)

      update_account(account, %{
        seats_warning_level: :approaching,
        seats_warning_last_sent_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      [email] = collect_queued_emails(account.id)
      assert email.subject == "You have reached your seat limit"
      assert fetch_account!(account.id).seats_warning_level == :at_limit
    end

    test "does not downgrade to approaching within a week", %{account: account} do
      account = update_account(account, %{limits: %{monthly_active_users_count: 20}})
      make_seats_active(account, 19)

      update_account(account, %{
        seats_warning_level: :at_limit,
        seats_warning_last_sent_at: DateTime.add(DateTime.utc_now(), -1, :day)
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert collect_queued_emails(account.id) == []
      assert fetch_account!(account.id).seats_warning_level == :at_limit
    end

    test "clears the warning state once plenty of seats are free", %{account: account} do
      make_seats_active(account, 5)

      update_account(account, %{
        seats_warning_level: :at_limit,
        seats_warning_last_sent_at: DateTime.utc_now()
      })

      assert :ok = perform_job(CheckAccountLimits, %{})

      account = fetch_account!(account.id)
      assert account.seats_warning_level == nil
      assert account.seats_warning_last_sent_at == nil
    end

    test "does not send when seat warnings are turned off in notification settings", %{
      account: account
    } do
      update_account(account, %{
        config: %{notifications: %{seats_warning: %{enabled: false}}}
      })

      make_seats_active(account, 10)

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert collect_queued_emails(account.id) == []
      assert fetch_account!(account.id).seats_warning_level == nil
    end

    test "sends again once seat warnings are turned back on", %{account: account} do
      update_account(account, %{
        config: %{notifications: %{seats_warning: %{enabled: false}}}
      })

      make_seats_active(account, 10)
      assert :ok = perform_job(CheckAccountLimits, %{})
      assert collect_queued_emails(account.id) == []

      update_account(account, %{
        config: %{notifications: %{seats_warning: %{enabled: true}}}
      })

      assert :ok = perform_job(CheckAccountLimits, %{})
      assert [_email] = collect_queued_emails(account.id)
    end

    test "does not send when enough seats remain", %{account: account} do
      make_seats_active(account, 5)

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert collect_queued_emails(account.id) == []
    end

    test "does not send for non-Business accounts" do
      account = provisioned_account_fixture(%{metadata: %{stripe: %{product_name: "Team"}}})
      admin_actor_fixture(account: account)
      account = update_account(account, %{limits: %{monthly_active_users_count: 10}})
      make_seats_active(account, 10)

      assert :ok = perform_job(CheckAccountLimits, %{})

      assert collect_queued_emails(account.id) == []
    end
  end
end
