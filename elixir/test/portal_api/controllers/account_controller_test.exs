defmodule PortalAPI.AccountControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  describe "show/2" do
    test "returns account details with limits", %{conn: conn} do
      account = account_fixture()
      actor = actor_fixture(type: :api_client, account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/account")

      assert %{
               "data" => %{
                 "id" => account_id,
                 "slug" => slug,
                 "name" => name,
                 "legal_name" => legal_name,
                 "limits" => limits
               }
             } = json_response(conn, 200)

      assert account_id == account.id
      assert slug == account.slug
      assert name == account.name
      assert legal_name == account.legal_name
      assert is_map(limits)
    end

    test "includes correct limit structure when limits are set", %{conn: conn} do
      account = account_fixture()
      actor = actor_fixture(type: :api_client, account: account)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/account")

      assert %{
               "data" => %{
                 "limits" => limits
               }
             } = json_response(conn, 200)

      # Should include monthly_active_users limit since default account has it set to 100
      assert %{
               "monthly_active_users" => %{
                 "used" => used_mau,
                 "available" => available_mau,
                 "total" => 100
               }
             } = limits

      assert is_integer(used_mau)
      assert is_integer(available_mau)
      assert used_mau + available_mau == 100
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = get(conn, ~p"/account")
      assert json_response(conn, 401)
    end
  end
end
