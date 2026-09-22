defmodule Portal.Accounts.ConfigTest do
  use Portal.DataCase, async: true

  alias Portal.Accounts.Config

  defp custom_dns_changeset(count) do
    addresses =
      for i <- 0..(count - 1), into: %{} do
        {Integer.to_string(i), %{"address" => "10.0.0.#{i}"}}
      end

    sort = Enum.map(0..(count - 1), &Integer.to_string/1)

    Config.changeset(%Config{}, %{
      "clients_upstream_dns" => %{
        "type" => "custom",
        "addresses" => addresses,
        "addresses_sort" => sort,
        "addresses_drop" => [""]
      }
    })
  end

  describe "changeset/2 upstream resolver limit" do
    test "accepts up to 8 resolvers" do
      assert custom_dns_changeset(8).valid?
    end

    test "rejects more than 8 resolvers" do
      changeset = custom_dns_changeset(9)

      refute changeset.valid?

      assert %{clients_upstream_dns: %{addresses: ["cannot exceed 8 resolvers"]}} =
               errors_on(changeset)
    end
  end
end
