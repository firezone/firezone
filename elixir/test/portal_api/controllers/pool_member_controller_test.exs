defmodule PortalAPI.PoolMemberControllerTest do
  use PortalAPI.ConnCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.ResourceFixtures

  alias Portal.StaticDevicePoolMember

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  defp member_ids(resource) do
    Repo.all(
      from(m in StaticDevicePoolMember,
        where: m.resource_id == ^resource.id,
        select: m.device_id
      )
    )
    |> Enum.sort()
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      pool = static_device_pool_resource_fixture(account: account)
      conn = get(conn, "/resources/#{pool.id}/pool_members")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists the pool's clients", %{conn: conn, account: account, actor: api_actor} do
      client1 = client_fixture(account: account)
      client2 = client_fixture(account: account)
      _unrelated = client_fixture(account: account)

      pool = static_device_pool_resource_fixture(account: account, devices: [client1, client2])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{pool.id}/pool_members")

      assert %{"data" => data, "metadata" => %{"count" => 2}} = json_response(conn, 200)
      assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([client1.id, client2.id])
    end

    test "returns an empty list for a pool with no members", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{pool.id}/pool_members")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "rejects a Resource that is not a device pool", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      resource = resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{resource.id}/pool_members")

      assert %{"status" => 400, "detail" => detail} = json_response(conn, 400)
      assert detail =~ "has no pool members"
    end

    test "returns not found for an unknown Resource", %{conn: conn, actor: api_actor} do
      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{Ecto.UUID.generate()}/pool_members")

      assert json_response(conn, 404)
    end

    test "does not list members of another account's pool", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      other_account = account_fixture()
      other_client = client_fixture(account: other_account)

      other_pool =
        static_device_pool_resource_fixture(account: other_account, devices: [other_client])

      _local_pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/resources/#{other_pool.id}/pool_members")

      assert json_response(conn, 404)
    end
  end

  describe "update_put/2" do
    test "replaces the pool's membership", %{conn: conn, account: account, actor: api_actor} do
      keep = client_fixture(account: account)
      drop = client_fixture(account: account)
      add = client_fixture(account: account)

      pool = static_device_pool_resource_fixture(account: account, devices: [keep, drop])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members",
          pool_members: [%{"device_id" => keep.id}, %{"device_id" => add.id}]
        )

      assert %{"data" => %{"device_ids" => device_ids}} = json_response(conn, 200)
      assert Enum.sort(device_ids) == Enum.sort([keep.id, add.id])
      assert member_ids(pool) == Enum.sort([keep.id, add.id])
    end

    test "an empty list clears the pool", %{conn: conn, account: account, actor: api_actor} do
      client = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [client])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members", pool_members: [])

      assert %{"data" => %{"device_ids" => []}} = json_response(conn, 200)
      assert member_ids(pool) == []
    end

    test "keeps the membership row for a client that stays", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      keep = client_fixture(account: account)
      add = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [keep])

      original_row_id =
        Repo.one!(
          from(m in StaticDevicePoolMember,
            where: m.resource_id == ^pool.id and m.device_id == ^keep.id,
            select: m.id
          )
        )

      conn
      |> authorize_conn(api_actor)
      |> put_req_header("content-type", "application/json")
      |> put("/resources/#{pool.id}/pool_members",
        pool_members: [%{"device_id" => keep.id}, %{"device_id" => add.id}]
      )
      |> json_response(200)

      # An unchanged member must not be deleted and reinserted - that
      # would churn the replication stream the data plane consumes.
      assert Repo.one!(
               from(m in StaticDevicePoolMember,
                 where: m.resource_id == ^pool.id and m.device_id == ^keep.id,
                 select: m.id
               )
             ) == original_row_id
    end

    # Regression: malformed entries used to be dropped silently. A body
    # where every entry was malformed looked like an empty list, so a
    # typo cleared the pool and returned 200.
    test "rejects a malformed entry instead of dropping it", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      keep = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [keep])

      for {label, body} <- [
            {"entry with no device_id", [%{}]},
            {"non-string device_id", [%{"device_id" => 123}]},
            {"one good entry and one malformed", [%{"device_id" => keep.id}, %{}]}
          ] do
        request_conn =
          conn
          |> recycle()
          |> authorize_conn(api_actor)
          |> put_req_header("content-type", "application/json")
          |> put("/resources/#{pool.id}/pool_members", pool_members: body)

        assert resp = json_response(request_conn, 422), "#{label} was accepted"
        assert map_size(resp["validation_errors"]) > 0, label
      end

      # The pool is untouched by every one of those.
      assert member_ids(pool) == [keep.id]
    end

    # The legitimate way to clear a pool still works - the distinction is
    # between "no members" and "members I could not read".
    test "an explicitly empty list still clears the pool", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      client = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [client])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members", pool_members: [])

      assert %{"data" => %{"device_ids" => []}} = json_response(conn, 200)
      assert member_ids(pool) == []
    end

    test "rejects an unknown device id", %{conn: conn, account: account, actor: api_actor} do
      pool = static_device_pool_resource_fixture(account: account)
      unknown = Ecto.UUID.generate()

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members",
          pool_members: [%{"device_id" => unknown}]
        )

      assert %{"status" => 422, "validation_errors" => errors} = json_response(conn, 422)
      assert [message] = errors["pool_members"]
      assert message =~ unknown
      assert member_ids(pool) == []
    end

    test "rejects a gateway device id", %{conn: conn, account: account, actor: api_actor} do
      site = Portal.SiteFixtures.site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members",
          pool_members: [%{"device_id" => gateway.id}]
        )

      assert %{"status" => 422} = json_response(conn, 422)
      assert member_ids(pool) == []
    end

    test "rejects a client from another account", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      other_client = client_fixture(account: account_fixture())
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members",
          pool_members: [%{"device_id" => other_client.id}]
        )

      assert %{"status" => 422} = json_response(conn, 422)
      assert member_ids(pool) == []
    end

    test "rejects a Resource that is not a device pool", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      resource = resource_fixture(account: account)
      client = client_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{resource.id}/pool_members",
          pool_members: [%{"device_id" => client.id}]
        )

      assert %{"status" => 400} = json_response(conn, 400)
    end

    test "returns bad request when pool_members is missing", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/resources/#{pool.id}/pool_members", %{})

      assert %{"status" => 400} = json_response(conn, 400)
    end
  end

  describe "update_patch/2" do
    test "adds and removes without disturbing other members", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      keep = client_fixture(account: account)
      drop = client_fixture(account: account)
      add = client_fixture(account: account)

      pool = static_device_pool_resource_fixture(account: account, devices: [keep, drop])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members",
          pool_members: %{"add" => [add.id], "remove" => [drop.id]}
        )

      assert %{"data" => %{"device_ids" => device_ids}} = json_response(conn, 200)
      assert Enum.sort(device_ids) == Enum.sort([keep.id, add.id])
      assert member_ids(pool) == Enum.sort([keep.id, add.id])
    end

    test "adding an existing member is a no-op", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      client = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [client])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members", pool_members: %{"add" => [client.id]})

      assert %{"data" => %{"device_ids" => [id]}} = json_response(conn, 200)
      assert id == client.id
      assert member_ids(pool) == [client.id]
    end

    test "removing a non-member is a no-op", %{conn: conn, account: account, actor: api_actor} do
      member = client_fixture(account: account)
      stranger = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [member])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members", pool_members: %{"remove" => [stranger.id]})

      assert %{"data" => %{"device_ids" => [id]}} = json_response(conn, 200)
      assert id == member.id
      assert member_ids(pool) == [member.id]
    end

    test "a client in both add and remove ends up in the pool", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      client = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members",
          pool_members: %{"add" => [client.id], "remove" => [client.id]}
        )

      assert %{"data" => %{"device_ids" => [id]}} = json_response(conn, 200)
      assert id == client.id
      assert member_ids(pool) == [client.id]
    end

    test "an empty body leaves the pool unchanged", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      client = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [client])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members", pool_members: %{})

      assert %{"data" => %{"device_ids" => [id]}} = json_response(conn, 200)
      assert id == client.id
    end

    test "rejects an unknown device id in add", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      member = client_fixture(account: account)
      pool = static_device_pool_resource_fixture(account: account, devices: [member])

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members",
          pool_members: %{"add" => [Ecto.UUID.generate()]}
        )

      assert %{"status" => 422} = json_response(conn, 422)
      assert member_ids(pool) == [member.id]
    end

    # Regression: only "add" was validated, so a non-binary in "remove"
    # reached the delete query and raised Ecto.Query.CastError - a 500 for
    # a malformed request.
    for field <- ["add", "remove"] do
      @field field

      test "rejects a non-string id in #{field}", %{
        conn: conn,
        account: account,
        actor: api_actor
      } do
        member = client_fixture(account: account)
        pool = static_device_pool_resource_fixture(account: account, devices: [member])

        conn =
          conn
          |> authorize_conn(api_actor)
          |> put_req_header("content-type", "application/json")
          |> patch("/resources/#{pool.id}/pool_members", pool_members: %{@field => [123]})

        assert resp = json_response(conn, 422)
        assert Map.has_key?(resp["validation_errors"], @field)
        assert member_ids(pool) == [member.id]
      end
    end

    test "returns bad request when pool_members is a list", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      pool = static_device_pool_resource_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/resources/#{pool.id}/pool_members", pool_members: [])

      assert %{"status" => 400} = json_response(conn, 400)
    end
  end
end
