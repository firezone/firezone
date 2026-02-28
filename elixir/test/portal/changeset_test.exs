defmodule Portal.ChangesetTest do
  use ExUnit.Case, async: true

  alias Portal.Changeset

  describe "private_ip?/1" do
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
