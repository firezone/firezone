defmodule Web.Auth.Devices.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    assert live(conn, ~p"/#{account}/devices") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Devices"
  end

  test "renders empty table when there are no devices", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices")

    assert html =~ "There are no devices to display."
    refute html =~ "tbody"
  end

  test "renders devices table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    online_device = Fixtures.Devices.create_device(account: account)
    offline_device = Fixtures.Devices.create_device(account: account)

    :ok = Domain.Devices.connect_device(online_device)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices")

    lv
    |> element("#devices")
    |> render()
    |> table_to_map()
    |> with_table_row("name", online_device.name, fn row ->
      assert row["status"] == "Online"
      name = Repo.preload(online_device, :actor).actor.name
      assert row["user"] =~ name
    end)
    |> with_table_row("name", offline_device.name, fn row ->
      assert row["status"] == "Offline"
      name = Repo.preload(offline_device, :actor).actor.name
      assert row["user"] =~ name
    end)
  end
end
