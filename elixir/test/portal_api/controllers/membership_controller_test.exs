defmodule PortalAPI.MembershipControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyAuthorizationFixtures
  import Ecto.Query

  alias Portal.Repo

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, account: account} do
      group = group_fixture(account: account)
      conn = get(conn, "/groups/#{group.id}/memberships")
      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns unauthorized for an actor without permission", %{conn: conn, account: account} do
      group = group_fixture(account: account)
      unprivileged = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}/memberships")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists all memberships", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)

      memberships =
        for _ <- 1..3,
            do: membership_fixture(account: account, group: group)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}/memberships")

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
      membership_ids = Enum.map(memberships, & &1.actor_id)

      assert equal_ids?(membership_ids, data_ids)
    end

    test "lists identity providers with limit", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)

      memberships =
        for _ <- 1..3,
            do: membership_fixture(account: account, group: group)

      conn =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> get("/groups/#{group.id}/memberships", limit: "2")

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
      assert MapSet.size(data_ids) == 2

      membership_ids =
        Enum.map(memberships, & &1.actor_id) |> MapSet.new()

      assert MapSet.subset?(data_ids, membership_ids)
    end
  end

  describe "update_patch/2" do
    test "adds actor to group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor = actor_fixture(account: account)
      attrs = %{"add" => [actor.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor.id]}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
    end

    test "returns error on invalid group id", %{conn: conn, actor: api_actor} do
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/00000000-0000-0000-0000-000000000000/memberships",
          memberships: attrs
        )

      assert %{"type" => "about:blank", "status" => 404, "title" => "Not Found"} =
               json_response(conn, 404)
    end

    test "returns error on invalid actor id", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert resp = json_response(conn, 422)
      assert %{"type" => "about:blank", "status" => 422} = resp
      assert %{"validation_errors" => %{"memberships" => memberships}} = resp

      assert memberships == [
               "00000000-0000-0000-0000-000000000000 is not an Actor in this account"
             ]
    end

    test "returns forbidden when group is not editable", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = synced_group_fixture(account: account)
      actor = actor_fixture(account: account)
      attrs = %{"add" => [actor.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"type" => "about:blank", "status" => 403, "detail" => "Group is not editable"} =
               json_response(conn, 403)
    end

    test "returns unauthorized when actor cannot read the group", %{
      conn: conn,
      account: account
    } do
      group = group_fixture(account: account)
      unprivileged = actor_fixture(account: account, type: :service_account)
      attrs = %{"add" => ["00000000-0000-0000-0000-000000000000"]}

      conn =
        conn
        |> authorize_conn(unprivileged)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "returns validation error for malformed actor uuid", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      attrs = %{"add" => ["<no value>"]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      resp = json_response(conn, 422)
      assert %{"type" => "about:blank", "status" => 422} = resp
      assert %{"validation_errors" => %{"add" => %{"0" => ["is invalid"]}}} = resp
    end

    test "removes actor from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = %{"remove" => [actor2.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor1.id]}
    end

    test "adds and removes actors from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      actor3 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = %{"add" => [actor3.id], "remove" => [actor2.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor3.id])
    end

    test "group remains the same on empty params", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = %{}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor2.id])
    end
  end

  describe "update_put/2" do
    test "adds actor to group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor = actor_fixture(account: account)
      attrs = [%{"actor_id" => actor.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor.id]}
    end

    test "returns error on empty params/body", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships")

      assert %{"type" => "about:blank", "status" => 400, "title" => "Bad Request"} =
               json_response(conn, 400)
    end

    test "returns validation error for malformed actor uuid", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      attrs = [%{"actor_id" => "<no value>"}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      resp = json_response(conn, 422)
      assert %{"type" => "about:blank", "status" => 422} = resp
      assert %{"validation_errors" => %{"0" => %{"actor_id" => ["is invalid"]}}} = resp
    end

    test "removes actor from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = [%{"actor_id" => actor1.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert data == %{"actor_ids" => [actor1.id]}
    end

    test "adds and removes actors from group", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      actor3 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      attrs = [%{"actor_id" => actor1.id}, %{"actor_id" => actor3.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.sort(data["actor_ids"]) == Enum.sort([actor1.id, actor3.id])
    end
  end

  describe "membership row stability" do
    # Regression for the API equivalent of #12074. The controller used to hand
    # the full desired member list to cast_assoc(:memberships). Membership's
    # primary key is composite - [account_id, id] - and the attrs carried no
    # id, so Ecto matched nothing, deleted every row and reinserted it with a
    # fresh id on every request. That cascaded away policy_authorizations and
    # pushed a delete/insert pair to every connected client of every member.
    defp membership_ids(group_id) do
      from(m in Portal.Membership, where: m.group_id == ^group_id, select: m.id)
      |> Repo.all()
      |> Enum.sort()
    end

    test "PATCH with an empty body does not rewrite any row", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)

      for _ <- 1..3,
          do: membership_fixture(account: account, group: group)

      before_ids = membership_ids(group.id)

      conn
      |> authorize_conn(api_actor)
      |> put_req_header("content-type", "application/json")
      |> patch("/groups/#{group.id}/memberships", memberships: %{})
      |> json_response(200)

      assert membership_ids(group.id) == before_ids
    end

    test "PATCH adding one actor leaves existing rows untouched", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)

      for _ <- 1..3,
          do: membership_fixture(account: account, group: group)

      before_ids = membership_ids(group.id)
      new_actor = actor_fixture(account: account)

      conn
      |> authorize_conn(api_actor)
      |> put_req_header("content-type", "application/json")
      |> patch("/groups/#{group.id}/memberships", memberships: %{"add" => [new_actor.id]})
      |> json_response(200)

      after_ids = membership_ids(group.id)
      assert length(after_ids) == 4
      assert before_ids -- after_ids == []
    end

    test "PUT with an unchanged member list does not rewrite any row", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      before_ids = membership_ids(group.id)
      attrs = [%{"actor_id" => actor1.id}, %{"actor_id" => actor2.id}]

      conn
      |> authorize_conn(api_actor)
      |> put_req_header("content-type", "application/json")
      |> put("/groups/#{group.id}/memberships", memberships: attrs)
      |> json_response(200)

      assert membership_ids(group.id) == before_ids
    end

    test "PUT adding one actor leaves existing rows untouched", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      before_ids = membership_ids(group.id)
      actor3 = actor_fixture(account: account)

      attrs = [
        %{"actor_id" => actor1.id},
        %{"actor_id" => actor2.id},
        %{"actor_id" => actor3.id}
      ]

      conn
      |> authorize_conn(api_actor)
      |> put_req_header("content-type", "application/json")
      |> put("/groups/#{group.id}/memberships", memberships: attrs)
      |> json_response(200)

      after_ids = membership_ids(group.id)
      assert length(after_ids) == 3
      assert before_ids -- after_ids == []
    end

    test "PATCH preserves policy authorizations of unaffected members", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account)
      membership = membership_fixture(account: account, actor: member, group: group)

      authorization =
        policy_authorization_fixture(
          account: account,
          actor: member,
          group: group,
          membership: membership
        )

      other = actor_fixture(account: account)

      conn
      |> authorize_conn(api_actor)
      |> put_req_header("content-type", "application/json")
      |> patch("/groups/#{group.id}/memberships", memberships: %{"add" => [other.id]})
      |> json_response(200)

      # policy_authorizations references memberships(account_id, id) ON DELETE
      # CASCADE, so churning the row would have taken this with it.
      assert Repo.get_by(Portal.PolicyAuthorization,
               account_id: account.id,
               id: authorization.id
             )
    end
  end

  describe "idempotency and concurrency" do
    test "PATCH adding an actor already in the group is a no-op", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account)
      membership_fixture(account: account, actor: member, group: group)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: %{"add" => [member.id]})

      assert %{"data" => %{"actor_ids" => [id]}} = json_response(conn, 200)
      assert id == member.id
      assert Repo.aggregate(from(m in Portal.Membership, where: m.group_id == ^group.id), :count) == 1
    end

    test "PATCH removing an actor that is not a member is a no-op", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account)
      membership_fixture(account: account, actor: member, group: group)
      stranger = actor_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: %{"remove" => [stranger.id]})

      assert %{"data" => %{"actor_ids" => [id]}} = json_response(conn, 200)
      assert id == member.id
    end

    test "PATCH keeps an actor named in both add and remove", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      member = actor_fixture(account: account)

      attrs = %{"add" => [member.id], "remove" => [member.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => %{"actor_ids" => [id]}} = json_response(conn, 200)
      assert id == member.id
    end

    test "a membership deleted between read and write does not raise", %{
      account: account,
      actor: api_actor
    } do
      # Interleaved rather than genuinely parallel: the async SQL sandbox gives
      # each process its own connection, so two real requests could not see one
      # another's uncommitted work. Deleting the row between the fetch and the
      # write reproduces the same interleaving the old cast_assoc path turned
      # into an unrescued Ecto.StaleEntryError -> 409 with an HTML body.
      group = group_fixture(account: account)
      actor1 = actor_fixture(account: account)
      actor2 = actor_fixture(account: account)
      membership_fixture(account: account, actor: actor1, group: group)
      membership_fixture(account: account, actor: actor2, group: group)

      subject = Portal.SubjectFixtures.subject_fixture(account: account, actor: api_actor)

      {:ok, group} = PortalAPI.MembershipController.Database.fetch_group(group.id, subject)

      # A concurrent request removes actor1 first.
      from(m in Portal.Membership, where: m.group_id == ^group.id and m.actor_id == ^actor1.id)
      |> Repo.delete_all()

      actor3 = actor_fixture(account: account)

      assert {:ok, actor_ids} =
               PortalAPI.MembershipController.Database.patch_members(
                 group,
                 [actor3.id],
                 [actor1.id],
                 subject
               )

      assert Enum.sort(actor_ids) == Enum.sort([actor2.id, actor3.id])
    end
  end

  describe "input validation" do
    test "PATCH rejects a malformed uuid in remove", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: %{"remove" => ["not-a-uuid"]})

      resp = json_response(conn, 422)
      assert %{"validation_errors" => %{"remove" => %{"0" => ["is invalid"]}}} = resp
    end

    test "PUT rejects an entry with no actor_id", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: [%{}])

      resp = json_response(conn, 422)
      assert %{"validation_errors" => %{"memberships" => memberships}} = resp
      assert memberships == ["entry is missing an Actor ID"]
    end

    test "PUT with an explicitly empty list clears the group", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      membership_fixture(account: account, group: group)

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: [])

      assert %{"data" => %{"actor_ids" => []}} = json_response(conn, 200)
    end
  end

  describe "authorization" do
    # An account_user may read a Group (permit(:read, Portal.Group,
    # :account_user)) but has no Portal.Actor clause, so it clears
    # fetch_group and then fails the Actor lookup. validate_actors/2 has to
    # propagate that rather than read an empty result as "no such actor",
    # which would answer an authorization failure with a 422 claiming every
    # ID is nonexistent.
    test "PATCH returns unauthorized, not a validation error, when the subject cannot read Actors",
         %{conn: conn, account: account} do
      group = group_fixture(account: account)
      target = actor_fixture(account: account)
      account_user = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(account_user)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: %{"add" => [target.id]})

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "PUT returns unauthorized, not a validation error, when the subject cannot read Actors",
         %{conn: conn, account: account} do
      group = group_fixture(account: account)
      target = actor_fixture(account: account)
      account_user = actor_fixture(account: account, type: :account_user)

      conn =
        conn
        |> authorize_conn(account_user)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: [%{"actor_id" => target.id}])

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end
  end

  describe "response contract" do
    # These pin behaviour that changed when the controller moved off
    # cast_assoc, so a future refactor cannot flip it back silently. Before,
    # PUT echoed the request order and rejected a repeated actor_id with a 422
    # ("has already been taken"); PATCH already sorted and already deduplicated.
    test "PUT returns actor_ids sorted, not in request order", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      actors = for _ <- 1..5, do: actor_fixture(account: account)
      sorted = actors |> Enum.map(& &1.id) |> Enum.sort()
      attrs = sorted |> Enum.reverse() |> Enum.map(&%{"actor_id" => &1})

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => %{"actor_ids" => actor_ids}} = json_response(conn, 200)
      assert actor_ids == sorted
    end

    test "PATCH returns actor_ids sorted", %{conn: conn, account: account, actor: api_actor} do
      group = group_fixture(account: account)
      actors = for _ <- 1..5, do: actor_fixture(account: account)
      for a <- actors, do: membership_fixture(account: account, actor: a, group: group)
      sorted = actors |> Enum.map(& &1.id) |> Enum.sort()

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: %{})

      assert %{"data" => %{"actor_ids" => actor_ids}} = json_response(conn, 200)
      assert actor_ids == sorted
    end

    test "PUT deduplicates a repeated actor_id instead of rejecting it", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      actor = actor_fixture(account: account)
      attrs = [%{"actor_id" => actor.id}, %{"actor_id" => actor.id}]

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> put("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => %{"actor_ids" => [id]}} = json_response(conn, 200)
      assert id == actor.id

      assert Repo.aggregate(from(m in Portal.Membership, where: m.group_id == ^group.id), :count) ==
               1
    end

    test "PATCH deduplicates repeated ids in add and remove", %{
      conn: conn,
      account: account,
      actor: api_actor
    } do
      group = group_fixture(account: account)
      keep = actor_fixture(account: account)
      drop = actor_fixture(account: account)
      membership_fixture(account: account, actor: drop, group: group)

      attrs = %{"add" => [keep.id, keep.id], "remove" => [drop.id, drop.id]}

      conn =
        conn
        |> authorize_conn(api_actor)
        |> put_req_header("content-type", "application/json")
        |> patch("/groups/#{group.id}/memberships", memberships: attrs)

      assert %{"data" => %{"actor_ids" => [id]}} = json_response(conn, 200)
      assert id == keep.id

      assert Repo.aggregate(from(m in Portal.Membership, where: m.group_id == ^group.id), :count) ==
               1
    end
  end
end
