defmodule Portal.ChangesetTest do
  use ExUnit.Case, async: true

  alias Portal.Changeset

  describe "private_ip?/1" do
    test "blocks link-local addresses" do
      ips = [
        "169.254.0.0",
        "169.254.169.254",
        "169.254.255.255",
        "fe80::1",
        "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
      ]

      for ip <- ips do
        assert Changeset.private_ip?(parse_ip!(ip)), "Expected #{ip} to be blocked"
      end
    end

    test "blocks link-local addresses wrapped in deprecated IPv6 embeddings" do
      ips = [
        "::ffff:169.254.169.254",
        "::169.254.169.254",
        "::ffff:0:169.254.169.254",
        "64:ff9b::169.254.169.254",
        "2002:a9fe:a9fe::1"
      ]

      for ip <- ips do
        assert Changeset.private_ip?(parse_ip!(ip)), "Expected #{ip} to be blocked"
      end
    end

    test "blocks site-local addresses" do
      assert Changeset.private_ip?(parse_ip!("fec0::1"))
      assert Changeset.private_ip?(parse_ip!("feff::1"))
    end

    test "allows addresses adjacent to the link-local ranges" do
      refute Changeset.private_ip?(parse_ip!("169.253.255.255"))
      refute Changeset.private_ip?(parse_ip!("169.255.0.0"))
      refute Changeset.private_ip?(parse_ip!("2606:4700:4700::1111"))
    end

    test "blocks IPv4-mapped IPv6 addresses when embedded IPv4 is blocked" do
      for ip <- ["::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:10.0.0.1"] do
        assert Changeset.private_ip?(parse_ip!(ip)), "Expected #{ip} to be blocked"
      end
    end

    test "allows IPv4-mapped IPv6 addresses when embedded IPv4 is public" do
      refute Changeset.private_ip?(parse_ip!("::ffff:8.8.8.8"))
    end
  end

  describe "public_host?/1" do
    test "returns false for private and reserved hosts" do
      refute Changeset.public_host?("127.0.0.1")
      refute Changeset.public_host?("::1")
      refute Changeset.public_host?("::ffff:127.0.0.1")
      refute Changeset.public_host?("localhost")
    end

    test "returns true for public hosts" do
      assert Changeset.public_host?("8.8.8.8")
      assert Changeset.public_host?("accounts.google.com")
    end
  end

  defp parse_ip!(ip) do
    {:ok, parsed_ip} = :inet.parse_address(String.to_charlist(ip))
    parsed_ip
  end
end
