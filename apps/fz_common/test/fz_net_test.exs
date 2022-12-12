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

  describe "rand_ip/2" do
    test "returns {:error, :range} for /32" do
      assert FzNet.rand_ip("100.64.0.0/32", :ipv4) == {:error, :range}
    end

    test "returns {:error, :range} for /31" do
      assert FzNet.rand_ip("100.64.0.0/31", :ipv4) == {:error, :range}
    end

    test "returns either 100.64.0.{1,2} for /30" do
      {:ok, rip} = FzNet.rand_ip("100.64.0.0/30", :ipv4)

      possibilities =
        Enum.map([1, 2], fn a -> %Postgrex.INET{address: {100, 64, 0, a}, netmask: nil} end)

      assert Enum.member?(possibilities, rip)
    end

    test "returns {:error, :range} for /128" do
      assert FzNet.rand_ip("fd00::/128", :ipv6) == {:error, :range}
    end

    test "returns {:error, :range} for /127" do
      assert FzNet.rand_ip("fd00::/127", :ipv6) == {:error, :range}
    end

    test "returns either fd00::1 or fd00::2 for /126" do
      {:ok, rip} = FzNet.rand_ip("fd00::/126", :ipv6)

      possibilities =
        Enum.map([1, 2], fn a ->
          %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 0, a}, netmask: nil}
        end)

      assert Enum.member?(possibilities, rip)
    end

    test "returns random ipv4 in range" do
      cidr = "100.64.0.0/10"
      {:ok, rip} = FzNet.rand_ip(cidr, :ipv4)
      assert CIDR.match(CIDR.parse(cidr), rip.address)
    end

    test "returns random ipv6 in range" do
      cidr = "fd00::/106"
      {:ok, rip} = FzNet.rand_ip(cidr, :ipv6)
      assert CIDR.match(CIDR.parse(cidr), rip.address)
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

  describe "endpoint_to_ip/1" do
    test "IPv4" do
      assert "192.168.1.1" == FzNet.endpoint_to_ip("192.168.1.1:4562")
    end

    test "short IPv6s" do
      assert "2600::1" == FzNet.endpoint_to_ip("[2600::1]:4562")
    end

    test "expanded IPv6s" do
      assert "2600:1:1:1:1:1:1:1" == FzNet.endpoint_to_ip("[2600:1:1:1:1:1:1:1]:4562")
    end
  end
end
