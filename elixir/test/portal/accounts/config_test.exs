defmodule Portal.Accounts.ConfigTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures

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

  describe "changeset/2 aes_gcm" do
    test "defaults to false" do
      assert %Config{}.aes_gcm == false
      assert Config.default_config().aes_gcm == false
    end

    test "casts the opt-in" do
      changeset = Config.changeset(%Config{}, %{"aes_gcm" => "true"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :aes_gcm) == true
    end

    test "leaves the opt-in untouched when not given" do
      changeset = Config.changeset(%Config{aes_gcm: true}, %{"search_domain" => "example.com"})

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).aes_gcm == true
    end

    test "reads as false for configs stored before the field existed" do
      account = account_fixture()

      Portal.Repo.query!(
        "UPDATE accounts SET config = config - 'aes_gcm' WHERE id = $1",
        [Ecto.UUID.dump!(account.id)]
      )

      account = Portal.Repo.get!(Portal.Account, account.id)
      assert account.config.aes_gcm == false
      refute Portal.Account.aes_gcm_opted_in?(account)
    end
  end
end
