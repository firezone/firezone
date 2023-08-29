defmodule Web.Auth.Devices.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    device = Fixtures.Devices.create_device(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      device: device
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    device: device,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/devices/#{device}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when device is deleted", %{
    account: account,
    device: device,
    identity: identity,
    conn: conn
  } do
    device = Fixtures.Devices.delete_device(device)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    device: device,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Devices"
    assert breadcrumbs =~ device.name
  end

  test "renders device details", %{
    account: account,
    device: device,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}")

    table =
      lv
      |> element("#device")
      |> render()
      |> vertical_table_to_map()

    assert table["identifier"] == device.id
    assert table["name"] == device.name
    assert table["owner"] =~ actor.name
    assert table["created"]
    assert table["last seen"]
    assert table["remote ipv4"] =~ to_string(device.ipv4)
    assert table["remote ipv6"] =~ to_string(device.ipv6)
    assert table["client version"] =~ device.last_seen_version
    assert table["user agent"] =~ device.last_seen_user_agent
  end

  test "renders device owner", %{
    account: account,
    device: device,
    identity: identity,
    conn: conn
  } do
    actor = Repo.preload(device, :actor).actor

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}")

    assert lv
           |> element("#device")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("owner") =~ actor.name
  end

  test "allows editing devices", %{
    account: account,
    device: device,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}")

    assert lv
           |> element("a", "Edit Device")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/devices/#{device}/edit", kind: :push}}}
  end

  test "allows deleting devices", %{
    account: account,
    device: device,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}")

    assert lv
           |> element("button", "Delete Device")
           |> render_click() ==
             {:error, {:redirect, %{to: ~p"/#{account}/devices"}}}

    assert Repo.get(Domain.Devices.Device, device.id).deleted_at
  end
end
