defmodule FzCommon.FzNetTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzNet

  describe "ip_type/1" do
    test "it detects IPv4 addresses" do
      assert FzNet.ip_type("127.0.0.1") == "IPv4"
    end

    test "it detects IPv6 addresses" do
      assert FzNet.ip_type("::1") == "IPv6"
    end

    test "it reports \"unknown\" for unknown type" do
      assert FzNet.ip_type("invalid") == "unknown"
    end
  end

  describe "valid_ip?/1" do
    test "10 is an invalid IP" do
      refute FzNet.valid_ip?("10")
    end

    test "1.1.1. is an invalid IP" do
      refute FzNet.valid_ip?("1.1.1.")
    end

    test "foobar is an invalid IP" do
      refute FzNet.valid_ip?("foobar")
    end

    test "1.1.1.1 is a valid IP" do
      assert FzNet.valid_ip?("1.1.1.1")
    end

    test "::1 is a valid IP" do
      assert FzNet.valid_ip?("1.1.1.1")
    end
  end

  describe "valid_host?/1" do
    test "foobar is valid" do
      assert FzNet.valid_hostname?("foobar")
    end

    test "-foobar is invalid" do
      refute FzNet.valid_hostname?("-foobar")
    end

    test "1234 is valid" do
      assert FzNet.valid_hostname?("1234")
    end
  end

  describe "valid_fqdn?/1" do
    test "foobar is invalid" do
      refute FzNet.valid_fqdn?("foobar")
    end

    test "-foobar is invalid" do
      refute FzNet.valid_fqdn?("-foobar")
    end

    test "foobar.com is valid" do
      assert FzNet.valid_fqdn?("foobar.com")
    end

    test "ff99.example.com is valid" do
      assert FzNet.valid_fqdn?("ff00.example.com")
    end
  end

  describe "valid_cidr?/1" do
    test "::/0f is an invalid CIDR" do
      refute FzNet.valid_cidr?("::/0f")
    end

    test "0.0.0.0/0f is an invalid CIDR" do
      refute FzNet.valid_cidr?("0.0.0.0/0f")
    end

    test "0.0.0.0 is an invalid CIDR" do
      refute FzNet.valid_cidr?("0.0.0.0")
    end

    test "foobar is an invalid CIDR" do
      refute FzNet.valid_cidr?("foobar")
    end

    test "0.0.0.0/0 is a valid CIDR" do
      assert FzNet.valid_cidr?("::/0")
    end

    test "::/0 is a valid CIDR" do
      assert FzNet.valid_cidr?("::/0")
    end
  end

  describe "standardized_inet/1" do
    test "sanitizes CIDRs with invalid start" do
      assert "10.0.0.0/24" == FzNet.standardized_inet("10.0.0.5/24")
    end

    test "formats CIDRs" do
      assert "::/0" == FzNet.standardized_inet("::0/0")
    end

    test "formats IP address" do
      assert "fd00:3::1" == FzNet.standardized_inet("fd00:3:0000::1")
    end
  end

  describe "to_complete_url/1" do
    @tag cases: [
           {"foobar", "https://foobar"},
           {"google.com", "https://google.com"},
           {"127.0.0.1", "https://127.0.0.1"},
           {"8.8.8.8", "https://8.8.8.8"},
           {"https://[fd00::1]", "https://[fd00::1]"},
           {"http://foobar", "http://foobar"},
           {"https://foobar", "https://foobar"}
         ]
    test "parses valid string URIs", %{cases: cases} do
      for {subject, expected} <- cases do
        assert {:ok, ^expected} = FzNet.to_complete_url(subject)
      end
    end

    @tag cases: ["<", "{", "["]
    test "returns {:error, _} for invalid URIs", %{cases: cases} do
      for subject <- cases do
        assert {:error, _} = FzNet.to_complete_url(subject)
      end
    end
  end

  describe "inet_to_ip_with_mask/2" do
    test "with netmask" do
      assert FzNet.inet_to_ip_with_mask(
               %Postgrex.INET{address: {10, 3, 2, 1}, netmask: 24},
               "10.3.2.0/24"
             ) == "10.3.2.1/24"
    end

    test "without netmask" do
      assert FzNet.inet_to_ip_with_mask(
               %Postgrex.INET{address: {10, 3, 2, 1}, netmask: nil},
               "10.3.2.0/24"
             ) == "10.3.2.1/24"
    end

    test "ipv6 with netmask" do
      assert "fd00::1/120" ==
               "#{FzNet.inet_to_ip_with_mask(%Postgrex.INET{address: {0xfd00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01}, netmask: 120}, "fd00::/120")}"
    end

    test "ipv6 without netmask" do
      assert "fd00::1/120" ==
               "#{FzNet.inet_to_ip_with_mask(%Postgrex.INET{address: {0xfd00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01}, netmask: nil}, "fd00::/120")}"
    end
  end
end
