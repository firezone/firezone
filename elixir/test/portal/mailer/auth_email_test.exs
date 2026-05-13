defmodule Portal.Mailer.AuthEmailTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.Mailer.AuthEmail

  describe "sign_up_link_email/4" do
    test "includes client download and quickstart links" do
      account = account_fixture()

      actor =
        actor_fixture(
          account: account,
          type: :account_admin_user,
          email: "test@example.com"
        )
        |> Portal.Repo.preload(:account)

      email =
        sign_up_link_email(
          account,
          actor,
          "Mozilla/5.0",
          {127, 0, 0, 1}
        )

      # Check HTML body contains the new links
      assert email.html_body =~ "http://localhost:13100/#{account.slug}"
      refute email.html_body =~ "http://localhost:13100/#{account.id}"
      assert email.html_body =~ "Next Steps:"
      assert email.html_body =~ "Download the Firezone Client"
      assert email.html_body =~ "https://www.firezone.dev/kb/client-apps"
      assert email.html_body =~ "View the Quickstart Guide"
      assert email.html_body =~ "https://www.firezone.dev/kb/quickstart"

      # Check text body contains the new links
      assert email.text_body =~ "http://localhost:13100/#{account.slug}"
      refute email.text_body =~ "http://localhost:13100/#{account.id}"
      assert email.text_body =~ "Next Steps:"
      assert email.text_body =~ "Download the Firezone Client for your platform:"
      assert email.text_body =~ "https://www.firezone.dev/kb/client-apps"
      assert email.text_body =~ "View the Quickstart Guide to get started:"
      assert email.text_body =~ "https://www.firezone.dev/kb/quickstart"
      assert email.text_body =~ "IP address: 127.0.x.x"
      refute email.text_body =~ "127.0.0.1"
    end
  end

  describe "sign_in_link_email/7" do
    test "generates sign-in URL with properly encoded query params" do
      account = account_fixture()
      provider = email_otp_provider_fixture(account: account)

      actor =
        actor_fixture(
          account: account,
          type: :account_admin_user,
          allow_email_otp_sign_in: true
        )
        |> Portal.Repo.preload(:account)

      # Portal sign-in (no "as" => "client") includes the link
      email =
        sign_in_link_email(
          actor,
          DateTime.utc_now(),
          provider.id,
          "abc123",
          "Mozilla/5.0",
          {127, 0, 0, 1},
          %{"redirect_to" => "/dashboard"}
        )

      # The URL should have properly encoded query params
      # NOT double-encoded (e.g., secret%3Dabc123 would be wrong)
      assert email.text_body =~ "/#{account.slug}/sign_in/email_otp/#{provider.id}/verify"
      refute email.text_body =~ "/#{account.id}/sign_in/email_otp/#{provider.id}/verify"
      assert email.text_body =~ "secret=abc123"
      assert email.text_body =~ "redirect_to=%2Fdashboard"
      assert email.text_body =~ "IP address: 127.0.x.x"
      refute email.text_body =~ "127.0.0.1"

      # Ensure the URL is not double-encoded
      refute email.text_body =~ "secret%3D"
      refute email.text_body =~ "redirect_to%3D"
    end

    test "includes sign-in link for portal sign-in (not client)" do
      account = account_fixture()
      provider = email_otp_provider_fixture(account: account)

      actor =
        actor_fixture(
          account: account,
          type: :account_admin_user,
          allow_email_otp_sign_in: true
        )
        |> Portal.Repo.preload(:account)

      email =
        sign_in_link_email(
          actor,
          DateTime.utc_now(),
          provider.id,
          "xyz789",
          "Mozilla/5.0",
          {127, 0, 0, 1}
        )

      # Portal sign-in should include the clickable link
      assert email.text_body =~
               "/#{account.slug}/sign_in/email_otp/#{provider.id}/verify?secret=xyz789"
    end

    test "omits sign-in link for client sign-in contexts" do
      account = account_fixture()
      provider = email_otp_provider_fixture(account: account)

      actor =
        actor_fixture(
          account: account,
          type: :account_admin_user,
          allow_email_otp_sign_in: true
        )
        |> Portal.Repo.preload(:account)

      for client_context <- ["client", "gui-client", "headless-client"] do
        email =
          sign_in_link_email(
            actor,
            DateTime.utc_now(),
            provider.id,
            "xyz789",
            "Mozilla/5.0",
            {127, 0, 0, 1},
            %{"as" => client_context}
          )

        # Client sign-in should NOT include the clickable link (only the code)
        assert email.text_body =~ "xyz789"
        refute email.text_body =~ "/verify?secret="
      end
    end

    test "obfuscates IPv6 request addresses" do
      account = account_fixture()
      provider = email_otp_provider_fixture(account: account)

      actor =
        actor_fixture(
          account: account,
          type: :account_admin_user,
          allow_email_otp_sign_in: true
        )
        |> Portal.Repo.preload(:account)

      email =
        sign_in_link_email(
          actor,
          DateTime.utc_now(),
          provider.id,
          "xyz789",
          "Mozilla/5.0",
          {0x2001, 0x0DB8, 0x85A3, 0, 0, 0, 0, 1}
        )

      assert email.text_body =~ "IP address: 2001:db8:85a3:0:xxxx:xxxx:xxxx:xxxx"
      refute email.text_body =~ "2001:db8:85a3:0:0:0:0:1"
      refute email.text_body =~ "2001:db8:85a3::1"
    end
  end

  describe "oidc_identity_verification_email/7" do
    test "uses email verification copy and links back to the pending verification form" do
      account = account_fixture()
      provider = oidc_provider_fixture(account: account)
      pending_identity_id = Ecto.UUID.generate()

      actor =
        actor_fixture(
          account: account,
          type: :account_admin_user,
          email: "admin@example.com"
        )
        |> Portal.Repo.preload(:account)

      context = %Portal.Authentication.Context{
        type: :portal,
        remote_ip: {127, 0, 0, 1},
        remote_ip_location_region: "US-CA",
        remote_ip_location_city: "San Francisco",
        remote_ip_location_lat: 37.7749,
        remote_ip_location_lon: -122.4194,
        user_agent: "Mozilla/5.0"
      }

      email =
        oidc_identity_verification_email(
          actor,
          DateTime.utc_now(),
          provider.id,
          pending_identity_id,
          "abc12",
          context,
          %{"redirect_to" => "/dashboard"}
        )

      assert email.subject == "Firezone email verification code"
      assert email.text_body =~ "Verify Your Email Address"
      assert email.text_body =~ "email verification form"
      assert email.text_body =~ "/#{account.slug}/sign_in/oidc/#{provider.id}/verify_identity"
      refute email.text_body =~ "/#{account.id}/sign_in/oidc/#{provider.id}/verify_identity"
      assert email.text_body =~ "pending_identity_id=#{pending_identity_id}"
      assert email.text_body =~ "redirect_to=%2Fdashboard"
      assert email.text_body =~ "Location: San Francisco, US-CA"
      assert email.text_body =~ "IP address: 127.0.x.x"
      refute email.text_body =~ "127.0.0.1"
      refute email.text_body =~ "Coordinates"
      assert email.text_body =~ "abc12"
      refute email.text_body =~ "Finish Signing In"
      refute email.text_body =~ "/verify?secret="
      refute email.text_body =~ "secret=abc12"
    end
  end
end
