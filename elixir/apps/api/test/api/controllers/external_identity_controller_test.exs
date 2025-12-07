defmodule API.IdentityControllerTest do
  use API.ConnCase, async: true

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.IdentityFixtures
  import Domain.DirectoryFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, actor: actor} do
      conn = get(conn, "/actors/#{actor.id}/external_identities")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all identities for actor", %{conn: conn, account: account, actor: actor} do
      identities =
        for _ <- 1..3, do: identity_fixture(account: account, actor: actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{actor.id}/external_identities")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert count == 3
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"])
      identity_ids = Enum.map(identities, & &1.id)

      assert equal_ids?(data_ids, identity_ids)
    end

    test "lists identities with limit", %{conn: conn, account: account, actor: actor} do
      identities =
        for _ <- 1..3,
            do:
              synced_identity_fixture(
                account: account,
                actor: actor,
                email: "testuser@example.com"
              )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{actor.id}/external_identities", limit: "2")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      assert limit == 2
      assert count == 3
      refute is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      identity_ids = Enum.map(identities, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, identity_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{conn: conn, account: account, actor: actor} do
      identity = identity_fixture(account: account, actor: actor)
      conn = get(conn, "/actors/#{actor.id}/external_identities/#{identity.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single identity with populated email field", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      directory = google_directory_fixture(account: account)

      identity =
        synced_identity_fixture(%{
          account: account,
          directory: directory,
          actor: actor,
          idp_id: "172836495673"
        })

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/actors/#{actor.id}/external_identities/#{identity.id}")

      assert %{"data" => data} = json_response(conn, 200)

      assert data["id"] == identity.id
      assert data["actor_id"] == actor.id
      assert data["account_id"] == identity.account_id
      assert data["directory_id"] == directory.id
      assert data["idp_id"] == identity.idp_id
      assert data["email"] == identity.email
      assert data["issuer"] == identity.issuer
      assert data["name"] == identity.name
      assert data["given_name"] == identity.given_name
      assert data["family_name"] == identity.family_name
      assert data["middle_name"] == identity.middle_name
      assert data["nickname"] == identity.nickname
      assert data["preferred_username"] == identity.preferred_username
      assert data["profile"] == identity.profile
      assert data["picture"] == identity.picture
      assert data["firezone_avatar_url"] == identity.firezone_avatar_url

      assert data["last_synced_at"] ==
               identity.last_synced_at |> DateTime.to_iso8601()

      assert data["inserted_at"] ==
               identity.inserted_at
               |> DateTime.from_naive!("Etc/UTC")
               |> DateTime.to_iso8601()
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{conn: conn, account: account, actor: actor} do
      identity = synced_identity_fixture(account: account, actor: actor)
      conn = delete(conn, "/actors/#{actor.id}/external_identities/#{identity.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes an identity", %{conn: conn, account: account, actor: actor} do
      identity = synced_identity_fixture(account: account, actor: actor)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete("/actors/#{actor.id}/external_identities/#{identity.id}")

      assert %{"data" => data} = json_response(conn, 200)

      assert data["id"] == identity.id
      assert data["actor_id"] == actor.id
      assert data["idp_id"] == identity.idp_id
      assert data["email"] == identity.email

      refute Repo.get_by(Domain.ExternalIdentity, id: identity.id)
    end
  end
end
