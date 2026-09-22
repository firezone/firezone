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

  describe "meters" do
    test "defaults to the flow-log error meters" do
      assert %Config{}.meters == [
               "flow_logs.config.errors",
               "flow_logs.token.errors",
               "flow_logs.report.errors"
             ]

      assert Config.default_meters() == %Config{}.meters
      assert Config.default_config().meters == %Config{}.meters
      assert Config.ensure_defaults(nil).meters == %Config{}.meters
    end

    test "falls back to the default when the stored JSON has no meters key" do
      config = Ecto.embedded_load(Config, %{"search_domain" => "example.com"}, :json)

      assert config.meters == Config.default_meters()
      assert Config.ensure_defaults(config).meters == Config.default_meters()
    end

    test "is not castable, so account admins cannot set it" do
      changeset = Config.changeset(%Config{}, %{"meters" => ["evil.meter"]})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :meters)
      assert Ecto.Changeset.apply_changes(changeset).meters == Config.default_meters()

      config = %Config{meters: ["ops.meter"]}

      assert Config.changeset(config, %{"meters" => ["evil.meter"]})
             |> Ecto.Changeset.apply_changes()
             |> Map.fetch!(:meters) == ["ops.meter"]
    end
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
