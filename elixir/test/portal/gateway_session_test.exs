defmodule Portal.GatewaySessionTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.GatewayFixtures
  import Portal.TokenFixtures
  import Portal.GatewaySessionFixtures

  alias Portal.GatewaySession

  describe "changeset/1" do
    test "validates required fields" do
      changeset =
        %GatewaySession{}
        |> Ecto.Changeset.cast(%{}, [])
        |> GatewaySession.changeset()

      assert errors_on(changeset).account_id
      assert errors_on(changeset).gateway_id
      assert errors_on(changeset).gateway_token_id
    end

    test "valid changeset with all required fields" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)

      changeset =
        %GatewaySession{}
        |> Ecto.Changeset.cast(
          %{
            account_id: account.id,
            gateway_id: gateway.id,
            gateway_token_id: token.id,
            user_agent: "Linux/6.1.0 connlib/1.0.0 (x86_64)",
            version: "1.0.0"
          },
          [:account_id, :gateway_id, :gateway_token_id, :user_agent, :version]
        )
        |> GatewaySession.changeset()

      assert changeset.valid?
    end

    test "enforces account association constraint" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(account: account, site: site)

      assert {:error, changeset} =
               %GatewaySession{}
               |> Ecto.Changeset.cast(
                 %{
                   account_id: Ecto.UUID.generate(),
                   gateway_id: gateway.id,
                   gateway_token_id: token.id
                 },
                 [:account_id, :gateway_id, :gateway_token_id]
               )
               |> GatewaySession.changeset()
               |> Repo.insert()

      assert errors_on(changeset).account
    end

    test "enforces gateway association constraint" do
      account = account_fixture()
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      assert {:error, changeset} =
               %GatewaySession{}
               |> Ecto.Changeset.cast(
                 %{
                   account_id: account.id,
                   gateway_id: Ecto.UUID.generate(),
                   gateway_token_id: token.id
                 },
                 [:account_id, :gateway_id, :gateway_token_id]
               )
               |> GatewaySession.changeset()
               |> Repo.insert()

      assert errors_on(changeset).gateway
    end

    test "enforces gateway_token association constraint" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)

      assert {:error, changeset} =
               %GatewaySession{}
               |> Ecto.Changeset.cast(
                 %{
                   account_id: account.id,
                   gateway_id: gateway.id,
                   gateway_token_id: Ecto.UUID.generate()
                 },
                 [:account_id, :gateway_id, :gateway_token_id]
               )
               |> GatewaySession.changeset()
               |> Repo.insert()

      assert errors_on(changeset).gateway_token
    end
  end

  describe "schema" do
    test "creates a session with all fields" do
      session =
        gateway_session_fixture(
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.45,
          remote_ip_location_lon: 30.52
        )

      assert session.id
      assert session.account_id
      assert session.gateway_id
      assert session.gateway_token_id
      assert session.user_agent
      assert session.remote_ip
      assert session.remote_ip_location_region
      assert session.remote_ip_location_city == "Kyiv"
      assert session.remote_ip_location_lat == 50.45
      assert session.remote_ip_location_lon == 30.52
      assert session.version
      assert session.inserted_at
    end

    test "inserted_at is set automatically" do
      session = gateway_session_fixture()
      assert session.inserted_at
    end

    test "session belongs to a gateway" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      session = gateway_session_fixture(account: account, site: site, gateway: gateway)

      assert session.gateway_id == gateway.id
    end

    test "session belongs to a gateway_token" do
      account = account_fixture()
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)
      session = gateway_session_fixture(account: account, site: site, token: token)

      assert session.gateway_token_id == token.id
    end
  end
end
