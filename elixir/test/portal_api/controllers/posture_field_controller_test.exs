defmodule PortalAPI.PostureFieldControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Policies.Postures.Fields

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn} do
      conn = get(conn, ~p"/posture_fields")

      assert %{"status" => 401, "title" => "Unauthorized"} = json_response(conn, 401)
    end

    test "lists every field in the registry", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/posture_fields")

      assert %{"data" => data} = json_response(conn, 200)

      expected_count =
        Fields.registry() |> Enum.map(fn {_provider, fields} -> map_size(Map.new(fields)) end) |> Enum.sum()

      assert length(data) == expected_count

      assert %{
               "provider" => "intune",
               "type" => "enum_string",
               "rows_supported" => true,
               "operators" => operators,
               "platforms" => platforms
             } = Enum.find(data, &(&1["field"] == "intune.compliance_state"))

      assert "is" in operators
      assert "exists" in operators
      assert "windows" in platforms

      assert %{"rows_supported" => false, "type" => "version"} =
               Enum.find(data, &(&1["field"] == "firezone.last_seen_version"))
    end

    test "filters by provider", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/posture_fields", provider: "santa")

      assert %{"data" => [_ | _] = data} = json_response(conn, 200)
      assert Enum.all?(data, &(&1["provider"] == "santa"))
      assert Enum.all?(data, &(&1["platforms"] == ["macos"]))
    end

    test "rejects an unknown provider", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/posture_fields", provider: "kolide")

      assert %{"status" => 400, "detail" => detail} = json_response(conn, 400)
      assert detail =~ "provider"
    end
  end
end
