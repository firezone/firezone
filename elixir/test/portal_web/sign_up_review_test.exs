defmodule PortalWeb.SignUpReviewTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe
  alias Portal.Workers.SignUpReviewRequest
  alias PortalWeb.SignUpReview

  doctest PortalWeb.SignUpReview

  # The review page is tested in the private ops dashboard (firezone/portal-ops).

  @sign_up_token_salt "sign_up_email_v1"
  @approvers ["alice@firezone.dev", "bob@firezone.dev"]

  setup do
    Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: @approvers)

    Portal.Repo.insert!(%Portal.KnownMxDomain{domain: "known-mail.test", verdict: :allow})
    Portal.Repo.insert!(%Portal.KnownMxDomain{domain: "disposable.test", verdict: :deny})
    :ok
  end

  describe "verify" do
    test "creates the account at once when every MX host is allowed", %{conn: conn} do
      stub_mx(["mx1.known-mail.test", "MX2.Known-Mail.Test."])
      email = unique_email()
      stub_stripe(email)

      conn = verify(conn, email)

      assert redirected_to(conn) =~ "/sites"
      assert Portal.Repo.get_by(Portal.Account, name: "Review Corp")
      assert [] == all_enqueued(worker: SignUpReviewRequest)
    end

    test "creates the account at once when review is off", %{conn: conn} do
      Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: [])
      stub_mx(["mx.disposable.test"])
      email = unique_email()
      stub_stripe(email)

      conn = verify(conn, email)

      assert redirected_to(conn) =~ "/sites"
      assert Portal.Repo.get_by(Portal.Account, name: "Review Corp")
    end

    test "blocks the sign-up when any MX host is denied", %{conn: conn} do
      stub_mx(["mx.known-mail.test", "mx.unknown.test", "mx.disposable.test"])

      conn = verify(conn, unique_email())

      assert_blocked(conn)
      refute Portal.Repo.get_by(Portal.Account, name: "Review Corp")
      assert [] == all_enqueued(worker: SignUpReviewRequest)
    end

    test "a denied domain wins over an allowed subdomain", %{conn: conn} do
      Portal.Repo.insert!(%Portal.KnownMxDomain{domain: "mail.disposable.test", verdict: :allow})
      stub_mx(["mx.mail.disposable.test"])

      assert_blocked(verify(conn, unique_email()))
    end

    test "holds the sign-up with the breakdown when allowed and unknown hosts mix", %{conn: conn} do
      stub_mx(["mx.known-mail.test", "mx.unknown.test"])
      email = unique_email()

      conn = verify(conn, email)

      assert redirected_to(conn) == ~p"/sign_up/pending"
      refute Portal.Repo.get_by(Portal.Account, name: "Review Corp")

      jobs = all_enqueued(worker: SignUpReviewRequest)
      assert jobs |> Enum.map(& &1.args["approver"]) |> Enum.sort() == @approvers
      assert Enum.all?(jobs, &(&1.args["email"] == email))
      refute Enum.any?(jobs, &(&1.args["review"] =~ email))

      assert {:ok, %{mail_servers: [{"mx.known-mail.test", :allow}, {"mx.unknown.test", :unknown}]}} =
               SignUpReview.decrypt_review(hd(jobs).args["review"])
    end

    test "does not match a host that only ends with the same characters", %{conn: conn} do
      stub_mx(["mx.notknown-mail.test", "mx.notdisposable.test"])
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "holds the sign-up when the domain does not exist", %{conn: conn} do
      stub_resolve(fn _domain -> {:error, :nxdomain} end)
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "creates the account when a domain without MX records is itself allowed", %{conn: conn} do
      stub_mx([])
      email = "owner-#{System.unique_integer([:positive])}@mail.known-mail.test"
      stub_stripe(email)

      assert redirected_to(verify(conn, email)) =~ "/sites"
    end

    test "blocks a domain without MX records that is itself denied", %{conn: conn} do
      stub_mx([])
      email = "owner-#{System.unique_integer([:positive])}@disposable.test"

      assert_blocked(verify(conn, email))
    end

    test "holds a domain without MX records as its own mail server", %{conn: conn} do
      email = hold_sign_up(conn, [])
      assert email =~ "@review.test"

      assert %{args: %{"review" => review}} = job_for("alice@firezone.dev")
      assert {:ok, %{mail_servers: [{"review.test", :unknown}]}} = SignUpReview.decrypt_review(review)
    end

    test "holds an email without a domain", %{conn: conn} do
      stub_resolve(fn _domain -> flunk("no lookup expected") end)
      assert redirected_to(verify(conn, "no-at-sign")) == ~p"/sign_up/pending"
    end

    test "holds the sign-up when the domain has a null MX", %{conn: conn} do
      stub_mx(["."])
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "holds the sign-up when the MX lookup times out", %{conn: conn} do
      stub_resolve(fn _domain -> {:error, :timeout} end)
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "looks up the absolute domain name in lowercase ASCII", %{conn: conn} do
      test_pid = self()

      stub_resolve(fn domain ->
        send(test_pid, {:resolved, to_string(domain)})
        {:error, :nxdomain}
      end)

      verify(conn, "user@Bücher.Test")

      assert_received {:resolved, "xn--bcher-kva.test."}
    end

    test "asks only once per email for repeated verifications", %{conn: conn} do
      stub_mx(["mx.unknown.test"])
      email = unique_email()

      verify(conn, email)
      verify(build_conn(), email)

      assert length(all_enqueued(worker: SignUpReviewRequest)) == 2
    end

    test "sends an existing owner to sign in without a check", %{conn: conn} do
      stub_mx(["mx.disposable.test"])
      email = unique_email()
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})

      conn = verify(conn, email)

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      assert [] == all_enqueued(worker: SignUpReviewRequest)
    end

    test "shows the pending page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/pending")
      assert html =~ "Thanks for signing up"
      assert html =~ "up to 24 hours"
    end
  end

  describe "SignUpReviewRequest" do
    test "emails each approver a personal ops link with the mail server breakdown", %{conn: conn} do
      email = hold_sign_up(conn, ["mx.known-mail.test", "mx.unknown.test"])
      job = job_for("alice@firezone.dev")

      assert :ok = perform_job(SignUpReviewRequest, job.args)

      assert_email_sent(fn sent ->
        assert sent.to == [{"", "alice@firezone.dev"}]
        assert sent.reply_to == {"Review User", email}
        assert sent.subject == "Approve sign-up: Review Corp"
        assert sent.text_body =~ "Mail servers:\n  mx.known-mail.test (allowed)\n  mx.unknown.test (unknown)"
        assert sent.text_body =~ "http://localhost:13102/sign_up_review?token="
        true
      end)
    end

    test "sends nothing to a removed approver", %{conn: conn} do
      hold_sign_up(conn)
      Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: ["bob@firezone.dev"])

      assert :ok = perform_job(SignUpReviewRequest, job_for("alice@firezone.dev").args)
      refute_email_sent()
    end
  end

  defp hold_sign_up(conn, mx_hosts \\ ["mx.unknown.test"]) do
    stub_mx(mx_hosts)
    email = unique_email()
    assert redirected_to(verify(conn, email)) == ~p"/sign_up/pending"
    email
  end

  defp assert_blocked(conn) do
    assert redirected_to(conn) =~ "/verify_sign_up?token="
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not allowed"
  end

  defp job_for(approver) do
    Enum.find(all_enqueued(worker: SignUpReviewRequest), &(&1.args["approver"] == approver))
  end

  defp verify(conn, email) do
    conn = get(conn, ~p"/sign_up")
    {conn, browser_id} = {recycle(conn), conn.private.sign_up_browser_id}

    claims = %{
      email: email,
      company_name: "Review Corp",
      actor_name: "Review User",
      browser: PortalWeb.Cookie.SignUpBrowser.token_claim(browser_id)
    }

    token = Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, claims)
    post(conn, ~p"/verify_sign_up", %{"token" => token})
  end

  defp stub_mx(hosts) do
    records =
      Enum.map(hosts, fn host ->
        :inet_dns.make_rr(domain: ~c"example.test", type: :mx, class: :in, data: {10, String.to_charlist(host)})
      end)

    stub_resolve(fn _domain -> {:ok, :inet_dns.make_msg(anlist: records)} end)
  end

  defp stub_resolve(fun) do
    Portal.Config.put_env_override(:portal, SignUpReview, resolve_mx: fun)
  end

  defp stub_stripe(email) do
    Stripe.stub(
      [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_test", "Review Corp", email)}] ++
        Stripe.mock_create_subscription_endpoint()
    )
  end

  defp unique_email, do: "owner-#{System.unique_integer([:positive])}@review.test"
end
