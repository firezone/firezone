defmodule Portal.DisposableEmailTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Portal.DisposableEmail
  import Portal.DisposableEmailHelpers

  describe "email_domain/1" do
    test "returns the lowercased domain without a trailing dot" do
      assert email_domain("user@Example.COM") == "example.com"
      assert email_domain(" user@example.com. ") == "example.com"
    end

    test "uses the part after the last @" do
      assert email_domain("\"a@b\"@example.com") == "example.com"
    end

    test "returns nil without a domain" do
      assert email_domain("user") == nil
      assert email_domain("user@") == nil
      assert email_domain(nil) == nil
    end
  end

  describe "screen/1 by domain" do
    setup do
      use_disposable_email_lists(confirmed: ["fldubai.com"], suspected: ["mailinator.com"])
      :ok
    end

    test "blocks confirmed domains and their subdomains" do
      assert screen("fldubai.com") == {:block, :domain}
      assert screen("FLDUBAI.com.") == {:block, :domain}
      assert screen("a.b.fldubai.com") == {:block, :domain}
    end

    test "warns on suspected domains and their subdomains" do
      assert screen("mailinator.com") == {:warn, :domain}
      assert screen("sub.mailinator.com") == {:warn, :domain}
    end

    test "allows other domains" do
      assert screen("example.com") == :ok
      assert screen("notfldubai.com") == :ok
    end

    test "blocks when a domain is on both lists" do
      use_disposable_email_lists(confirmed: ["both.example"], suspected: ["both.example"])

      assert screen("both.example") == {:block, :domain}
    end
  end

  test "screen/1 allows everything without lists" do
    use_disposable_email_lists([])

    assert screen("fldubai.com") == :ok
  end

  describe "screen/1 by MX" do
    setup do
      Portal.Config.put_env_override(:sign_up_disposable_mx_check_enabled, true)
      use_disposable_email_lists(confirmed: ["mail.tm"], suspected: ["guerrillamail.com"])
      :ok
    end

    test "blocks domains whose mail servers are under a confirmed domain" do
      stub_mx(fn "fldubai.com" -> {:ok, ["in.mail.tm"]} end)

      assert screen("FLDUBAI.com") == {:block, :mx}
    end

    test "warns on domains whose mail servers are under a suspected domain" do
      stub_mx(fn _domain -> {:ok, ["mail.guerrillamail.com"]} end)

      assert screen("sharklasers.com") == {:warn, :mx}
    end

    test "blocks when one of several mail servers is under a confirmed domain" do
      stub_mx(fn _domain -> {:ok, ["mail.guerrillamail.com", "in.mail.tm"]} end)

      assert screen("fresh.example") == {:block, :mx}
    end

    test "blocks a suspected domain whose mail servers are under a confirmed domain" do
      stub_mx(fn _domain -> {:ok, ["in.mail.tm"]} end)

      assert screen("guerrillamail.com") == {:block, :mx}
    end

    test "does not look up a confirmed domain" do
      stub_mx(fn _domain -> flunk("MX records looked up") end)

      assert screen("mail.tm") == {:block, :domain}
    end

    test "allows domains served by other mail servers or none" do
      stub_mx(fn
        "example.com" -> {:ok, ["aspmx.l.google.com"]}
        "nomx.example" -> {:ok, []}
      end)

      assert screen("example.com") == :ok
      assert screen("nomx.example") == :ok
    end

    test "allows and logs when the lookup fails" do
      for reason <- [:timeout, :nxdomain, :servfail] do
        stub_mx(fn _domain -> {:error, reason} end)

        log = capture_log([level: :info], fn -> assert screen("example.com") == :ok end)

        assert log =~ "Disposable email MX lookup failed, allowing sign-up"
        assert log =~ "email_domain=example.com"
      end
    end

    test "does not look up names that are not hostnames" do
      stub_mx(fn _domain -> flunk("MX records looked up") end)

      assert screen("localhost") == :ok
      assert screen("exa mple.com") == :ok
      assert screen("bücher.example") == :ok
    end

    test "does not look up MX records when disabled" do
      Portal.Config.put_env_override(:sign_up_disposable_mx_check_enabled, false)
      stub_mx(fn _domain -> flunk("MX records looked up") end)

      assert screen("fldubai.com") == :ok
    end

    test "does not look up MX records without lists" do
      use_disposable_email_lists([])
      stub_mx(fn _domain -> flunk("MX records looked up") end)

      assert screen("fldubai.com") == :ok
    end
  end
end
