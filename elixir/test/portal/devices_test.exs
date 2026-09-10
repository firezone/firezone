defmodule Portal.DevicesTest do
  use Portal.DataCase, async: true

  import Ecto.Query

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  alias Portal.Device
  alias Portal.Devices
  alias Portal.GatewayToken

  describe "provision_gateway/3" do
    test "creates a gateway and mints its single-owner token" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject =
        subject_fixture(account: account, actor: %{type: :api_client, account: account})

      assert {:ok, %Device{} = gateway, %GatewayToken{} = token, encoded_token} =
               Devices.provision_gateway(site, "edge-nyc-1", subject)

      assert gateway.name == "edge-nyc-1"
      assert gateway.site_id == site.id
      assert gateway.account_id == site.account_id
      assert gateway.type == :gateway

      assert token.device_id == gateway.id
      assert is_nil(token.site_id)
      # secret_fragment is scrubbed - only the encoded token carries the secret.
      assert is_nil(token.secret_fragment)
      assert is_binary(encoded_token)
    end

    # Regression: the Device insert and the GatewayToken insert are
    # authorized separately - Safe.permit/3 lets an account_user insert a
    # Device (clients create their own row on first connect) but not a
    # GatewayToken. Before both writes shared a transaction, the Device
    # was committed and then the token insert returned :unauthorized,
    # leaving a tokenless Gateway behind while the caller saw a 401.
    test "leaves no gateway behind when the caller cannot mint a token" do
      account = account_fixture()
      site = site_fixture(account: account)

      subject =
        subject_fixture(account: account, actor: %{type: :account_user, account: account})

      assert {:error, :unauthorized} = Devices.provision_gateway(site, "orphan-gw", subject)

      assert Repo.aggregate(
               from(d in Device, where: d.site_id == ^site.id and d.type == :gateway),
               :count
             ) == 0

      assert Repo.aggregate(
               from(t in GatewayToken, where: t.account_id == ^account.id),
               :count
             ) == 0
    end

    test "generates a random name when none is given" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject =
        subject_fixture(account: account, actor: %{type: :api_client, account: account})

      assert {:ok, %Device{name: name}, _token, _encoded_token} =
               Devices.provision_gateway(site, nil, subject)

      refute is_nil(name)
      refute name == ""
    end
  end

  describe "next_free_slug/3" do
    setup do
      %{account: account_fixture()}
    end

    test "slugs the device name", %{account: account} do
      assert Devices.next_free_slug(account.id, "Jamil's MacBook Pro", nil) == "jamils-macbook-pro"
      assert Devices.next_free_slug(account.id, "Pixel 8", nil) == "pixel-8"
      assert Devices.next_free_slug(account.id, "DESKTOP-ABC123", nil) == "desktop-abc123"
    end

    test "keeps only the part before the first dot", %{account: account} do
      assert Devices.next_free_slug(account.id, "Jamils-MacBook-Pro.local", nil) ==
               "jamils-macbook-pro"
    end

    test "drops curly apostrophes and non-ASCII letters", %{account: account} do
      assert Devices.next_free_slug(account.id, "Zoë’s iPhone", nil) == "zo-s-iphone"
    end

    test "collapses runs of separators and trims the ends", %{account: account} do
      assert Devices.next_free_slug(account.id, "  --my__laptop!! ", nil) == "my-laptop"
    end

    test "falls back to device when nothing is left", %{account: account} do
      assert Devices.next_free_slug(account.id, "***", nil) == "device"
    end

    test "puts the owner's first name in front of stock names", %{account: account} do
      assert Devices.next_free_slug(account.id, "iPhone", "Jamil Bou Kheir") == "jamils-iphone"
      assert Devices.next_free_slug(account.id, "DESKTOP-ABC123", "Jamil") == "jamils-desktop-abc123"
      assert Devices.next_free_slug(account.id, "iPad", "jamil@firezone.dev") == "jamils-ipad"
      assert Devices.next_free_slug(account.id, "iPhone", "James Smith") == "james-iphone"
      assert Devices.next_free_slug(account.id, "***", "Jamil") == "jamils-device"
    end

    test "leaves names that already carry the owner's name alone", %{account: account} do
      assert Devices.next_free_slug(account.id, "Jamil's MacBook Pro", "Jamil Bou Kheir") ==
               "jamils-macbook-pro"

      assert Devices.next_free_slug(account.id, "Jamils-MacBook-Pro.local", "Jamil") ==
               "jamils-macbook-pro"

      assert Devices.next_free_slug(account.id, "jamil-laptop", "Jamil") == "jamil-laptop"
      assert Devices.next_free_slug(account.id, "Samsung Galaxy", "Sam") == "sams-samsung-galaxy"
    end

    test "ignores an owner name that leaves no label", %{account: account} do
      assert Devices.next_free_slug(account.id, "iPhone", "***") == "iphone"
      assert Devices.next_free_slug(account.id, "iPhone", "") == "iphone"
    end

    test "numbers a slug another device in the account holds", %{account: account} do
      actor = actor_fixture(account: account, name: "Jamil Bou Kheir")
      client_fixture(account: account, actor: actor, name: "iPhone")
      client_fixture(account: account, actor: actor, name: "iPhone")

      assert Devices.next_free_slug(account.id, "iPhone", "Jamil Bou Kheir") == "jamils-iphone-3"
      assert Devices.next_free_slug(account_fixture().id, "iPhone", "Jamil") == "jamils-iphone"
    end

    test "caps the slug at 63 characters, numbers included", %{account: account} do
      name = String.duplicate("a", 70)
      assert String.length(Devices.next_free_slug(account.id, name, nil)) == 63

      client_fixture(account: account, name: name, slug: Devices.next_free_slug(account.id, name, nil))
      numbered = Devices.next_free_slug(account.id, name, nil)

      assert String.length(numbered) == 63
      assert String.ends_with?(numbered, "-2")
    end
  end

  describe "owner_name/1" do
    test "is the name of people and nothing for service accounts" do
      assert Devices.owner_name(%Portal.Actor{type: :account_user, name: "Jamil"}) == "Jamil"
      assert Devices.owner_name(%Portal.Actor{type: :account_admin_user, name: "Jamil"}) == "Jamil"
      assert is_nil(Devices.owner_name(%Portal.Actor{type: :service_account, name: "CI"}))
      assert is_nil(Devices.owner_name(nil))
    end
  end
end
