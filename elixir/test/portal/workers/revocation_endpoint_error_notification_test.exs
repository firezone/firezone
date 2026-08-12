defmodule Portal.Workers.RevocationEndpointErrorNotificationTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.SessionLogFixtures

  alias Portal.Revocation.Failure
  alias Portal.RevocationEndpoint
  alias Portal.Workers.RevocationEndpointErrorNotification

  defmodule FailingRevocationEmail do
    def revocation_endpoint_error_email(_endpoint, _recipients), do: :failing_email
  end

  defmodule FailingMailer do
    def enqueue(:failing_email), do: {:error, :injected_failure}
  end

  # A DER-encoded name, since that is what the column holds and what the email
  # renders back to something readable.
  @issuer :public_key.der_encode(
            :Name,
            {:rdnSequence,
             [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "Acme Device CA"}}]]}
          )

  defp errored_endpoint_fixture(account, attrs \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      Enum.into(attrs, %{
        account_id: account.id,
        issuer: @issuer,
        distribution_point: "http://crl.acme.test/devices.crl",
        crl_urls: ["http://crl.acme.test/devices.crl"],
        ocsp_urls: [],
        crl_error: "connection refused",
        errored_at: now,
        is_disabled: true,
        disabled_reason: Failure.disabled_reason(),
        error_email_count: 0,
        inserted_at: now,
        updated_at: now
      })

    Repo.insert_all(RevocationEndpoint, [attrs])
    reload_endpoint(account)
  end

  defp reload_endpoint(account) do
    Repo.get_by!(RevocationEndpoint,
      account_id: account.id,
      issuer: @issuer,
      distribution_point: "http://crl.acme.test/devices.crl"
    )
  end

  describe "perform/1" do
    test "tells admins that revocation is no longer checked" do
      account = account_fixture()
      session_log_fixture(account: account)
      admin = admin_actor_fixture(account: account)
      errored_endpoint_fixture(account)

      assert :ok = perform_job(RevocationEndpointErrorNotification, %{})

      endpoint = reload_endpoint(account)
      assert endpoint.error_email_count == 1
      assert endpoint.last_error_email_at

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Certificate revocation checks have stopped - CN=Acme Device CA"
      assert {"", admin.email} in email.bcc
      assert email.text_body =~ "connection refused"
      assert email.text_body =~ "Acme Device CA"
      assert email.text_body =~ "http://crl.acme.test/devices.crl"
      assert email.text_body =~ "are let on even"
      assert email.text_body =~ "settings/trust_anchors"
      assert email.html_body =~ "connection refused"
      assert email.html_body =~ "Edit and Save"
    end

    test "leaves an endpoint that is only failing, not yet disabled, alone" do
      account = account_fixture()
      session_log_fixture(account: account)
      admin_actor_fixture(account: account)
      errored_endpoint_fixture(account, %{is_disabled: false, disabled_reason: nil})

      assert :ok = perform_job(RevocationEndpointErrorNotification, %{})

      assert reload_endpoint(account).error_email_count == 0
      assert collect_queued_emails(account.id) == []
    end

    test "waits out the interval before emailing again" do
      account = account_fixture()
      session_log_fixture(account: account)
      admin_actor_fixture(account: account)

      errored_endpoint_fixture(account, %{
        error_email_count: 1,
        last_error_email_at: DateTime.add(DateTime.utc_now(), -2, :hour)
      })

      assert :ok = perform_job(RevocationEndpointErrorNotification, %{})

      assert reload_endpoint(account).error_email_count == 1
      assert collect_queued_emails(account.id) == []
    end

    test "emails again once the interval has passed" do
      account = account_fixture()
      session_log_fixture(account: account)
      admin_actor_fixture(account: account)

      errored_endpoint_fixture(account, %{
        error_email_count: 1,
        last_error_email_at: DateTime.add(DateTime.utc_now(), -21, :hour)
      })

      assert :ok = perform_job(RevocationEndpointErrorNotification, %{})

      assert reload_endpoint(account).error_email_count == 2
      assert [_email] = collect_queued_emails(account.id)
    end

    test "stops after ten emails" do
      account = account_fixture()
      session_log_fixture(account: account)
      admin_actor_fixture(account: account)

      errored_endpoint_fixture(account, %{
        error_email_count: 10,
        last_error_email_at: DateTime.add(DateTime.utc_now(), -200, :hour)
      })

      assert :ok = perform_job(RevocationEndpointErrorNotification, %{})

      assert reload_endpoint(account).error_email_count == 10
      assert collect_queued_emails(account.id) == []
    end

    test "skips a dormant account without spending one of its emails" do
      account = account_fixture()
      admin_actor_fixture(account: account)
      errored_endpoint_fixture(account)

      assert :ok = perform_job(RevocationEndpointErrorNotification, %{})

      assert reload_endpoint(account).error_email_count == 0
      assert collect_queued_emails(account.id) == []
    end

    test "an account with no admins is logged rather than retried forever" do
      account = account_fixture()
      session_log_fixture(account: account)
      errored_endpoint_fixture(account)

      log =
        capture_log(fn ->
          assert :ok = perform_job(RevocationEndpointErrorNotification, %{})
        end)

      assert log =~ "No admin actors found for account"
      assert reload_endpoint(account).error_email_count == 0
    end

    test "a send that fails still counts, so the admins are not emailed twice" do
      account = account_fixture()
      session_log_fixture(account: account)
      admin_actor_fixture(account: account)
      errored_endpoint_fixture(account)

      Portal.Config.put_env_override(RevocationEndpointErrorNotification,
        mailer_module: FailingMailer,
        revocation_email_module: FailingRevocationEmail
      )

      log =
        capture_log(fn ->
          assert :ok = perform_job(RevocationEndpointErrorNotification, %{})
        end)

      assert log =~ "Failed to enqueue certificate revocation error email"
      assert reload_endpoint(account).error_email_count == 1
    end
  end
end
