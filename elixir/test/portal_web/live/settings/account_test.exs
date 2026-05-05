defmodule PortalWeb.Settings.AccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.SubjectFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/account"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "billing plan UI" do
    test "shows upgrade button for non-enterprise provisioned account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test", product_name: "Team"}}
        })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Upgrade plan"
      refute html =~ "Contact your account manager for plan changes."
    end

    test "shows contact message instead of upgrade button for enterprise provisioned account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      account =
        update_account(account, %{
          metadata: %{stripe: %{customer_id: "cus_test", product_name: "Enterprise"}}
        })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      refute html =~ "Upgrade plan"
      assert html =~ "Contact your account manager for plan changes."
    end

    test "shows neither upgrade button nor contact message for unprovisioned account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      refute html =~ "Upgrade plan"
      refute html =~ "Contact your account manager for plan changes."
    end
  end

  describe "index (default action)" do
    test "renders account settings page with account slug", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ account.slug
    end

    test "renders plan features section", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Plan Features"
    end

    test "renders usage section", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ "Usage"
    end
  end

  describe "edit account name" do
    test "renders account name on the settings page", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      assert html =~ account.name
    end

    test "can open the edit account panel", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      html = render_click(lv, "open_edit_account")
      assert html =~ "Edit Account"
    end

    test "validates name length", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      render_click(lv, "open_edit_account")

      html =
        lv
        |> form("form[phx-submit='submit_account_name']", %{account: %{name: "ab"}})
        |> render_change()

      assert html =~ "should be at least 3 character(s)"
    end

    test "saves updated account name", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      render_click(lv, "open_edit_account")

      new_name = "Updated Account Name"

      lv
      |> form("form[phx-submit='submit_account_name']", %{account: %{name: new_name}})
      |> render_submit()

      html = render(lv)
      assert html =~ new_name
      # Panel slides back off-screen after save (translate-x-full = hidden)
      assert html =~ "translate-x-full"
    end
  end

  describe "delete account" do
    test "shows confirm delete dialog on click", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      html = render_click(lv, "confirm_delete_account")
      assert html =~ "Delete this account?"
      assert html =~ account.slug
    end

    test "can cancel delete confirmation", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      render_click(lv, "confirm_delete_account")
      html = render_click(lv, "cancel_delete_account")

      refute html =~ "Delete this account?"
      assert html =~ "Delete account"
    end

    test "schedules account for deletion when slug matches", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      admin_2 = admin_actor_fixture(account: account)
      _disabled_admin = disabled_actor_fixture(account: account, type: :account_admin_user)
      _account_user = actor_fixture(account: account, type: :account_user)
      _other_admin = admin_actor_fixture()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      render_click(lv, "confirm_delete_account")
      render_click(lv, "update_slug_confirmation", %{"slug_confirmation" => account.slug})

      html =
        lv
        |> form("form[phx-submit='delete_account']", %{slug_confirmation: account.slug})
        |> render_submit()

      account = fetch_account!(account.id)

      assert html =~ "Cancel deletion"
      assert account.disabled_at
      assert account.scheduled_deletion_at

      queued_emails = collect_queued_emails(account.id)
      assert length(queued_emails) == 1

      [email] = queued_emails

      recipients =
        email.bcc
        |> Enum.map(fn {_name, address} -> address end)

      assert actor.email in recipients
      assert admin_2.email in recipients
      assert length(recipients) == 2
      assert email.subject == "Firezone Account Scheduled for Deletion"
      assert email.text_body =~ Calendar.strftime(account.scheduled_deletion_at, "%B %-d, %Y")
    end

    test "sends aborted deletion email when cancellation restores the account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      scheduled_deletion_at = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      account =
        update_account(account,
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: scheduled_deletion_at
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/account")

      html = render_click(lv, "cancel_account_deletion")

      account = fetch_account!(account.id)

      refute account.disabled_at
      refute account.scheduled_deletion_at
      refute html =~ "scheduled for deletion"

      queued_emails = collect_queued_emails(account.id)
      assert length(queued_emails) == 1

      [email] = queued_emails
      assert email.subject == "Firezone Account Deletion Aborted"
      assert email.text_body =~ "has been canceled"
      assert email.text_body =~ account.slug
    end

    test "scheduling is idempotent and only queues one email", %{account: account, actor: actor} do
      subject = subject_fixture(account: account, actor: actor)
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      attrs = %{
        disabled_at: disabled_at,
        scheduled_deletion_at: scheduled_deletion_at
      }

      assert {:ok, first_account} =
               PortalWeb.Settings.Account.schedule_account_deletion(
                 account,
                 attrs,
                 subject
               )

      assert {:ok, second_account} =
               PortalWeb.Settings.Account.schedule_account_deletion(
                 account,
                 %{
                   disabled_at: DateTime.add(disabled_at, 1, :day),
                   scheduled_deletion_at: DateTime.add(scheduled_deletion_at, 1, :day)
                 },
                 subject
               )

      assert DateTime.compare(first_account.scheduled_deletion_at, scheduled_deletion_at) == :eq
      assert DateTime.compare(second_account.scheduled_deletion_at, scheduled_deletion_at) == :eq
      assert length(collect_queued_emails(account.id)) == 1
    end

    test "cancellation is idempotent and only queues one email", %{account: account, actor: actor} do
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account,
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      subject = subject_fixture(account: account, actor: actor)

      assert {:ok, first_account} =
               PortalWeb.Settings.Account.cancel_account_deletion(account, subject)

      assert {:ok, second_account} =
               PortalWeb.Settings.Account.cancel_account_deletion(account, subject)

      refute first_account.scheduled_deletion_at
      refute second_account.scheduled_deletion_at
      assert length(collect_queued_emails(account.id)) == 1
    end
  end
end
