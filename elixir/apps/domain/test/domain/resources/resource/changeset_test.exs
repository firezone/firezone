defmodule Domain.Resources.Resource.ChangesetTest do
  use Domain.DataCase, async: true
  import Domain.Resources.Resource.Changeset

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)
    resource = Fixtures.Resources.create_resource(account: account)

    %{account: account, actor: actor, identity: identity, subject: subject, resource: resource}
  end

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

      [
        "foobar",
        "192.168.1.256/28",
        "100.64.0.0/8",
        "fd00:2021:1111::/102",
        "0.0.0.0/32",
        "0.0.0.0/16",
        "0.0.0.0/0",
        "127.0.0.1/32",
        "::0/32",
        "::1/128",
        "::8/8",
        "2607:f8b0:4012:0::200e/128:80"
      ]
      |> Enum.each(fn string ->
        refute create(%{type: :cidr, address: string}).valid?
      end)
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

      [
        "foobar",
        "192.168.1.256",
        "100.64.0.0",
        "fd00:2021:1111::",
        "0.0.0.0",
        "::0",
        "127.0.0.1",
        "::1",
        "[2607:f8b0:4012:0::200e]:80"
      ]
      |> Enum.each(fn string ->
        refute create(%{type: :ip, address: string}).valid?
      end)
    end

    test "accepts valid DNS addresses" do
      for valid_address <- [
            "**.foo.google.com",
            "?.foo.google.com",
            "web-*.foo.google.com",
            "web-?.foo.google.com",
            "web-*.google.com",
            "web-?.google.com",
            "**.*.?.foo.foo.com",
            "**.google.com",
            "?.google.com",
            "*.*.*.*.google.com",
            "?.?.?.?.google.com",
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

      [
        "1.1.1.1/32",
        "1.1.1.1",
        ".example.com",
        "example..com",
        "**",
        "**.",
        "*.",
        "*.*",
        "?",
        "?.",
        "example.com.",
        "exa&mple.com",
        "",
        "http://example.com/",
        "//example.com/",
        "example.com/",
        ".example.com",
        "example.",
        "example.com:80"
      ]
      |> Enum.each(fn invalid_address ->
        refute create(%{type: :dns, address: invalid_address}).valid?
      end)
    end
  end

  describe "update/2" do
    test "validates and normalizes CIDR ranges", %{resource: resource, subject: subject} do
      for {string, cidr} <- [
            {"192.168.1.1/24", "192.168.1.0/24"},
            {"101.100.100.0/28", "101.100.100.0/28"},
            {"192.168.1.255/28", "192.168.1.240/28"},
            {"192.168.1.255/32", "192.168.1.255/32"},
            {"2607:f8b0:4012:0::200e/128", "2607:f8b0:4012::200e/128"}
          ] do
        {changeset, _} =
          update(
            resource,
            %{
              name: "foo",
              type: :cidr,
              address: string,
              address_description: string
            },
            subject
          )

        assert changeset.changes.address == cidr
        assert changeset.valid?
      end

      [
        "foobar",
        "192.168.1.256/28",
        "100.64.0.0/8",
        "fd00:2021:1111::/102",
        "0.0.0.0/32",
        "0.0.0.0/16",
        "0.0.0.0/0",
        "127.0.0.1/32",
        "::0/32",
        "::1/128",
        "::8/8",
        "2607:f8b0:4012:0::200e/128:80"
      ]
      |> Enum.each(fn invalid_cidr ->
        {changeset, _} = update(resource, %{type: :cidr, address: invalid_cidr}, subject)
        refute changeset.valid?
      end)
    end

    test "validates and normalizes IP addresses", %{resource: resource, subject: subject} do
      for {string, ip} <- [
            {"192.168.1.1", "192.168.1.1"},
            {"101.100.100.0", "101.100.100.0"},
            {"192.168.1.255", "192.168.1.255"},
            {"2607:f8b0:4012:0::200e", "2607:f8b0:4012::200e"}
          ] do
        {changeset, _} =
          update(
            resource,
            %{
              name: "foo",
              type: :ip,
              address: string,
              address_description: string
            },
            subject
          )

        assert changeset.changes.address == ip
        assert changeset.valid?
      end

      [
        "foobar",
        "192.168.1.256",
        "100.64.0.0",
        "fd00:2021:1111::",
        "0.0.0.0",
        "::0",
        "127.0.0.1",
        "::1",
        "[2607:f8b0:4012:0::200e]:80"
      ]
      |> Enum.each(fn invalid_ip ->
        {changeset, _} = update(resource, %{type: :ip, address: invalid_ip}, subject)
        refute changeset.valid?
      end)
    end

    test "accepts valid DNS addresses", %{resource: resource, subject: subject} do
      for valid_address <- [
            "**.foo.google.com",
            "?.foo.google.com",
            "web-*.foo.google.com",
            "web-?.foo.google.com",
            "web-*.google.com",
            "web-?.google.com",
            "**.*.?.foo.foo.com",
            "**.google.com",
            "?.google.com",
            "*.*.*.*.google.com",
            "?.?.?.?.google.com",
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
        {changeset, _} =
          update(
            resource,
            %{
              name: "foo",
              type: :dns,
              address: valid_address,
              address_description: valid_address
            },
            subject
          )

        assert changeset.valid?
      end

      [
        "2600::1/32",
        "2600::1",
        "1.1.1.1/32",
        "1.1.1.1",
        ".example.com",
        "example..com",
        "**",
        "**.",
        "*.",
        "*.*",
        "?",
        "?.",
        "example.com.",
        "exa&mple.com",
        "",
        "http://example.com/",
        "//example.com/",
        "example.com/",
        ".example.com",
        "example.",
        "example.com:80"
      ]
      |> Enum.each(fn invalid_address ->
        {changeset, _} = update(resource, %{type: :dns, address: invalid_address}, subject)
        refute changeset.valid?
      end)
    end
  end

  def create(attrs) do
    Fixtures.Accounts.create_account()
    |> create(attrs)
  end
end
