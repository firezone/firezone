defmodule Domain.ResourceTest do
  use ExUnit.Case, async: true
  import Ecto.Changeset

  alias Domain.Resource

  defp build_changeset(attrs) do
    %Resource{}
    |> cast(attrs, [:address, :address_description, :name, :type, :ip_stack, :site_id])
    |> Resource.changeset()
  end

  defp build_changeset_with_address_validation(attrs) do
    account = %Domain.Account{features: %Domain.Accounts.Features{}}

    %Resource{}
    |> cast(attrs, [:address, :address_description, :name, :type, :ip_stack, :site_id])
    |> Resource.changeset()
    |> Resource.validate_address(account)
  end

  describe "changeset/1" do
    test "validates name length maximum" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "accepts valid name length" do
      changeset = build_changeset(%{name: "valid-resource-name"})
      refute Map.has_key?(errors_on(changeset), :name)
    end

    test "validates address_description length maximum" do
      changeset = build_changeset(%{address_description: String.duplicate("a", 513)})
      assert %{address_description: ["should be at most 512 character(s)"]} = errors_on(changeset)
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

      changeset =
        existing
        |> cast(%{type: :ip}, [:type])
        |> Resource.changeset()

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
  end

  describe "validate_address/2" do
    test "rejects DNS address with port number" do
      changeset =
        build_changeset_with_address_validation(%{type: :dns, address: "example.com:8080"})

      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end

    test "rejects IP address with port number" do
      changeset =
        build_changeset_with_address_validation(%{type: :ip, address: "192.168.1.1:8080"})

      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end

    test "rejects bracketed IPv6 with port number" do
      changeset =
        build_changeset_with_address_validation(%{type: :ip, address: "[2001:db8::1]:8080"})

      assert "cannot contain a port number" in errors_on(changeset)[:address]
    end

    test "accepts DNS address without port" do
      changeset = build_changeset_with_address_validation(%{type: :dns, address: "example.com"})
      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "accepts IPv6 address (multiple colons)" do
      changeset = build_changeset_with_address_validation(%{type: :ip, address: "2001:db8::1"})
      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "accepts full IPv6 address" do
      changeset =
        build_changeset_with_address_validation(%{
          type: :ip,
          address: "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
        })

      refute Map.has_key?(errors_on(changeset), :address)
    end

    test "rejects CIDR with malformed opening bracket" do
      changeset = build_changeset_with_address_validation(%{type: :cidr, address: "[fe00::/1"})
      assert "has mismatched brackets" in errors_on(changeset)[:address]
    end

    test "rejects IP with malformed closing bracket" do
      changeset = build_changeset_with_address_validation(%{type: :ip, address: "fe00::]/1"})
      assert "has mismatched brackets" in errors_on(changeset)[:address]
    end

    test "accepts properly bracketed IPv6" do
      changeset = build_changeset_with_address_validation(%{type: :ip, address: "[2001:db8::1]"})
      errors = errors_on(changeset)
      refute "has mismatched brackets" in Map.get(errors, :address, [])
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
