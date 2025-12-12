defmodule Domain.Resources.Resource.ChangesetTest do
  use Domain.DataCase, async: true
  import Domain.Resources.Resource.Changeset

  @valid_dns_addresses [
    "**.foo.google.com",
    "?.foo.google.com",
    "web-*.foo.google.com",
    "web-?.foo.google.com",
    "web-*.google.com",
    "web-?.google.com",
    "sub.**.example.com",
    "sub.**.foo.bar.google.com",
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
    "subdomain.subdomain2.example.space",
    "single.label",
    "a-b-c.d-e-f.g-h-i",
    "xn--fssq61j.com",
    "*.xn--fssq61j.com",
    "**.xn--fssq61j.com",
    "sub.**.xn--fssq61j.com",
    "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z.a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z.a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z.com",
    "sub.domain",
    "sub-domain.com",
    "sub--domain.com"
  ]

  @invalid_dns_addresses [
    "2600::1/32",
    "2600::1",
    "1.1.1.1/32",
    "1.1.1.1",
    ".example.com",
    "example..com",
    "**example.com",
    "example. com.**",
    "example.com.**",
    "foo.**bar.com",
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
    "example.com:80",
    "-example.com",
    "example-.com",
    "example_com",
    "example..com",
    "too.long.#{String.duplicate("a", 256)}",
    "a.#{String.duplicate("a", 64)}.com",
    "example.com/",
    "example.com?",
    "example.com*",
    "*.com.",
    "**.com.",
    "foo.**",
    "foo**.com",
    "**.example.com.",
    "example..**",
    "**example.com",
    "***.foo.com",
    "**.**test.com",
    "**.foo**test.com",
    "foo.**bar",
    "**test",
    "*.com",
    "?.com"
  ]

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

        assert changeset.valid?,
               "Expected '#{string}' to be valid, got: #{inspect(changeset.errors)}"
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
        refute create(%{type: :cidr, address: string}).valid?,
               "Expected '#{string}' to be invalid"
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

        assert changeset.valid?,
               "Expected '#{string}' to be valid, got: #{inspect(changeset.errors)}"
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
        refute create(%{type: :ip, address: string}).valid?,
               "Expected '#{string}' to be invalid"
      end)
    end

    test "accepts valid DNS addresses" do
      for valid_address <- @valid_dns_addresses do
        changeset =
          create(%{
            name: "foo",
            type: :dns,
            address: valid_address,
            address_description: valid_address
          })

        assert changeset.valid?,
               "Expected '#{valid_address}' to be valid, got: #{inspect(changeset.errors)}"
      end

      for invalid_address <- @invalid_dns_addresses do
        changeset = create(%{type: :dns, address: invalid_address})
        refute changeset.valid?, "Expected '#{invalid_address}' to be invalid"
      end
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
        changeset =
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

        assert changeset.valid?,
               "Expected '#{string}' to be valid, got: #{inspect(changeset.errors)}"
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
        changeset = update(resource, %{type: :cidr, address: invalid_cidr}, subject)
        refute changeset.valid?, "Expected '#{invalid_cidr}' to be invalid"
      end)
    end

    test "validates and normalizes IP addresses", %{resource: resource, subject: subject} do
      for {string, ip} <- [
            {"192.168.1.1", "192.168.1.1"},
            {"101.100.100.0", "101.100.100.0"},
            {"192.168.1.255", "192.168.1.255"},
            {"2607:f8b0:4012:0::200e", "2607:f8b0:4012::200e"}
          ] do
        changeset =
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

        assert changeset.valid?,
               "Expected '#{string}' to be valid, got: #{inspect(changeset.errors)}"
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
        changeset = update(resource, %{type: :ip, address: invalid_ip}, subject)
        refute changeset.valid?, "Expected '#{invalid_ip}' to be invalid"
      end)
    end

    test "accepts valid DNS addresses", %{resource: resource, subject: subject} do
      for valid_address <- @valid_dns_addresses do
        changeset =
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

        assert changeset.valid?,
               "Expected '#{valid_address}' to be valid, got: #{inspect(changeset.errors)}"
      end

      for invalid_address <- @invalid_dns_addresses do
        changeset = update(resource, %{type: :dns, address: invalid_address}, subject)
        refute changeset.valid?, "Expected '#{invalid_address}' to be invalid"
      end
    end

    test "trims whitespace on changes" do
      for {name, type, address, description} <- [
            {"foo", :ip, "192.168.1.1", "local server"},
            {"bar", :cidr, "192.168.1.0/24", "local network"},
            {"baz", :dns, "example.com", "local server"}
          ] do
        changeset =
          create(%{
            name: "   " <> name <> "   ",
            type: type,
            address: "   " <> address <> "   ",
            address_description: "   " <> description <> "   "
          })

        assert changeset.changes[:name] == name
        assert changeset.changes[:address] == address
        assert changeset.changes[:address_description] == description
        assert changeset.valid?
      end
    end
  end

  def create(attrs) do
    Fixtures.Accounts.create_account()
    |> create(attrs)
  end
end
