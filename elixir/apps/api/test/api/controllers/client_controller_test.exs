defmodule API.ClientControllerTest do
  use API.ConnCase, async: true
  alias Domain.Client

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.ClientFixtures
  import Domain.SubjectFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    client = client_fixture(account: account)
    subject = subject_fixture(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      client: client,
      subject: subject
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = get(conn, ~p"/clients/#{client}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "lists all clients", %{
      conn: conn,
      actor: actor,
      client: client,
      account: account
    } do
      clients =
        for _ <- 1..3,
            do: client_fixture(account: account)

      clients = [client | clients]

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients")

      assert %{
               "data" => data,
               "metadata" => %{
                 "count" => count,
                 "limit" => limit,
                 "next_page" => next_page,
                 "prev_page" => prev_page
               }
             } = json_response(conn, 200)

      # client was created in setup
      assert count == 4
      assert limit == 50
      assert is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"])
      client_ids = Enum.map(clients, & &1.id)

      assert equal_ids?(data_ids, client_ids)
    end

    test "lists clients with limit", %{
      conn: conn,
      actor: actor,
      client: client,
      account: account
    } do
      clients =
        for _ <- 1..3,
            do: client_fixture(account: account)

      clients = [client | clients]

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", limit: "2")

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
      # client was created in setup
      assert count == 4
      refute is_nil(next_page)
      assert is_nil(prev_page)

      data_ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      client_ids = Enum.map(clients, & &1.id) |> MapSet.new()

      assert MapSet.subset?(data_ids, client_ids)
    end
  end

  describe "show/2" do
    test "returns error when not authorized", %{
      conn: conn,
      client: client
    } do
      conn = get(conn, ~p"/clients/#{client.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns a single client", %{
      conn: conn,
      actor: actor,
      client: client
    } do
      client = %{client | online?: false}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients/#{client.id}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => client.id,
                 "name" => client.name,
                 "ipv4" => to_string(client.ipv4_address.address),
                 "ipv6" => to_string(client.ipv6_address.address),
                 "actor_id" => client.actor_id,
                 "created_at" => client.inserted_at && DateTime.to_iso8601(client.inserted_at),
                 "device_serial" => client.device_serial,
                 "device_uuid" => client.device_uuid,
                 "external_id" => client.external_id,
                 "firebase_installation_id" => client.firebase_installation_id,
                 "identifier_for_vendor" => client.identifier_for_vendor,
                 "last_seen_at" =>
                   client.last_seen_at && DateTime.to_iso8601(client.last_seen_at),
                 "last_seen_remote_ip" => "#{client.last_seen_remote_ip}",
                 "last_seen_remote_ip_location_city" => client.last_seen_remote_ip_location_city,
                 "last_seen_remote_ip_location_lat" => client.last_seen_remote_ip_location_lat,
                 "last_seen_remote_ip_location_lon" => client.last_seen_remote_ip_location_lon,
                 "last_seen_remote_ip_location_region" =>
                   client.last_seen_remote_ip_location_region,
                 "last_seen_user_agent" => client.last_seen_user_agent,
                 "last_seen_version" => client.last_seen_version,
                 "online" => client.online?,
                 "updated_at" => client.updated_at && DateTime.to_iso8601(client.updated_at),
                 "verified_at" => client.verified_at && DateTime.to_iso8601(client.verified_at)
               }
             }
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = put(conn, ~p"/clients/#{client}", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor, client: client} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}")

      assert resp = json_response(conn, 400)
      assert resp == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "updates a client", %{conn: conn, actor: actor, client: client} do
      attrs = %{"name" => "Updated Client"}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}", client: attrs)

      assert resp = json_response(conn, 200)

      assert resp["data"]["id"] == client.id
      assert resp["data"]["name"] == attrs["name"]
    end
  end

  describe "verify/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = put(conn, ~p"/clients/#{client}/verify", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "verifies a client", %{conn: conn, actor: actor, client: client} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}/verify")

      assert resp = json_response(conn, 200)

      assert resp["data"]["id"] == client.id
      assert resp["data"]["verified_at"]
    end
  end

  describe "unverify/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = put(conn, ~p"/clients/#{client}/verify", %{})
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "unverifies a client", %{conn: conn, actor: actor, client: client} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}/unverify")

      assert resp = json_response(conn, 200)

      assert resp["data"]["id"] == client.id
      refute resp["data"]["verified_at"]
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{
      conn: conn,
      client: client
    } do
      conn = delete(conn, ~p"/clients/#{client.id}")
      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "deletes a client", %{
      conn: conn,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/clients/#{client}")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => client.id,
                 "name" => client.name,
                 "ipv4" => to_string(client.ipv4_address.address),
                 "ipv6" => to_string(client.ipv6_address.address),
                 "actor_id" => client.actor_id,
                 "created_at" => client.inserted_at && DateTime.to_iso8601(client.inserted_at),
                 "device_serial" => client.device_serial,
                 "device_uuid" => client.device_uuid,
                 "external_id" => client.external_id,
                 "firebase_installation_id" => client.firebase_installation_id,
                 "identifier_for_vendor" => client.identifier_for_vendor,
                 "last_seen_at" =>
                   client.last_seen_at && DateTime.to_iso8601(client.last_seen_at),
                 "last_seen_remote_ip" => "#{client.last_seen_remote_ip}",
                 "last_seen_remote_ip_location_city" => client.last_seen_remote_ip_location_city,
                 "last_seen_remote_ip_location_lat" => client.last_seen_remote_ip_location_lat,
                 "last_seen_remote_ip_location_lon" => client.last_seen_remote_ip_location_lon,
                 "last_seen_remote_ip_location_region" =>
                   client.last_seen_remote_ip_location_region,
                 "last_seen_user_agent" => client.last_seen_user_agent,
                 "last_seen_version" => client.last_seen_version,
                 "online" => false,
                 "updated_at" => client.updated_at && DateTime.to_iso8601(client.updated_at),
                 "verified_at" => client.verified_at && DateTime.to_iso8601(client.verified_at)
               }
             }

      refute Repo.get_by(Client, id: client.id, account_id: client.account_id)
    end
  end
end
