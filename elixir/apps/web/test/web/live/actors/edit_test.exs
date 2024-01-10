defmodule Web.Live.Actors.EditTest do
  use Web.ConnCase, async: true

  describe "user" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(actor: actor, account: account)

      %{
        account: account,
        actor: actor,
        identity: identity
      }
    end

    test "redirects to sign in page for unauthorized user", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      path = ~p"/#{account}/actors/#{actor}/edit"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must log in to access this page."}
                 }}}
    end

    test "renders not found error when actor is deleted", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      actor = Fixtures.Actors.delete(actor)

      assert_raise Web.LiveErrors.NotFoundError, fn ->
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")
      end
    end

    test "renders breadcrumbs item", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      assert item = Floki.find(html, "[aria-label='Breadcrumb']")
      breadcrumbs = String.trim(Floki.text(item))
      assert breadcrumbs =~ "Actors"
      assert breadcrumbs =~ actor.name
      assert breadcrumbs =~ "Edit"
    end

    test "renders form", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      form = form(lv, "form")

      assert find_inputs(form) == [
               "actor[name]",
               "actor[type]"
             ]

      Fixtures.Actors.create_group(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      form = form(lv, "form")

      assert find_inputs(form) == [
               "actor[memberships][]",
               "actor[name]",
               "actor[type]"
             ]

      Fixtures.Actors.update(actor, last_synced_at: DateTime.utc_now())

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      form = form(lv, "form")

      assert find_inputs(form) == [
               "actor[memberships][]",
               "actor[type]"
             ]
    end

    test "renders changeset errors on input change", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      attrs = Fixtures.Actors.actor_attrs() |> Map.take([:name])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      lv
      |> form("form", actor: attrs)
      |> validate_change(%{actor: %{name: String.duplicate("a", 555)}}, fn form, _html ->
        assert form_validation_errors(form) == %{
                 "actor[name]" => ["should be at most 512 character(s)"]
               }
      end)
      |> validate_change(%{actor: %{name: ""}}, fn form, _html ->
        assert form_validation_errors(form) == %{
                 "actor[name]" => ["can't be blank"]
               }
      end)
    end

    test "renders changeset errors on submit", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      attrs = %{name: String.duplicate("X", 555)}

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      assert lv
             |> form("form", actor: attrs)
             |> render_submit()
             |> form_validation_errors() == %{
               "actor[name]" => ["should be at most 512 character(s)"]
             }
    end

    test "renders error when trying to demote the last admin", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      attrs = %{name: String.duplicate("X", 555)}

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      assert lv
             |> form("form", actor: attrs)
             |> render_submit() =~ "You may not demote the last admin."
    end

    test "updates an actor on valid attrs", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      group1 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(actor: actor, group: group1)

      group2 = Fixtures.Actors.create_group(account: account)

      attrs = %{
        name: Fixtures.Actors.actor_attrs().name,
        memberships: [group2.id]
      }

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      lv
      |> form("form", actor: attrs)
      |> render_submit()

      assert_redirected(lv, ~p"/#{account}/actors/#{actor}")

      assert actor = Repo.get_by(Domain.Actors.Actor, id: actor.id) |> Repo.preload(:memberships)
      assert actor.name == attrs.name
      assert [%{group_id: group_id}] = actor.memberships
      assert group_id == group2.id
    end
  end

  describe "service account" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account
        )

      %{
        account: account,
        actor: actor,
        identity: identity
      }
    end

    test "redirects to sign in page for unauthorized user", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      path = ~p"/#{account}/actors/#{actor}/edit"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must log in to access this page."}
                 }}}
    end

    test "renders not found error when gateway is deleted", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.delete(actor)

      assert_raise Web.LiveErrors.NotFoundError, fn ->
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")
      end
    end

    test "renders breadcrumbs item", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      assert item = Floki.find(html, "[aria-label='Breadcrumb']")
      breadcrumbs = String.trim(Floki.text(item))
      assert breadcrumbs =~ "Actors"
      assert breadcrumbs =~ actor.name
      assert breadcrumbs =~ "Edit"
    end

    test "renders form", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      form = form(lv, "form")

      assert find_inputs(form) == [
               "actor[name]"
             ]

      Fixtures.Actors.create_group(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      form = form(lv, "form")

      assert find_inputs(form) == [
               "actor[memberships][]",
               "actor[name]"
             ]
    end

    test "renders changeset errors on input change", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      attrs = Fixtures.Actors.actor_attrs() |> Map.take([:name])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      lv
      |> form("form", actor: attrs)
      |> validate_change(%{actor: %{name: String.duplicate("a", 555)}}, fn form, _html ->
        assert form_validation_errors(form) == %{
                 "actor[name]" => ["should be at most 512 character(s)"]
               }
      end)
      |> validate_change(%{actor: %{name: ""}}, fn form, _html ->
        assert form_validation_errors(form) == %{
                 "actor[name]" => ["can't be blank"]
               }
      end)
    end

    test "renders changeset errors on submit", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      attrs = %{name: String.duplicate("a", 555)}

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      assert lv
             |> form("form", actor: attrs)
             |> render_submit()
             |> form_validation_errors() == %{
               "actor[name]" => ["should be at most 512 character(s)"]
             }
    end

    test "updates an actor on valid attrs", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      group1 = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(actor: actor, group: group1)

      group2 = Fixtures.Actors.create_group(account: account)

      attrs = %{
        name: Fixtures.Actors.actor_attrs().name,
        memberships: [group2.id]
      }

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}/edit")

      lv
      |> form("form", actor: attrs)
      |> render_submit()

      assert_redirected(lv, ~p"/#{account}/actors/#{actor}")

      assert actor = Repo.get_by(Domain.Actors.Actor, id: actor.id) |> Repo.preload(:memberships)
      assert actor.name == attrs.name
      assert [%{group_id: group_id}] = actor.memberships
      assert group_id == group2.id
    end
  end
end
