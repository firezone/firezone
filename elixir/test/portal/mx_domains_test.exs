defmodule Portal.MXDomainsTest do
  use Portal.DataCase, async: true
  import ExUnit.CaptureLog
  import Portal.MXDomainFixtures
  alias Portal.MXDomains

  describe "check_email/1" do
    setup do
      mx_domain_fixture("mail.tm")
      mx_domain_fixture("google.com", :good, nil)
      :ok
    end

    test "is bad when a mail server is under a bad domain" do
      stub_mx(fn "fldubai.com" -> {:ok, ["in.mail.tm"]} end)

      assert MXDomains.check_email("user@FLDubai.com") ==
               {:bad, %{email_domain: "fldubai.com", mx_host: "in.mail.tm", mx_domain: "mail.tm"}}
    end

    test "names the most specific bad domain" do
      mx_domain_fixture("in.mail.tm")
      stub_mx(fn _domain -> {:ok, ["in.mail.tm"]} end)

      assert {:bad, %{mx_domain: "in.mail.tm"}} = MXDomains.check_email("user@fldubai.com")
    end

    test "is bad when any one of several mail servers is" do
      stub_mx(fn _domain -> {:ok, ["aspmx.l.google.com", "mx.self.example", "in.mail.tm"]} end)

      assert {:bad, %{mx_host: "in.mail.tm"}} = MXDomains.check_email("user@mixed.example")
    end

    test "is bad when a mail server is under both a bad and a good domain" do
      mx_domain_fixture("in.mail.tm", :good, nil)
      stub_mx(fn _domain -> {:ok, ["in.mail.tm"]} end)

      assert {:bad, %{mx_domain: "mail.tm"}} = MXDomains.check_email("user@fldubai.com")
    end

    test "is good when every mail server is under a good domain" do
      mx_domain_fixture("outlook.com", :good, nil)
      stub_mx(fn "firezone.dev" -> {:ok, ["aspmx.l.google.com", "firezone-dev.mail.protection.outlook.com"]} end)

      assert MXDomains.check_email("user@firezone.dev") ==
               {:good, %{email_domain: "firezone.dev", mx_host: "aspmx.l.google.com", mx_domain: "google.com"}}
    end

    test "is unknown when any mail server is unrated and none is bad" do
      stub_mx(fn
        "self.example" -> {:ok, ["mail.self.example"]}
        "mixed.example" -> {:ok, ["aspmx.l.google.com", "mx.mixed.example"]}
      end)

      assert MXDomains.check_email("user@self.example") ==
               {:unknown, %{email_domain: "self.example", mx_host: "mail.self.example", mx_domain: nil}}

      assert {:unknown, %{mx_host: "mx.mixed.example"}} = MXDomains.check_email("user@mixed.example")
    end

    test "does not match a domain that only ends with a rated one" do
      stub_mx(fn _domain -> {:ok, ["in.notmail.tm"]} end)

      assert {:unknown, %{mx_domain: nil}} = MXDomains.check_email("user@example.com")
    end

    test "rates the email domain itself when it has no MX records" do
      stub_mx(fn _domain -> {:ok, []} end)

      assert MXDomains.check_email("user@mail.tm") ==
               {:bad, %{email_domain: "mail.tm", mx_host: nil, mx_domain: "mail.tm"}}

      assert {:bad, %{mx_domain: "mail.tm"}} = MXDomains.check_email("user@sub.mail.tm")
      assert {:good, %{mx_host: nil, mx_domain: "google.com"}} = MXDomains.check_email("user@google.com")
      assert {:unknown, %{mx_host: nil, mx_domain: nil}} = MXDomains.check_email("user@example.com")
    end

    test "only rates mail servers when the email domain has MX records" do
      stub_mx(fn "mail.tm" -> {:ok, ["mx.example.com"]} end)

      assert {:unknown, %{mx_host: "mx.example.com"}} = MXDomains.check_email("user@mail.tm")
    end

    test "is unchecked and logged when the lookup fails" do
      for reason <- [:timeout, :nxdomain, :servfail] do
        stub_mx(fn _domain -> {:error, reason} end)

        log =
          capture_log([level: :info], fn -> assert MXDomains.check_email("user@example.com") == :unchecked end)

        assert log =~ "MX lookup failed, allowing sign-up"
        assert log =~ "email_domain=example.com"
      end
    end

    test "is unchecked for emails without a domain, without looking them up" do
      stub_mx(fn _domain -> flunk("MX records looked up") end)

      assert MXDomains.check_email("user") == :unchecked
      assert MXDomains.check_email("user@") == :unchecked
      assert MXDomains.check_email("") == :unchecked
    end
  end

  describe "email_domain/1" do
    test "returns the lowercased domain after the last @" do
      assert MXDomains.email_domain(" User@Example.COM. ") == "example.com"
      assert MXDomains.email_domain("\"a@b\"@example.com") == "example.com"
    end

    test "returns nil without a domain" do
      assert MXDomains.email_domain("user") == nil
      assert MXDomains.email_domain("user@") == nil
      assert MXDomains.email_domain("@") == nil
    end
  end
end
