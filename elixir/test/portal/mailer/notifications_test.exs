defmodule Portal.Mailer.NotificationsTest do
  use Portal.DataCase, async: true
  import Portal.Mailer.Notifications
  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  alias Portal.Authentication.Context
  alias Portal.ComponentVersions

  setup do
    account = account_fixture()
    %{account: account}
  end

  describe "account_scheduled_for_deletion_email/3" do
    test "includes the scheduled deletion date, settings link, and request context", %{
      account: account
    } do
      scheduled_deletion_at =
        DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      account = update_account(account, scheduled_deletion_at: scheduled_deletion_at)
      formatted_date = Calendar.strftime(scheduled_deletion_at, "%B %-d, %Y")

      context = %Context{
        type: :portal,
        remote_ip: {93, 184, 216, 34},
        remote_ip_location_region: "California",
        remote_ip_location_city: "Los Angeles",
        remote_ip_location_lat: 34.05,
        remote_ip_location_lon: -118.24,
        user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
      }

      email =
        account_scheduled_for_deletion_email(account, "admin@example.com", context)

      assert email.subject == "Firezone Account Scheduled for Deletion"
      assert email.text_body =~ account.slug
      assert email.text_body =~ account.id
      assert email.text_body =~ formatted_date
      assert email.text_body =~ "/#{account.slug}/settings/account"
      assert email.text_body =~ "93.184.*.*"
      assert email.text_body =~ "Los Angeles"
      assert email.text_body =~ "California"
      assert email.text_body =~ context.user_agent
      assert email.html_body =~ "Account Scheduled for Deletion"
      assert email.html_body =~ formatted_date
      assert email.html_body =~ "93.184.*.*"
      assert email.html_body =~ "Los Angeles"
      assert email.html_body =~ context.user_agent
    end
  end

  describe "account_deletion_aborted_email/3" do
    test "includes the cancellation message, settings link, and request context", %{
      account: account
    } do
      context = %Context{
        type: :portal,
        remote_ip: {93, 184, 216, 34},
        remote_ip_location_region: "California",
        remote_ip_location_city: "Los Angeles",
        remote_ip_location_lat: 34.05,
        remote_ip_location_lon: -118.24,
        user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
      }

      email = account_deletion_aborted_email(account, "admin@example.com", context)

      assert email.subject == "Firezone Account Deletion Aborted"
      assert email.text_body =~ "has been canceled"
      assert email.text_body =~ account.slug
      assert email.text_body =~ account.id
      assert email.text_body =~ "/#{account.slug}/settings/account"
      assert email.text_body =~ "93.184.*.*"
      assert email.text_body =~ "Los Angeles"
      assert email.text_body =~ context.user_agent
      assert email.html_body =~ "Account Deletion Aborted"
      assert email.html_body =~ "no longer scheduled for deletion"
      assert email.html_body =~ "93.184.*.*"
      assert email.html_body =~ "Los Angeles"
      assert email.html_body =~ context.user_agent
    end
  end

  describe "account_deletion_completed_email/2" do
    test "includes the completion message", %{account: account} do
      email =
        account_deletion_completed_email(account, "admin@example.com")

      assert email.subject == "Firezone Account Deletion Complete"
      assert email.text_body =~ "has been permanently deleted"
      assert email.text_body =~ account.slug
      assert email.text_body =~ account.id
      assert email.html_body =~ "Account Deletion Complete"
      assert email.html_body =~ "no longer available"
    end
  end

  describe "outdated_gateway_email/4" do
    test "should contain current gateway version and list of outdated gateways", %{
      account: account
    } do
      admin_email = "admin@foo.local"

      gateway_1 = gateway_fixture(account: account)
      gateway_2 = gateway_fixture(account: account)

      current_version = "3.2.1"
      set_current_version(current_version)

      incompatible_client_count = 5

      email_body =
        outdated_gateway_email(
          account,
          [gateway_1, gateway_2],
          incompatible_client_count,
          admin_email
        )

      assert email_body.text_body =~ "The latest Firezone Gateway release is: #{current_version}"
      assert email_body.text_body =~ gateway_1.name
      assert email_body.text_body =~ gateway_2.name

      assert email_body.text_body =~
               "#{incompatible_client_count} recently connected client(s) are not compatible"

      assert email_body.text_body =~ "See all outdated clients"

      assert email_body.html_body =~
               "The latest Firezone Gateway release is: <span style=\"font-weight: 600\">#{current_version}</span>"

      assert email_body.html_body =~ gateway_1.name
      assert email_body.html_body =~ gateway_2.name

      assert email_body.html_body =~
               "/#{account.slug}/clients?clients_order_by=devices%3Aasc%3Alast_seen_version\" target=\"_blank\" rel=\"noopener noreferrer\">#{incompatible_client_count} recently connected client(s)</a> are not compatible"

      assert email_body.html_body =~ "See all outdated clients"
    end
  end

  defp set_current_version(version) do
    config = Portal.Config.get_env(:portal, ComponentVersions)

    new_versions =
      config
      |> Keyword.get(:versions)
      |> Keyword.merge(gateway: version)

    new_config = Keyword.merge(config, versions: new_versions)
    Portal.Config.put_env_override(:portal, ComponentVersions, new_config)
  end
end
