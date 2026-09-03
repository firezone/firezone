defmodule PortalAPI.ClientControllerTest do
  use PortalAPI.ConnCase, async: true
  alias Portal.Device

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SubjectFixtures

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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error for invalid page cursor", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", page_cursor: "not-a-valid-cursor")

      assert %{"type" => "about:blank", "status" => 400, "detail" => "Invalid page cursor"} =
               json_response(conn, 400)
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

    test "filters by name", %{conn: conn, actor: actor, account: account} do
      match = client_fixture(account: account, name: "jane-laptop")
      _other = client_fixture(account: account, name: "field-tablet")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", name: "jane-laptop")

      assert %{"data" => [data], "metadata" => %{"count" => 1}} = json_response(conn, 200)
      assert data["id"] == match.id
    end

    test "filters by firezone_id", %{conn: conn, actor: actor, account: account} do
      match = client_fixture(account: account, firezone_id: "client_filter_target")
      _other = client_fixture(account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", firezone_id: "client_filter_target")

      assert %{"data" => [data], "metadata" => %{"count" => 1}} = json_response(conn, 200)
      assert data["id"] == match.id
      assert data["firezone_id"] == "client_filter_target"
    end

    test "combines name and firezone_id filters", %{conn: conn, actor: actor, account: account} do
      match = client_fixture(account: account, name: "shared-name", firezone_id: "client_a")
      _same_name = client_fixture(account: account, name: "shared-name", firezone_id: "client_b")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", name: "shared-name", firezone_id: "client_a")

      assert %{"data" => [data], "metadata" => %{"count" => 1}} = json_response(conn, 200)
      assert data["id"] == match.id
    end

    test "returns an empty list when nothing matches", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      _client = client_fixture(account: account, name: "jane-laptop")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", name: "nonexistent")

      assert %{"data" => [], "metadata" => %{"count" => 0}} = json_response(conn, 200)
    end

    test "does not match a Client in another account", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      _local = client_fixture(account: account, name: "unique-here")
      other = client_fixture(account: account_fixture(), name: "unique-here")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", name: "unique-here")

      assert %{"data" => [data]} = json_response(conn, 200)
      refute data["id"] == other.id
    end

    test "does not match a Gateway sharing a firezone_id", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      site = Portal.SiteFixtures.site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site, firezone_id: "shared_fz_id")
      client = client_fixture(account: account, firezone_id: "shared_fz_id")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", firezone_id: "shared_fz_id")

      assert %{"data" => [data], "metadata" => %{"count" => 1}} = json_response(conn, 200)
      assert data["id"] == client.id
      refute data["id"] == gateway.id
    end

    # coerce_filters/1 only reads the parameters it knows about, so an
    # unrecognized one is ignored rather than erroring - matching every
    # other filtered index in this API.
    test "rejects an unrecognized query parameter", %{conn: conn, actor: actor, account: account} do
      client_fixture(account: account, name: "jane-laptop")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients", name: "jane-laptop", nope: "value")

      assert %{"status" => 400, "detail" => detail} = json_response(conn, 400)
      assert detail =~ "`nope` is not a known parameter"
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
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns a single client", %{
      conn: conn,
      actor: actor,
      client: client
    } do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients/#{client.id}")

      assert %{"data" => data} = json_response(conn, 200)

      assert data["id"] == client.id
      assert data["name"] == client.name
      assert data["ipv4"] == to_string(client.ipv4)
      assert data["ipv6"] == to_string(client.ipv6)
      assert data["actor_id"] == client.actor_id
      assert data["firezone_id"] == client.firezone_id
      assert data["online"] == false
      assert Map.has_key?(data, "hostname")
    end

    test "renders a null firezone_id for an attested client", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      # An attested client has no self-reported id to render, so the published
      # schema has to allow null here or every such response breaks the contract.
      client = client_fixture(account: account, actor: actor_fixture(account: account))
      Portal.Repo.update_all(Portal.Device, set: [firezone_id: nil])

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients/#{client.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert Map.has_key?(data, "firezone_id")
      assert is_nil(data["firezone_id"])

      assert %OpenApiSpex.Schema{nullable: true} =
               PortalAPI.Schemas.Client.GetSchema.schema().properties.firezone_id
    end

    test "renders device trust fields", %{conn: conn, actor: actor, account: account} do
      client_actor = actor_fixture(account: account)
      attested_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      client =
        client_fixture(
          account: account,
          actor: client_actor,
          last_attested_device_serial: "SN-ATT-1",
          last_attested_device_uuid: "7A461FF9-0BE2-64A9-A418-539D9A21827B",
          last_attested_mdm_device_id: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
          last_attested_cert_serial: "4A:2F:00:8C",
          last_attested_cert_fingerprint: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
          last_attested_at: attested_at
        )

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients/#{client.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["last_attested_device_serial"] == "SN-ATT-1"
      assert data["last_attested_device_uuid"] == "7A461FF9-0BE2-64A9-A418-539D9A21827B"
      assert data["last_attested_mdm_device_id"] == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
      assert data["last_attested_cert_serial"] == "4A:2F:00:8C"
      assert data["last_attested_cert_fingerprint"] ==
               "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

      assert data["last_attested_at"] == DateTime.to_iso8601(attested_at)
    end

    test "renders hostname when set", %{conn: conn, actor: actor, account: account} do
      client = client_fixture(account: account, actor: actor, hostname: "host.example.com")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients/#{client.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["hostname"] == "host.example.com"
    end

    test "returns not found for non-existent client", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get(~p"/clients/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "update/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = put(conn, ~p"/clients/#{client}", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns error on empty params/body", %{conn: conn, actor: actor, client: client} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
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

    test "returns validation error for an invalid update", %{
      conn: conn,
      actor: actor,
      client: client
    } do
      attrs = %{"name" => String.duplicate("a", 256)}

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}", client: attrs)

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "name")
    end

    test "ignores hostname in the update body", %{
      conn: conn,
      actor: actor,
      account: account
    } do
      client = client_fixture(account: account, actor: actor, hostname: "host.example.com")

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{client}",
          client: %{"name" => "Renamed", "hostname" => "attacker.example.com"}
        )

      assert resp = json_response(conn, 200)
      assert resp["data"]["name"] == "Renamed"
      assert resp["data"]["hostname"] == "host.example.com"
    end

    test "returns not found for non-existent client", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{Ecto.UUID.generate()}", client: %{"name" => "Nope"})

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "verify/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = put(conn, ~p"/clients/#{client}/verify", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

    test "returns not found for non-existent client", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{Ecto.UUID.generate()}/verify")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "unverify/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = put(conn, ~p"/clients/#{client}/verify", %{})
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

    test "returns not found for non-existent client", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/clients/#{Ecto.UUID.generate()}/unverify")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end

  describe "delete/2" do
    test "returns error when not authorized", %{
      conn: conn,
      client: client
    } do
      conn = delete(conn, ~p"/clients/#{client.id}")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
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

      assert %{"data" => data} = json_response(conn, 200)

      assert data["id"] == client.id
      assert data["name"] == client.name
      assert data["online"] == false

      refute Repo.get_by(Device, id: client.id, account_id: client.account_id)
    end

    test "returns not found for non-existent client", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/clients/#{Ecto.UUID.generate()}")

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end
  end
end
