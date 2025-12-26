defmodule Portal.Mailer.AuthEmailTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.Mailer.AuthEmail

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
      assert email.text_body =~ "secret=abc123"
      assert email.text_body =~ "redirect_to=%2Fdashboard"

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
      assert email.text_body =~ "/sign_in/email_otp/#{provider.id}/verify?secret=xyz789"
    end

    test "omits sign-in link for client sign-in" do
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
          {127, 0, 0, 1},
          %{"as" => "client"}
        )

      # Client sign-in should NOT include the clickable link (only the code)
      # The text template has a conditional that omits the URL for client sign-in
      assert email.text_body =~ "xyz789"
      refute email.text_body =~ "/verify?secret="
    end
  end
end
