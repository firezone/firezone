defmodule Portal.ResourceTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SiteFixtures

  alias Portal.Resource

  # Valid DNS addresses that should be accepted
  @valid_dns_addresses [
    # Wildcard patterns
    "**.foo.google.com",
    "?.foo.google.com",
    "web-*.foo.google.com",
    "web-?.foo.google.com",
    "*.google.com",
    "**.google.com",
    # Multi-level wildcards
    "sub.**.example.com",
    "sub.**.foo.bar.google.com",
    "*.*.*.*.google.com",
    "?.?.?.?.google.com",
    # Basic domains
    "example.com",
    "example.weird",
    "subdomain.subdomain2.example.space",
    "sub.domain",
    "sub-domain.com",
    "sub--domain.com",
    "a-b-c.d-e-f.g-h-i",
    # Single labels
    "google",
    "single.label",
    # Numeric
    "1234567890.com",
    # Max length label (63 chars)
    "#{String.duplicate("a", 63)}.com",
    # Unicode/IDN
    "такі.справи",
    "xn--fssq61j.com",
    "*.xn--fssq61j.com",
    "**.xn--fssq61j.com",
    "sub.**.xn--fssq61j.com",
    # Many subdomains
    "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z.com"
  ]

  # Invalid DNS addresses that should be rejected
  @invalid_dns_addresses [
    # IP addresses (should use IP type instead)
    "1.1.1.1",
    "1.1.1.1/32",
    "2600::1",
    "2600::1/32",
    # Leading/trailing dots
    ".example.com",
    "example.com.",
    "example.",
    # Double dots
    "example..com",
    # Invalid wildcard positions
    "**",
    "**.",
    "*.",
    "*.*",
    "?",
    "?.",
    "foo.**",
    "**example.com",
    "foo.**bar.com",
    "example.com.**",
    "foo**.com",
    "***.foo.com",
    "**.**test.com",
    "**.foo**test.com",
    "foo.**bar",
    "**test",
    # Wildcard-only for common TLDs
    "*.com",
    "?.com",
    "*.com.",
    "**.com.",
    # Special characters
    "exa&mple.com",
    "example_com",
    "example.com?",
    "example.com*",
    # URLs (not bare hostnames)
    "http://example.com/",
    "//example.com/",
    "example.com/",
    # Starting/ending with hyphen
    "-example.com",
    "example-.com",
    # Port numbers
    "example.com:80",
    # Too long (label > 63 chars)
    "a.#{String.duplicate("a", 64)}.com"
  ]

  defp build_changeset(attrs) do
    %Resource{}
    |> cast(attrs, [:address, :address_description, :name, :type, :ip_stack, :site_id])
    |> Resource.changeset()
  end

  defp build_changeset_on_existing(existing, attrs) do
    existing
    |> cast(attrs, [:address, :address_description, :name, :type, :ip_stack, :site_id])
    |> Resource.changeset()
  end

  describe "changeset/1 basic validations" do
    test "validates name length maximum" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "accepts valid name length" do
      changeset = build_changeset(%{name: "valid-resource-name"})
      refute Map.has_key?(errors_on(changeset), :name)
    end

    test "validates address_description length maximum" do
      changeset = build_changeset(%{address_description: String.duplicate("a", 256)})
      assert %{address_description: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "accepts valid address_description length" do
      changeset = build_changeset(%{address_description: "A valid description"})
      refute Map.has_key?(errors_on(changeset), :address_description)
    end

    test "sets default ip_stack to :dual for DNS type" do
      changeset = build_changeset(%{type: :dns})
      assert get_field(changeset, :ip_stack) == :dual
    end

    test "does not set default ip_stack for non-DNS types" do
      changeset = build_changeset(%{type: :ip})
      assert get_field(changeset, :ip_stack) == nil
    end

    test "clears ip_stack when changing from DNS to non-DNS type" do
      existing = %Resource{type: :dns, ip_stack: :dual}
      changeset = build_changeset_on_existing(existing, %{type: :ip})
      assert get_change(changeset, :ip_stack) == nil
    end

    test "embeds filters with valid protocol" do
      changeset = build_changeset(%{filters: [%{protocol: :tcp, ports: []}]})
      refute Map.has_key?(errors_on(changeset), :filters)
    end

    test "requires protocol in filters" do
      changeset = build_changeset(%{filters: [%{ports: []}]})
      assert %{filters: [%{protocol: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "trims whitespace from name, address, and address_description" do
      changeset =
        build_changeset(%{
          type: :dns,
          name: "   my-resource   ",
          address: "   example.com   ",
          address_description: "   my description   "
        })

      assert get_change(changeset, :name) == "my-resource"
      assert get_change(changeset, :address) == "example.com"
      assert get_change(changeset, :address_description) == "my description"
    end
  end

  describe "changeset/1 internet resource type" do
    test "sets address to nil for internet type" do
      changeset = build_changeset(%{type: :internet, address: "should-be-ignored"})
      assert get_change(changeset, :address) == nil
    end

    test "clears existing address when changing to internet type" do
      existing = %Resource{type: :dns, address: "example.com"}
      changeset = build_changeset_on_existing(existing, %{type: :internet})
      assert get_change(changeset, :address) == nil
    end
  end

  describe "changeset/1 type change revalidation" do
    test "revalidates address when type changes from cidr to ip" do
      # A valid CIDR but invalid IP
      existing = %Resource{type: :cidr, address: "10.0.0.0/24"}
      changeset = build_changeset_on_existing(existing, %{type: :ip})

      assert Map.has_key?(errors_on(changeset), :address),
             "Expected CIDR address to be rejected when type changed to ip"
    end

    test "revalidates address when type changes from dns to cidr" do
      existing = %Resource{type: :dns, address: "example.com"}
      changeset = build_changeset_on_existing(existing, %{type: :cidr})

      assert Map.has_key?(errors_on(changeset), :address),
             "Expected DNS address to be rejected when type changed to cidr"
    end

    test "revalidates address when type changes from ip to dns" do
      existing = %Resource{type: :ip, address: "192.168.1.1"}
      changeset = build_changeset_on_existing(existing, %{type: :dns})

      assert Map.has_key?(errors_on(changeset), :address),
             "Expected IP address to be rejected when type changed to dns"
    end
  end

  describe "changeset/1 DNS address validation" do
    test "accepts valid DNS addresses" do
      for valid_address <- @valid_dns_addresses do
        changeset = build_changeset(%{type: :dns, address: valid_address})

        refute Map.has_key?(errors_on(changeset), :address),
               "Expected '#{valid_address}' to be valid, got: #{inspect(errors_on(changeset)[:address])}"
      end
    end

    test "rejects invalid DNS addresses" do
      for invalid_address <- @invalid_dns_addresses do
        changeset = build_changeset(%{type: :dns, address: invalid_address})

        assert Map.has_key?(errors_on(changeset), :address),
               "Expected '#{invalid_address}' to be rejected"
      end
    end

    test "rejects DNS address with port number" do
      changeset = build_changeset(%{type: :dns, address: "example.com:8080"})
      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end
  end

  describe "changeset/1 CIDR address validation" do
    test "validates and normalizes CIDR ranges" do
      for {input, expected} <- [
            {"192.168.1.1/24", "192.168.1.0/24"},
            {"101.100.100.0/28", "101.100.100.0/28"},
            {"192.168.1.255/28", "192.168.1.240/28"},
            {"192.168.1.255/32", "192.168.1.255/32"},
            {"2607:f8b0:4012:0::200e/128", "2607:f8b0:4012::200e/128"}
          ] do
        changeset = build_changeset(%{type: :cidr, address: input})

        assert get_change(changeset, :address) == expected,
               "Expected '#{input}' to normalize to '#{expected}', got '#{get_change(changeset, :address)}'"

        refute Map.has_key?(errors_on(changeset), :address),
               "Expected '#{input}' to be valid, got: #{inspect(errors_on(changeset)[:address])}"
      end
    end

    test "rejects invalid CIDR ranges" do
      for invalid_cidr <- [
            "foobar",
            "192.168.1.256/28",
            "not-a-cidr"
          ] do
        changeset = build_changeset(%{type: :cidr, address: invalid_cidr})

        assert Map.has_key?(errors_on(changeset), :address),
               "Expected '#{invalid_cidr}' to be rejected"
      end
    end

    test "rejects CIDR in private/reserved ranges" do
      for reserved_cidr <- [
            "100.64.0.0/10",
            "fd00:2021:1111::/48"
          ] do
        changeset = build_changeset(%{type: :cidr, address: reserved_cidr})

        assert Map.has_key?(errors_on(changeset), :address),
               "Expected reserved CIDR '#{reserved_cidr}' to be rejected"
      end
    end

    test "rejects CIDR for full-tunnel addresses" do
      for full_tunnel <- [
            "0.0.0.0/32",
            "0.0.0.0/0"
          ] do
        changeset = build_changeset(%{type: :cidr, address: full_tunnel})

        assert "please use the Internet Resource for full-tunnel traffic" in errors_on(changeset)[
                 :address
               ],
               "Expected '#{full_tunnel}' to be rejected with full-tunnel message"
      end
    end

    test "rejects CIDR for loopback addresses" do
      for loopback <- [
            "127.0.0.1/32",
            "127.0.0.0/8",
            "::1/128"
          ] do
        changeset = build_changeset(%{type: :cidr, address: loopback})

        assert "cannot contain loopback addresses" in errors_on(changeset)[:address],
               "Expected loopback '#{loopback}' to be rejected"
      end
    end

    test "rejects CIDR with port number" do
      changeset = build_changeset(%{type: :cidr, address: "10.0.0.0/24:8080"})
      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end

    test "rejects CIDR with malformed brackets" do
      changeset = build_changeset(%{type: :cidr, address: "[fe00::/64"})
      assert "has mismatched brackets" in errors_on(changeset)[:address]
    end
  end

  describe "changeset/1 IP address validation" do
    test "validates and normalizes IP addresses" do
      for {input, expected} <- [
            {"192.168.1.1", "192.168.1.1"},
            {"101.100.100.0", "101.100.100.0"},
            {"192.168.1.255", "192.168.1.255"},
            {"2607:f8b0:4012:0::200e", "2607:f8b0:4012::200e"}
          ] do
        changeset = build_changeset(%{type: :ip, address: input})

        assert get_change(changeset, :address) == expected,
               "Expected '#{input}' to normalize to '#{expected}'"

        refute Map.has_key?(errors_on(changeset), :address),
               "Expected '#{input}' to be valid, got: #{inspect(errors_on(changeset)[:address])}"
      end
    end

    test "rejects invalid IP addresses" do
      for invalid_ip <- [
            "foobar",
            "192.168.1.256",
            "not-an-ip"
          ] do
        changeset = build_changeset(%{type: :ip, address: invalid_ip})

        assert Map.has_key?(errors_on(changeset), :address),
               "Expected '#{invalid_ip}' to be rejected"
      end
    end

    test "rejects CIDR notation for ip type" do
      for cidr_address <- [
            "192.168.1.1/32",
            "192.168.1.0/24",
            "10.0.0.0/8",
            "2607:f8b0:4012::200e/128",
            "fe80::1/64"
          ] do
        changeset = build_changeset(%{type: :ip, address: cidr_address})

        assert Map.has_key?(errors_on(changeset), :address),
               "Expected CIDR '#{cidr_address}' to be rejected for ip type"
      end
    end

    test "rejects IP in private/reserved ranges" do
      for reserved_ip <- [
            "100.64.0.1",
            "fd00:2021:1111::1"
          ] do
        changeset = build_changeset(%{type: :ip, address: reserved_ip})

        assert Map.has_key?(errors_on(changeset), :address),
               "Expected reserved IP '#{reserved_ip}' to be rejected"
      end
    end

    test "rejects loopback IP addresses" do
      for loopback <- [
            "127.0.0.1",
            "::1"
          ] do
        changeset = build_changeset(%{type: :ip, address: loopback})

        assert "cannot contain loopback addresses" in errors_on(changeset)[:address],
               "Expected loopback '#{loopback}' to be rejected"
      end
    end

    test "rejects all-zero IP addresses" do
      changeset = build_changeset(%{type: :ip, address: "0.0.0.0"})
      assert "cannot contain all IPv4 addresses" in errors_on(changeset)[:address]

      changeset = build_changeset(%{type: :ip, address: "::"})
      assert "cannot contain all IPv6 addresses" in errors_on(changeset)[:address]
    end

    test "rejects IP address with port number" do
      changeset = build_changeset(%{type: :ip, address: "192.168.1.1:8080"})
      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end

    test "rejects bracketed IPv6 with port number" do
      changeset = build_changeset(%{type: :ip, address: "[2001:db8::1]:8080"})
      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end

    test "accepts full IPv6 address" do
      changeset =
        build_changeset(%{type: :ip, address: "2001:0db8:85a3:0000:0000:8a2e:0370:7334"})

      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "rejects IP with malformed brackets" do
      changeset = build_changeset(%{type: :ip, address: "fe00::]/1"})
      assert "has mismatched brackets" in errors_on(changeset)[:address]

      changeset = build_changeset(%{type: :ip, address: "[fe00::"})
      assert "has mismatched brackets" in errors_on(changeset)[:address]
    end

    test "accepts properly bracketed IPv6 without port" do
      changeset = build_changeset(%{type: :ip, address: "[2001:db8::1]"})
      refute "has mismatched brackets" in Map.get(errors_on(changeset), :address, [])
    end
  end

  describe "changeset/1 association constraints" do
    test "enforces account association constraint" do
      site = site_fixture()

      {:error, changeset} =
        %Resource{}
        |> cast(
          %{
            account_id: Ecto.UUID.generate(),
            name: "Test Resource",
            type: :cidr,
            address: "10.0.0.0/24",
            site_id: site.id
          },
          [:account_id, :name, :type, :address, :site_id]
        )
        |> Resource.changeset()
        |> Repo.insert()

      assert %{account: ["does not exist"]} = errors_on(changeset)
    end

    test "enforces site association constraint" do
      account = account_fixture()

      {:error, changeset} =
        %Resource{}
        |> cast(
          %{
            name: "Test Resource",
            type: :cidr,
            address: "10.0.0.0/24",
            site_id: Ecto.UUID.generate()
          },
          [:name, :type, :address, :site_id]
        )
        |> put_assoc(:account, account)
        |> Resource.changeset()
        |> Repo.insert()

      assert %{site: ["does not exist"]} = errors_on(changeset)
    end

    test "allows valid associations" do
      account = account_fixture()
      site = site_fixture(account: account)

      {:ok, resource} =
        %Resource{}
        |> cast(
          %{
            name: "Test Resource",
            type: :cidr,
            address: "10.0.0.0/24"
          },
          [:name, :type, :address]
        )
        |> put_assoc(:account, account)
        |> put_assoc(:site, site)
        |> Resource.changeset()
        |> Repo.insert()

      assert resource.account_id == account.id
      assert resource.site_id == site.id
    end
  end
end
