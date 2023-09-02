defmodule Web.Live.Devices.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    device = Fixtures.Devices.create_device(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      device: device
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    device: device,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/devices/#{device}/edit") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when device is deleted", %{
    account: account,
    identity: identity,
    device: device,
    conn: conn
  } do
    device = Fixtures.Devices.delete_device(device)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    device: device,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}/edit")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Devices"
    assert breadcrumbs =~ device.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    device: device,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "device[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    device: device,
    conn: conn
  } do
    attrs = Fixtures.Devices.device_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}/edit")

    lv
    |> form("form", device: attrs)
    |> validate_change(%{device: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "device[name]" => ["should be at most 255 character(s)"]
             }
    end)
    |> validate_change(%{device: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "device[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    identity: identity,
    device: device,
    conn: conn
  } do
    other_device = Fixtures.Devices.create_device(account: account, actor: actor)
    attrs = %{name: other_device.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}/edit")

    assert lv
           |> form("form", device: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "device[name]" => ["has already been taken"]
           }
  end

  test "creates a new device on valid attrs", %{
    account: account,
    identity: identity,
    device: device,
    conn: conn
  } do
    attrs = Fixtures.Devices.device_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/devices/#{device}/edit")

    assert lv
           |> form("form", device: attrs)
           |> render_submit() ==
             {:error, {:redirect, %{to: ~p"/#{account}/devices/#{device}"}}}

    assert device = Repo.get_by(Domain.Devices.Device, id: device.id)
    assert device.name == attrs.name
  end
end
