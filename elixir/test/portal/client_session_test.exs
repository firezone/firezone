defmodule Portal.ClientSessionTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.TokenFixtures
  import Portal.ClientSessionFixtures

  alias Portal.ClientSession

  describe "changeset/1" do
    test "validates required fields" do
      changeset =
        %ClientSession{}
        |> Ecto.Changeset.cast(%{}, [])
        |> ClientSession.changeset()

      assert errors_on(changeset).account_id
      assert errors_on(changeset).client_id
      assert errors_on(changeset).client_token_id
    end

    test "valid changeset with all required fields" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      changeset =
        %ClientSession{}
        |> Ecto.Changeset.cast(
          %{
            account_id: account.id,
            client_id: client.id,
            client_token_id: token.id,
            user_agent: "Test/1.0",
            version: "1.0.0"
          },
          [:account_id, :client_id, :client_token_id, :user_agent, :version]
        )
        |> ClientSession.changeset()

      assert changeset.valid?
    end

    test "enforces account association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor)

      assert {:error, changeset} =
               %ClientSession{}
               |> Ecto.Changeset.cast(
                 %{
                   account_id: Ecto.UUID.generate(),
                   client_id: client.id,
                   client_token_id: token.id
                 },
                 [:account_id, :client_id, :client_token_id]
               )
               |> ClientSession.changeset()
               |> Repo.insert()

      assert errors_on(changeset).account
    end

    test "enforces client association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = client_token_fixture(account: account, actor: actor)

      assert {:error, changeset} =
               %ClientSession{}
               |> Ecto.Changeset.cast(
                 %{
                   account_id: account.id,
                   client_id: Ecto.UUID.generate(),
                   client_token_id: token.id
                 },
                 [:account_id, :client_id, :client_token_id]
               )
               |> ClientSession.changeset()
               |> Repo.insert()

      assert errors_on(changeset).client
    end

    test "enforces client_token association constraint" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      assert {:error, changeset} =
               %ClientSession{}
               |> Ecto.Changeset.cast(
                 %{
                   account_id: account.id,
                   client_id: client.id,
                   client_token_id: Ecto.UUID.generate()
                 },
                 [:account_id, :client_id, :client_token_id]
               )
               |> ClientSession.changeset()
               |> Repo.insert()

      assert errors_on(changeset).client_token
    end
  end

  describe "schema" do
    test "creates a session with all fields" do
      session =
        client_session_fixture(
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.45,
          remote_ip_location_lon: 30.52
        )

      assert session.id
      assert session.account_id
      assert session.client_id
      assert session.client_token_id
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
      session = client_session_fixture()
      assert session.inserted_at
    end

    test "session belongs to a client" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)
      session = client_session_fixture(account: account, actor: actor, client: client)

      assert session.client_id == client.id
    end

    test "session belongs to a client_token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = client_token_fixture(account: account, actor: actor)
      session = client_session_fixture(account: account, actor: actor, token: token)

      assert session.client_token_id == token.id
    end
  end
end
