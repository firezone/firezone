defmodule PortalWeb.Settings.BillingTest do
  use PortalWeb.ConnCase, async: false

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  alias Portal.Mocks.Stripe

  setup do
    # Enable billing with test secret key
    Portal.Config.put_env_override(Portal.Billing,
      enabled: true,
      secret_key: "sk_test_123",
      webhook_signing_secret: "whsec_test_123",
      default_price_id: "price_test_123"
    )

    account =
      account_fixture(
        metadata: %{
          stripe: %{
            customer_id: "cus_test123",
            subscription_id: "sub_test123",
            product_name: "Enterprise",
            billing_email: "billing@example.com",
            support_type: "email"
          }
        },
        legal_name: "Test Company Legal Name",
        limits: %{
          monthly_active_users_count: 100,
          service_accounts_count: 50,
          sites_count: 10,
          account_admin_users_count: 5,
          users_count: 200
        }
      )

    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "mount/3" do
    test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
      path = ~p"/#{account}/settings/billing"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end

    test "raises NotFoundError when billing is not provisioned", %{conn: conn} do
      # Create account without Stripe metadata (not provisioned)
      account = account_fixture(metadata: %{stripe: %{}})
      actor = admin_actor_fixture(account: account)

      conn = authorize_conn(conn, actor)

      assert_raise PortalWeb.LiveErrors.NotFoundError, fn ->
        live(conn, ~p"/#{account}/settings/billing")
      end
    end

    test "loads billing data successfully", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert html =~ "Billing Information"
      assert html =~ account.metadata.stripe.product_name
      assert html =~ account.metadata.stripe.billing_email
      assert html =~ account.legal_name
    end

    test "counts account admin users correctly", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create additional admin
      _admin2 = admin_actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()
      assert html =~ "2 used"
      assert html =~ "5 allowed"
      assert html =~ "Admins"
    end

    test "counts service accounts correctly", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create service accounts
      _sa1 = service_account_fixture(account: account)
      _sa2 = service_account_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()
      assert html =~ "Service Accounts"
      assert html =~ "2 used"
      assert html =~ "50 allowed"
    end

    test "counts users correctly", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create additional users
      _user1 = actor_fixture(account: account, type: :account_user)
      _user2 = actor_fixture(account: account, type: :account_user)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()
      # 1 admin + 2 regular users = 3 total
      assert html =~ "Users"
      assert html =~ "3 used"
      assert html =~ "200 allowed"
    end

    test "counts monthly active users correctly", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create a client with recent activity
      _client = client_fixture(account: account, actor: actor, last_seen_at: DateTime.utc_now())

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()
      assert html =~ "Seats"
      assert html =~ "1 used"
      assert html =~ "100 allowed"
    end

    test "counts sites correctly", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create managed sites (not system-managed)
      Portal.SiteFixtures.site_fixture(account: account, managed_by: :account)
      Portal.SiteFixtures.site_fixture(account: account, managed_by: :account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()
      assert html =~ "Sites"
      assert html =~ "2 used"
      assert html =~ "10 allowed"
    end
  end

  describe "render/1" do
    test "renders breadcrumbs", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
      breadcrumbs = String.trim(Floki.text(item))
      assert breadcrumbs =~ "Billing"
    end

    test "renders billing information table", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      rows =
        lv
        |> element("#billing")
        |> render()
        |> vertical_table_to_map()

      assert rows["current plan"] =~ "Enterprise"
      assert rows["billing email"] =~ "billing@example.com"
      assert rows["billing name"] =~ "Test Company Legal Name"
    end

    test "renders limits section with all limits", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()

      # Check all limit types are displayed
      assert html =~ "Users"
      assert html =~ "Seats"
      assert html =~ "Service Accounts"
      assert html =~ "Admins"
      assert html =~ "Sites"
    end

    test "does not render limits section when no limits are set", %{
      conn: conn
    } do
      # Create account with all limits set to nil
      account =
        account_fixture(
          metadata: %{
            stripe: %{
              customer_id: "cus_unlimited",
              subscription_id: "sub_unlimited",
              product_name: "Enterprise Unlimited",
              billing_email: "unlimited@example.com",
              support_type: "email_and_slack"
            }
          },
          limits: %{
            users_count: nil,
            monthly_active_users_count: nil,
            service_accounts_count: nil,
            sites_count: nil,
            account_admin_users_count: nil,
            api_clients_count: nil,
            api_tokens_per_client_count: nil
          }
        )

      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      refute html =~ "billing-limits"
      refute html =~ "Upgrade your plan to increase the limits below"
    end

    test "highlights exceeded limits in red", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create more admins than the limit allows
      _admin2 = admin_actor_fixture(account: account)
      _admin3 = admin_actor_fixture(account: account)
      _admin4 = admin_actor_fixture(account: account)
      _admin5 = admin_actor_fixture(account: account)
      _admin6 = admin_actor_fixture(account: account)
      # Now we have 6 admins but limit is 5

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html = element(lv, "#billing-limits") |> render()
      assert html =~ "text-red-500"
      assert html =~ "6 used"
    end

    test "renders support section with email support type", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert html =~ "Support"
      assert html =~ "Please send"
      assert html =~ "an email"
      assert html =~ "mailto:"
    end

    test "renders support section with email_and_slack support type", %{
      conn: conn
    } do
      account =
        account_fixture(
          metadata: %{
            stripe: %{
              customer_id: "cus_slack",
              subscription_id: "sub_slack",
              product_name: "Enterprise",
              billing_email: "slack@example.com",
              support_type: "email_and_slack"
            }
          }
        )

      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert html =~ "Slack channel"
      assert html =~ "an email"
    end

    test "renders support section with community support for other types", %{
      conn: conn
    } do
      account =
        account_fixture(
          metadata: %{
            stripe: %{
              customer_id: "cus_community",
              subscription_id: "sub_community",
              product_name: "Starter",
              billing_email: "community@example.com",
              support_type: "community"
            }
          }
        )

      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert html =~ "Discourse"
      assert html =~ "Discord"
      assert html =~ "Priority email and dedicated Slack support"
    end

    test "renders danger zone section", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert html =~ "Danger zone"
      assert html =~ "Terminate account"
      assert html =~ "contact support"
    end

    test "renders Contact sales link", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert has_element?(lv, "a[href*='mailto:']")
      assert html =~ "Contact sales"
    end

    test "renders Manage button", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert has_element?(lv, "button[phx-click='redirect_to_billing_portal']")
    end
  end

  describe "handle_event redirect_to_billing_portal" do
    test "redirects to Stripe billing portal on success", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Mock Stripe
      bypass = Bypass.open()
      Stripe.mock_create_billing_session_endpoint(bypass, account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      assert {:error, {:redirect, %{to: to}}} =
               element(lv, "button[phx-click='redirect_to_billing_portal']")
               |> render_click()

      assert to =~ "https://billing.stripe.com/p/session"
    end

    test "shows error message when billing portal is unavailable", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Mock Stripe to return error by not setting up any endpoints
      bypass = Bypass.open()
      Bypass.down(bypass)
      Stripe.override_endpoint_url("http://localhost:#{bypass.port}")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      html =
        element(lv, "button[phx-click='redirect_to_billing_portal']")
        |> render_click()

      assert html =~ "Billing portal is temporarily unavailable, please try again later."
    end

    test "logs error when billing portal fails", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      import ExUnit.CaptureLog

      # Mock Stripe to return error
      bypass = Bypass.open()
      Bypass.down(bypass)
      Stripe.override_endpoint_url("http://localhost:#{bypass.port}")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/billing")

      log =
        capture_log(fn ->
          element(lv, "button[phx-click='redirect_to_billing_portal']")
          |> render_click()
        end)

      assert log =~ "Failed to get billing portal URL"
    end
  end

  describe "DB.count_account_admin_users_for_account/1" do
    alias PortalWeb.Settings.Billing.DB

    test "counts only account admin users", %{account: account} do
      # Create various actor types
      _admin1 = admin_actor_fixture(account: account)
      _admin2 = admin_actor_fixture(account: account)
      _user = actor_fixture(account: account, type: :account_user)
      _service = service_account_fixture(account: account)

      count = DB.count_account_admin_users_for_account(account)
      # 2 created here + 1 from setup = 3
      assert count == 3
    end

    test "excludes disabled admins", %{account: account} do
      _active_admin = admin_actor_fixture(account: account)

      _disabled_admin = disabled_actor_fixture(account: account, type: :account_admin_user)

      count = DB.count_account_admin_users_for_account(account)
      # Only the active admin + 1 from setup
      assert count == 2
    end
  end

  describe "DB.count_service_accounts_for_account/1" do
    alias PortalWeb.Settings.Billing.DB

    test "counts only service accounts", %{account: account} do
      _sa1 = service_account_fixture(account: account)
      _sa2 = service_account_fixture(account: account)
      _user = actor_fixture(account: account, type: :account_user)

      count = DB.count_service_accounts_for_account(account)
      assert count == 2
    end

    test "excludes disabled service accounts", %{account: account} do
      _active_sa = service_account_fixture(account: account)

      _disabled_sa = disabled_actor_fixture(account: account, type: :service_account)

      count = DB.count_service_accounts_for_account(account)
      assert count == 1
    end
  end

  describe "DB.count_users_for_account/1" do
    alias PortalWeb.Settings.Billing.DB

    test "counts both account_admin_user and account_user types", %{account: account} do
      _admin = admin_actor_fixture(account: account)
      _user1 = actor_fixture(account: account, type: :account_user)
      _user2 = actor_fixture(account: account, type: :account_user)
      _service = service_account_fixture(account: account)

      count = DB.count_users_for_account(account)
      # 3 created here + 1 admin from setup = 4
      assert count == 4
    end

    test "excludes disabled users", %{account: account} do
      _active_user = actor_fixture(account: account, type: :account_user)

      _disabled_user = disabled_actor_fixture(account: account, type: :account_user)

      count = DB.count_users_for_account(account)
      # 1 active user + 1 admin from setup = 2
      assert count == 2
    end
  end

  describe "DB.count_1m_active_users_for_account/1" do
    alias PortalWeb.Settings.Billing.DB

    test "counts users with recent client activity", %{account: account, actor: actor} do
      # Create a client with recent activity
      _client = client_fixture(account: account, actor: actor, last_seen_at: DateTime.utc_now())

      count = DB.count_1m_active_users_for_account(account)
      assert count == 1
    end

    test "excludes users with old client activity", %{account: account, actor: actor} do
      # Create a client with old activity (more than 1 month ago)
      two_months_ago = DateTime.utc_now() |> DateTime.add(-60, :day)
      _old_client = client_fixture(account: account, actor: actor, last_seen_at: two_months_ago)

      count = DB.count_1m_active_users_for_account(account)
      assert count == 0
    end

    test "counts each actor only once even with multiple clients", %{account: account, actor: actor} do
      # Create multiple clients for the same actor
      _client1 = client_fixture(account: account, actor: actor, last_seen_at: DateTime.utc_now())
      _client2 = client_fixture(account: account, actor: actor, last_seen_at: DateTime.utc_now())

      count = DB.count_1m_active_users_for_account(account)
      assert count == 1
    end

    test "excludes disabled actors", %{account: account} do
      disabled_actor = disabled_actor_fixture(account: account, type: :account_user)

      _client = client_fixture(account: account, actor: disabled_actor, last_seen_at: DateTime.utc_now())

      count = DB.count_1m_active_users_for_account(account)
      assert count == 0
    end
  end

  describe "DB.count_groups_for_account/1" do
    alias PortalWeb.Settings.Billing.DB

    test "counts only account-managed sites", %{account: account} do
      # Create account-managed sites
      Portal.SiteFixtures.site_fixture(account: account, managed_by: :account)
      Portal.SiteFixtures.site_fixture(account: account, managed_by: :account)

      # Create system-managed site (should not be counted)
      Portal.SiteFixtures.site_fixture(account: account, managed_by: :system)

      count = DB.count_groups_for_account(account)
      assert count == 2
    end
  end
end
