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
end
