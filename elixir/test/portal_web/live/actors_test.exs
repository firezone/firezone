defmodule PortalWeb.Live.ActorsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "handle_params :show" do
    test "redirects to actors list when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{Ecto.UUID.generate()}")

      assert path == ~p"/#{account}/actors"
    end
  end

  describe "handle_params :edit" do
    test "redirects to actors list when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{Ecto.UUID.generate()}/edit")

      assert path == ~p"/#{account}/actors"
    end
  end

  describe "handle_params :add_token" do
    test "redirects to actors list when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{Ecto.UUID.generate()}/add_token")

      assert path == ~p"/#{account}/actors"
    end
  end

  describe "handle_event delete" do
    test "shows error flash when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "delete", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Actor not found"
    end
  end

  describe "handle_event disable" do
    test "shows error flash when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "disable", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Actor not found"
    end
  end

  describe "handle_event enable" do
    test "shows error flash when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "enable", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Actor not found"
    end
  end

  describe "handle_event create_user" do
    test "enforces users_count limit", %{account: account, actor: actor, conn: conn} do
      Ecto.Changeset.change(account, limits: %Portal.Accounts.Limits{users_count: 1})
      |> Repo.update!()

      actor_with_email_fixture(type: :account_user, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      html =
        lv
        |> form("#user-form",
          actor: %{
            "name" => "Another User",
            "email" => "another-user@example.com",
            "type" => "account_user",
            "allow_email_otp_sign_in" => "true"
          }
        )
        |> render_submit()

      assert html =~ "User limit reached for your account"
      refute Repo.get_by(Portal.Actor, account_id: account.id, email: "another-user@example.com")
    end
  end
end
