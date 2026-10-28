defmodule PortalWeb.LiveHooks.FetchAccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "live navigation with a slug another region holds moves to that region", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    Portal.SlugRegistryHelpers.use_azure_registry(:us)

    Portal.SlugRegistryHelpers.stub_registry(fn
      %{method: "GET"} = conn ->
        Req.Test.json(conn, Portal.SlugRegistryHelpers.entity("eu-live", Ecto.UUID.generate(), "eu"))
    end)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    assert {:error, {:redirect, %{to: "https://eu.app.firezone.dev/eu-live"}}} =
             live_redirect(lv, to: "/eu-live/sites?tab=all")
  end

  test "live navigation with an old slug moves to the current slug", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    old_slug = account.slug
    account = update_account(account, slug: "#{old_slug}_renamed")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/sites")

    assert {:error, {:redirect, %{to: to}}} =
             live_redirect(lv, to: "/#{old_slug}/settings/account?tab=plan")

    assert to == "/#{account.slug}/settings/account?tab=plan"
  end

  test "a plain request with an old slug moves to the current slug", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    old_slug = account.slug
    account = update_account(account, slug: "#{old_slug}_renamed")

    conn =
      conn
      |> authorize_conn(actor)
      |> get("/#{old_slug}/settings/account")

    assert redirected_to(conn) == "/#{account.slug}/settings/account"
  end
end
