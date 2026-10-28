defmodule Portal.SlugRegistry.AzureTableTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Plug.Conn
  import Portal.SlugRegistryHelpers

  alias Portal.SlugRegistry

  setup do
    use_azure_registry(:us)
    %{account_id: Ecto.UUID.generate()}
  end

  describe "claim/2" do
    test "inserts the slug with the account and region", %{account_id: account_id} do
      test_pid = self()

      stub_registry(fn
        %{method: "POST", request_path: "/slugs"} = conn ->
          send(test_pid, {:inserted, json_body(conn), get_req_header(conn, "authorization")})
          send_resp(conn, 204, "")
      end)

      assert SlugRegistry.claim("Acme", account_id) == :ok

      assert_received {:inserted, body, ["Bearer registry-token"]}
      assert body["PartitionKey"] == "slug"
      assert body["RowKey"] == "acme"
      assert body["AccountId"] == account_id
      assert body["Region"] == "us"
      assert is_binary(body["InsertedAt"])
    end

    test "succeeds again for a slug the same account holds", %{account_id: account_id} do
      stub_registry(fn
        %{method: "POST"} = conn -> send_resp(conn, 409, "")
        %{method: "GET"} = conn -> Req.Test.json(conn, entity("acme", account_id, "us"))
      end)

      assert SlugRegistry.claim("acme", account_id) == :ok
    end

    test "reports a slug another account holds", %{account_id: account_id} do
      stub_registry(fn
        %{method: "POST"} = conn -> send_resp(conn, 409, "")
        %{method: "GET"} = conn -> Req.Test.json(conn, entity("acme", Ecto.UUID.generate(), "eu"))
      end)

      assert SlugRegistry.claim("acme", account_id) == {:error, :taken}
    end

    test "reports an unavailable registry and logs it", %{account_id: account_id} do
      stub_registry(fn conn -> send_resp(conn, 503, "busy") end)

      log = capture_log(fn -> assert SlugRegistry.claim("acme", account_id) == {:error, :unavailable} end)

      assert log =~ "Slug registry request failed"
    end

    test "reports an unavailable registry when no token can be fetched", %{account_id: account_id} do
      Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn -> send_resp(conn, 500, "") end)
      stub_registry(fn _conn -> :default end)

      log = capture_log(fn -> assert SlugRegistry.claim("acme", account_id) == {:error, :unavailable} end)

      assert log =~ "Slug registry request failed"
    end
  end

  describe "lookup/1" do
    test "returns the owner and region", %{account_id: account_id} do
      stub_registry(fn %{method: "GET"} = conn ->
        assert row_key(conn) == "acme"
        Req.Test.json(conn, entity("acme", account_id, "eu"))
      end)

      assert {:ok, %{slug: "acme", account_id: ^account_id, region: "eu"}} = SlugRegistry.lookup("ACME")
    end

    test "misses an unknown slug" do
      stub_registry(fn _conn -> :default end)

      assert SlugRegistry.lookup("nobody") == :not_found
    end
  end

  describe "release/2" do
    test "deletes a slug the account holds", %{account_id: account_id} do
      test_pid = self()

      stub_registry(fn
        %{method: "GET"} = conn ->
          Req.Test.json(conn, entity("acme", account_id, "us"))

        %{method: "DELETE"} = conn ->
          send(test_pid, {:deleted, row_key(conn), get_req_header(conn, "if-match")})
          send_resp(conn, 204, "")
      end)

      assert SlugRegistry.release("acme", account_id) == :ok
      assert_received {:deleted, "acme", ["*"]}
    end

    test "leaves a slug another account holds", %{account_id: account_id} do
      stub_registry(fn
        %{method: "GET"} = conn -> Req.Test.json(conn, entity("acme", Ecto.UUID.generate(), "us"))
        %{method: "DELETE"} -> flunk("must not delete")
      end)

      assert SlugRegistry.release("acme", account_id) == :ok
    end
  end

  describe "transfer/2" do
    test "merges the new region into every slug of the account", %{account_id: account_id} do
      test_pid = self()

      stub_registry(fn
        %{method: "GET", request_path: "/slugs()"} = conn ->
          assert conn.query_params["$filter"] == "AccountId eq '#{account_id}'"

          Req.Test.json(conn, %{
            "value" => [entity("acme", account_id, "us"), entity("acme-old", account_id, "us")]
          })

        %{method: "POST"} = conn ->
          send(test_pid, {:merged, row_key(conn), get_req_header(conn, "x-http-method"), json_body(conn)})
          send_resp(conn, 204, "")
      end)

      assert SlugRegistry.transfer(account_id, :eu) == {:ok, 2}
      assert_received {:merged, "acme", ["MERGE"], %{"Region" => "eu"}}
      assert_received {:merged, "acme-old", ["MERGE"], %{"Region" => "eu"}}
    end
  end

  describe "list_region/1" do
    test "follows continuation tokens", %{account_id: account_id} do
      stub_registry(fn %{method: "GET", request_path: "/slugs()"} = conn ->
        assert conn.query_params["$filter"] == "Region eq 'us'"

        case conn.query_params["NextRowKey"] do
          nil ->
            conn
            |> put_resp_header("x-ms-continuation-nextpartitionkey", "slug")
            |> put_resp_header("x-ms-continuation-nextrowkey", "beta")
            |> Req.Test.json(%{"value" => [entity("alpha", account_id, "us")]})

          "beta" ->
            Req.Test.json(conn, %{"value" => [entity("beta", account_id, "us")]})
        end
      end)

      assert {:ok, [%{slug: "alpha"}, %{slug: "beta"}]} = SlugRegistry.list_region(:us)
    end
  end
end
