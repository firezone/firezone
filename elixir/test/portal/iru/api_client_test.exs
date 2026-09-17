defmodule Portal.Iru.APIClientTest do
  use ExUnit.Case, async: true

  alias Portal.Iru.APIClient

  setup do
    %{client: APIClient.new("test", :us, "test-token")}
  end

  test "Prism follows opaque cursors even after short pages", %{client: client} do
    cursor = "opaque+/token=="
    first = [%{"device_id" => "first"}]
    last = [%{"device_id" => "last"}]

    Req.Test.expect(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/api/v1/prism/device_information"
      assert conn.query_params == %{"limit" => "300"}
      Req.Test.json(conn, %{"data" => first, "cursor" => cursor})
    end)

    Req.Test.expect(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"limit" => "300", "cursor" => cursor}
      Req.Test.json(conn, %{"data" => last, "cursor" => nil})
    end)

    assert Enum.to_list(APIClient.stream_prism(client, "device_information")) == [first, last]
  end

  test "Prism stops on a full page without a next cursor", %{client: client} do
    rows = for i <- 1..300, do: %{"device_id" => "device-#{i}"}

    for terminal <- [%{"cursor" => nil}, %{"cursor" => ""}, %{}] do
      Req.Test.expect(APIClient, fn conn ->
        Req.Test.json(conn, Map.put(terminal, "data", rows))
      end)

      assert Enum.to_list(APIClient.stream_prism(client, "filevault")) == [rows]
    end
  end

  test "Prism emits an error and stops if a later page fails", %{client: client} do
    Req.Test.expect(APIClient, fn conn ->
      Req.Test.json(conn, %{"data" => [%{"device_id" => "first"}], "cursor" => "next"})
    end)

    Req.Test.expect(APIClient, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"detail" => "invalid cursor"})
    end)

    assert [[%{"device_id" => "first"}], {:error, %Req.Response{status: 400}}] =
             Enum.to_list(APIClient.stream_prism(client, "filevault"))
  end

  test "Prism rejects malformed responses", %{client: client} do
    for body <- [%{}, %{"data" => nil}, %{"data" => [], "cursor" => 123}] do
      Req.Test.expect(APIClient, &Req.Test.json(&1, body))
      assert [{:error, _}] = Enum.to_list(APIClient.stream_prism(client, "filevault"))
    end
  end

  test "device lists continue using offsets", %{client: client} do
    rows = for i <- 1..300, do: %{"device_id" => "device-#{i}"}

    Req.Test.expect(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"limit" => "300", "offset" => "0"}
      Req.Test.json(conn, rows)
    end)

    Req.Test.expect(APIClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"limit" => "300", "offset" => "300"}
      Req.Test.json(conn, [])
    end)

    assert Enum.to_list(APIClient.stream_devices(client)) == [rows, []]
  end
end
