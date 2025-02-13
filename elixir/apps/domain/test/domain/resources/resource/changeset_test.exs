defmodule Domain.Resources.Resource.ChangesetTest do
  use Domain.DataCase, async: true
  import Domain.Resources.Resource.Changeset

  describe "create/2" do
    test "validates and normalizes CIDR ranges" do
      for {string, cidr} <- [
            {"192.168.1.1/24", "192.168.1.0/24"},
            {"101.100.100.0/28", "101.100.100.0/28"},
            {"192.168.1.255/28", "192.168.1.240/28"},
            {"192.168.1.255/32", "192.168.1.255/32"},
            {"2607:f8b0:4012:0::200e/128", "2607:f8b0:4012::200e/128"}
          ] do
        changeset =
          create(%{
            name: "foo",
            type: :cidr,
            address: string,
            address_description: string
          })

        assert changeset.changes[:address] == cidr
        assert changeset.valid?
      end

      refute create(%{type: :cidr, address: "192.168.1.256/28"}).valid?
      refute create(%{type: :cidr, address: "100.64.0.0/8"}).valid?
      refute create(%{type: :cidr, address: "fd00:2021:1111::/102"}).valid?
      refute create(%{type: :cidr, address: "0.0.0.0/32"}).valid?
      refute create(%{type: :cidr, address: "0.0.0.0/16"}).valid?
      refute create(%{type: :cidr, address: "0.0.0.0/0"}).valid?
      refute create(%{type: :cidr, address: "127.0.0.1/32"}).valid?
      refute create(%{type: :cidr, address: "::0/32"}).valid?
      refute create(%{type: :cidr, address: "::1/128"}).valid?
      refute create(%{type: :cidr, address: "::8/8"}).valid?
      refute create(%{type: :cidr, address: "2607:f8b0:4012:0::200e/128:80"}).valid?
    end

    test "validates and normalizes IP addresses" do
      for {string, ip} <- [
            {"192.168.1.1", "192.168.1.1"},
            {"101.100.100.0", "101.100.100.0"},
            {"192.168.1.255", "192.168.1.255"},
            {"2607:f8b0:4012:0::200e", "2607:f8b0:4012::200e"}
          ] do
        changeset =
          create(%{
            name: "foo",
            type: :ip,
            address: string,
            address_description: string
          })

        assert changeset.changes[:address] == ip
        assert changeset.valid?
      end

      refute create(%{type: :ip, address: "192.168.1.256"}).valid?
      refute create(%{type: :ip, address: "100.64.0.0"}).valid?
      refute create(%{type: :ip, address: "fd00:2021:1111::"}).valid?
      refute create(%{type: :ip, address: "0.0.0.0"}).valid?
      refute create(%{type: :ip, address: "::0"}).valid?
      refute create(%{type: :ip, address: "127.0.0.1"}).valid?
      refute create(%{type: :ip, address: "::1"}).valid?
      refute create(%{type: :ip, address: "[2607:f8b0:4012:0::200e]:80"}).valid?
    end

    test "accepts valid DNS addresses" do
      for valid_address <- [
            "*.google",
            "?.google",
            "google",
            "example.com",
            "example.weird",
            "1234567890.com",
            "#{String.duplicate("a", 63)}.com",
            "такі.справи",
            "subdomain.subdomain2.example.space"
          ] do
        changeset =
          create(%{
            name: "foo",
            type: :dns,
            address: valid_address,
            address_description: valid_address
          })

        assert changeset.valid?
      end

      refute create(%{type: :dns, address: "1.1.1.1"}).valid?
      refute create(%{type: :dns, address: ".example.com"}).valid?
      refute create(%{type: :dns, address: "example.com."}).valid?
      refute create(%{type: :dns, address: "exa&mple.com"}).valid?
      refute create(%{type: :dns, address: ""}).valid?
      refute create(%{type: :dns, address: "http://example.com/"}).valid?
      refute create(%{type: :dns, address: "//example.com/"}).valid?
      refute create(%{type: :dns, address: "example.com/"}).valid?
      refute create(%{type: :dns, address: ".example.com"}).valid?
      refute create(%{type: :dns, address: "example."}).valid?
      refute create(%{type: :dns, address: "example.com:80"}).valid?
    end
  end

  def create(attrs) do
    Fixtures.Accounts.create_account()
    |> create(attrs)
  end
end
