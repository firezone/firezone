defmodule PortalAPI.Plugs.ScopeTest do
  use PortalAPI.ConnCase, async: true

  alias PortalAPI.Scopes

  setup %{conn: conn} do
    account = Portal.AccountFixtures.account_fixture()
    actor = Portal.ActorFixtures.actor_fixture(type: :account_admin_user, account: account)
    %{conn: conn, account: account, actor: actor}
  end

  describe "a scoped credential" do
    test "reaches the entity it was granted", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor, ["policies:read"])
        |> get(~p"/policies")

      assert json_response(conn, 200)
    end

    test "is refused on an entity it was not granted", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor, ["policies:read"])
        |> get(~p"/resources")

      assert %{"detail" => detail} = json_response(conn, 403)
      assert detail =~ "resources:read"
    end

    test "may read with a write scope, since write implies read", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor, ["policies:write"])
        |> get(~p"/policies")

      assert json_response(conn, 200)
    end

    test "may not write with only a read scope", %{conn: conn, actor: actor} do
      conn =
        conn
        |> authorize_conn(actor, ["policies:read"])
        |> post(~p"/policies", %{})

      assert %{"detail" => detail} = json_response(conn, 403)
      assert detail =~ "policies:write"
    end

  end

  describe "composition with Safe.permit/3" do
    test "a scope narrows but never widens what the actor may do" do
      account = Portal.AccountFixtures.account_fixture()
      actor = Portal.ActorFixtures.actor_fixture(type: :account_user, account: account)

      subject =
        Portal.SubjectFixtures.subject_fixture(account: account, actor: actor)
        |> put_in([Access.key!(:credential), Access.key!(:scopes)], ["groups:write"])

      assert Portal.Scope.permit(:groups, :post, subject) == :ok

      assert Portal.Safe.permit(:insert, Portal.Group, subject) == {:error, :unauthorized}
    end
  end

  describe "a request refused for its scopes" do
    test "is still metered and logged, like any other authenticated request", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor, ["policies:read"])
        |> put_req_header("content-type", "application/json")
        |> get(~p"/resources")

      assert json_response(conn, 403)

      # Otherwise a narrowly scoped token could do unbounded work off the books.
      assert [log] = Portal.Repo.all(Portal.APIRequestLog)
      assert log.account_id == account.id
      assert log.actor_id == actor.id
      assert log.method == "GET"
      assert log.path == "/resources"
    end
  end

  describe "an unscoped credential" do
    test "is unrestricted, so tokens minted before scopes keep working", %{
      conn: conn,
      actor: actor
    } do
      conn = conn |> authorize_conn(actor) |> get(~p"/resources")
      assert json_response(conn, 200)
    end
  end

  describe "the entity map" do
    test "every entity in the vocabulary is reachable by some controller" do
      mapped =
        Scopes.controllers()
        |> Enum.map(&Scopes.entity_for/1)
        |> Enum.map(fn {:ok, entity} -> entity end)
        |> MapSet.new()

      dead = Enum.reject(Portal.Scope.entities(), &MapSet.member?(mapped, &1))

      assert dead == [],
             "these entities have no controller behind them, so ticking them in the API " <>
               "token form grants nothing: #{inspect(dead)}"
    end

    test "covers every controller reachable through the :api pipeline" do
      unmapped =
        PortalAPI.Router.__routes__()
        |> Enum.map(fn route ->
          path = String.replace(route.path, ~r/:[a-z_]+/, "00000000-0000-0000-0000-000000000000")

          Phoenix.Router.route_info(
            PortalAPI.Router,
            route.verb |> Atom.to_string() |> String.upcase(),
            path,
            "localhost"
          )
        end)
        |> Enum.filter(&(is_map(&1) and :api in &1.pipe_through))
        |> Enum.map(& &1.plug)
        |> Enum.uniq()
        |> Enum.reject(&match?({:ok, _entity}, Scopes.entity_for(&1)))

      assert unmapped == [],
             "these controllers are behind the scope plug but have no entity, so every " <>
               "scoped credential is refused on them: #{inspect(unmapped)}"
    end

    test "requires posture provider scope for posture controllers", %{
      conn: conn,
      actor: actor
    } do
      conn =
        conn
        |> authorize_conn(actor, ["policies:read"])
        |> get(~p"/intune_devices")

      assert %{"detail" => detail} = json_response(conn, 403)
      assert detail =~ "posture_providers:read"
    end
  end
end
