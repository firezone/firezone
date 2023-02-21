defmodule FzHttpWeb.UserLive.ShowTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.UsersFixtures

  describe "authenticated show" do
    setup :create_device

    test "includes the device name", %{admin_conn: conn, device: device} do
      path = ~p"/users/#{device.user_id}"
      {:ok, _view, html} = live(conn, path)

      assert html =~ device.name
    end
  end

  describe "authenticated show device" do
    setup :create_device

    test "shows device details", %{admin_conn: conn, device: device} do
      path = ~p"/devices/#{device}"
      {:ok, _view, html} = live(conn, path)
      assert html =~ device.name
      assert html =~ device.description
      assert html =~ "<h4 class=\"title is-4\">Details</h4>"
    end
  end

  describe "authenticated new device" do
    @test_pubkey "8IkpsAXiqhqNdc9PJS76YeJjig4lyTBaf8Rm7gTApXk="

    @device_id_regex ~r/device-(?<device_id>.*)-inserted-at/
    @valid_params %{
      "device" => %{
        "public_key" => @test_pubkey,
        "name" => "new_name",
        "description" => "new_description"
      }
    }
    @allowed_ips ["2.2.2.2"]
    @allowed_ips_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_allowed_ips" => "false",
        "allowed_ips" => @allowed_ips
      }
    }
    @allowed_ips_unchanged %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_allowed_ips" => "true",
        "allowed_ips" => @allowed_ips
      }
    }
    @dns ["8.8.8.8", "8.8.4.4"]
    @dns_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_dns" => "false",
        "dns" => @dns
      }
    }
    @dns_unchanged %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_dns" => "true",
        "dns" => @dns
      }
    }
    @wireguard_endpoint "6.6.6.6"
    @endpoint_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_endpoint" => "false",
        "endpoint" => @wireguard_endpoint
      }
    }
    @endpoint_unchanged %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_endpoint" => "true",
        "endpoint" => @wireguard_endpoint
      }
    }
    @mtu_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_mtu" => "false",
        "mtu" => "1280"
      }
    }
    @mtu_unchanged %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_mtu" => "true",
        "mtu" => "1280"
      }
    }
    @persistent_keepalive_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_persistent_keepalive" => "false",
        "persistent_keepalive" => "120"
      }
    }
    @persistent_keepalive_unchanged %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_persistent_keepalive" => "true",
        "persistent_keepalive" => "5"
      }
    }
    @default_allowed_ips_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_allowed_ips" => "false"
      }
    }
    @default_dns_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_dns" => "false"
      }
    }
    @default_endpoint_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_endpoint" => "false"
      }
    }
    @default_mtu_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_mtu" => "false"
      }
    }
    @default_persistent_keepalive_change %{
      "device" => %{
        "public_key" => @test_pubkey,
        "use_default_persistent_keepalive" => "false"
      }
    }

    def device_id(view) do
      %{"device_id" => device_id} = Regex.named_captures(@device_id_regex, view)
      device_id
    end

    test "opens modal", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("#add-device-button")
      |> render_click()

      assert_patch(view, ~p"/users/#{user.id}/new_device")
    end

    test "allows name changes", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@valid_params)

      assert test_view =~ "Device added!"
      assert test_view =~ @valid_params["device"]["name"]
    end

    test "prevents allowed_ips changes when use_default_allowed_ips is true", %{
      admin_conn: conn,
      admin_user: user
    } do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@allowed_ips_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents dns changes when use_default_dns is true", %{
      admin_conn: conn,
      admin_user: user
    } do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@dns_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents endpoint changes when use_default_endpoint is true", %{
      admin_conn: conn,
      admin_user: user
    } do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@endpoint_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents mtu changes when use_default_mtu is true", %{
      admin_conn: conn,
      admin_user: user
    } do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@mtu_unchanged)

      assert test_view =~ "must not be present"
    end

    test "prevents persistent_keepalive changes when use_default_persistent_keepalive is true",
         %{
           admin_conn: conn,
           admin_user: user
         } do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@persistent_keepalive_unchanged)

      assert test_view =~ "must not be present"
    end

    test "allows allowed_ips changes", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@allowed_ips_change)

      assert test_view =~ "Device added!"

      path = ~p"/users/#{user.id}"
      {:ok, _view, html} = live(conn, path)
      path = ~p"/devices/#{device_id(html)}"
      {:ok, _view, html} = live(conn, path)

      for allowed_ip <- @allowed_ips do
        assert html =~ allowed_ip
      end
    end

    test "allows dns changes", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@dns_change)

      assert test_view =~ "Device added!"

      path = ~p"/users/#{user.id}"
      {:ok, _view, html} = live(conn, path)
      path = ~p"/devices/#{device_id(html)}"
      {:ok, _view, html} = live(conn, path)

      for dns <- @dns do
        assert html =~ dns
      end
    end

    test "allows endpoint changes", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@endpoint_change)

      assert test_view =~ "Device added!"

      path = ~p"/users/#{user.id}"
      {:ok, _view, html} = live(conn, path)
      path = ~p"/devices/#{device_id(html)}"
      {:ok, _view, html} = live(conn, path)
      assert html =~ @wireguard_endpoint
    end

    test "allows mtu changes", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@mtu_change)

      assert test_view =~ "Device added!"

      path = ~p"/users/#{user.id}"
      {:ok, _view, html} = live(conn, path)
      path = ~p"/devices/#{device_id(html)}"
      {:ok, _view, html} = live(conn, path)
      assert html =~ "1280"
    end

    test "allows persistent_keepalive changes", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_submit(@persistent_keepalive_change)

      assert test_view =~ "Device added!"

      path = ~p"/users/#{user.id}"
      {:ok, _view, html} = live(conn, path)
      path = ~p"/devices/#{device_id(html)}"
      {:ok, _view, html} = live(conn, path)
      assert html =~ "120"
    end

    test "generates a name when it's empty", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      params = Map.put(@valid_params, "name", "")

      test_view =
        view
        |> form("#create-device")
        |> render_submit(params)

      assert test_view =~ "Device added!"
    end

    test "on use_default_allowed_ips change", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_change(@default_allowed_ips_change)

      assert test_view =~ """
             <textarea class="textarea " id="create-device_allowed_ips" name="device[allowed_ips]">
             </textarea>\
             """
    end

    test "on use_default_dns change", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_change(@default_dns_change)

      assert test_view =~ """
             <input class="input " id="create-device_dns" name="device[dns]" type="text"/>\
             """
    end

    test "on use_default_endpoint change", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_change(@default_endpoint_change)

      assert test_view =~ """
             <input class="input " id="create-device_endpoint" name="device[endpoint]" type="text"/>\
             """
    end

    test "on use_default_mtu change", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_change(@default_mtu_change)

      assert test_view =~ """
             <input class="input " id="create-device_mtu" name="device[mtu]" type="text"/>\
             """
    end

    test "on use_default_persistent_keepalive change", %{admin_conn: conn, admin_user: user} do
      path = ~p"/users/#{user.id}/new_device"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#create-device")
        |> render_change(@default_persistent_keepalive_change)

      assert test_view =~ """
             <input class="input " id="create-device_persistent_keepalive" name="device[persistent_keepalive]" type="text"/>\
             """
    end
  end

  describe "delete own device" do
    setup :create_device

    test "successful", %{admin_conn: conn, device: device} do
      path = ~p"/devices/#{device}"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Delete Device #{device.name}")
      |> render_click()

      assert_redirect(view, ~p"/devices")
    end
  end

  describe "unauthenticated show" do
    setup :create_device

    test "redirects to sign in", %{unauthed_conn: conn, device: device} do
      path = ~p"/users/#{device.user_id}"
      expected_path = ~p"/"
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "delete self" do
    test "displays flash message with error", %{admin_user: user, admin_conn: conn} do
      path = ~p"/users/#{user.id}"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("button", "Delete User")
        |> render_click()

      assert test_view =~ "Use the account section to delete your account."
    end
  end

  describe "delete_user" do
    setup :create_users

    test "deletes the user", %{admin_conn: conn, users: users} do
      user = List.last(users)
      path = ~p"/users/#{user.id}"
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Delete User")
      |> render_click()

      {new_path, flash} = assert_redirect(view)
      assert flash["info"] == "User deleted successfully."
      assert new_path == ~p"/users"
    end
  end

  describe "user role" do
    setup do
      admin_user = UsersFixtures.user(role: :admin)
      unprivileged_user = UsersFixtures.user(role: :unprivileged)
      {:ok, other_admin_user: admin_user, unprivileged_user: unprivileged_user}
    end

    test "promotes to admin", %{admin_conn: conn, unprivileged_user: unprivileged_user} do
      path = ~p"/users/#{unprivileged_user}"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("button", "promote")
        |> render_click()

      assert test_view =~ "User updated successfully."
      assert test_view =~ "<td>admin</td>"
    end

    test "demotes to unprivileged", %{admin_conn: conn, other_admin_user: other_admin_user} do
      path = ~p"/users/#{other_admin_user}"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("button", "demote")
        |> render_click()

      assert test_view =~ "User updated successfully."
      assert test_view =~ "<td>unprivileged</td>"
    end

    test "demotes self", %{admin_conn: conn, admin_user: admin_user} do
      path = ~p"/users/#{admin_user}"
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("button", "demote")
        |> render_click()

      assert test_view =~ "not supported"
      assert test_view =~ "<td>admin</td>"
    end
  end

  describe "edit user" do
    setup :create_users

    setup %{users: users, admin_conn: conn} do
      user = List.last(users)
      path = ~p"/users/#{user.id}/edit"
      {:ok, view, _html} = live(conn, path)

      success = fn _conn, view, user ->
        {new_path, flash} = assert_redirect(view)
        assert flash["info"] == "User updated successfully."
        assert new_path == ~p"/users/#{user.id}"
      end

      %{success: success, view: view, admin_conn: conn, user: user}
    end

    @new_email_attrs %{"user" => %{"email" => "newemail@localhost"}}
    @new_password_attrs %{
      "user" => %{"password" => "new_password", "password_confirmation" => "new_password"}
    }
    @new_email_password_attrs %{
      "user" => %{
        "email" => "newemail@localhost",
        "password" => "new_password",
        "password_confirmation" => "new_password"
      }
    }
    @invalid_attrs %{
      "user" => %{
        "email" => "not_valid",
        "password" => "short",
        "password_confirmation" => "short"
      }
    }

    test "successfully changes email", %{
      success: success,
      view: view,
      user: user,
      admin_conn: conn
    } do
      view
      |> element("form#user-form")
      |> render_submit(@new_email_attrs)

      success.(conn, view, user)
    end

    test "successfully changes password", %{
      success: success,
      view: view,
      admin_conn: conn,
      user: user
    } do
      view
      |> element("form#user-form")
      |> render_submit(@new_password_attrs)

      success.(conn, view, user)
    end

    test "successfully changes email and password", %{
      success: success,
      view: view,
      admin_conn: conn,
      user: user
    } do
      view
      |> element("form#user-form")
      |> render_submit(@new_email_password_attrs)

      success.(conn, view, user)
    end

    test "displays errors for invalid changes", %{view: view} do
      test_view =
        view
        |> element("form#user-form")
        |> render_submit(@invalid_attrs)

      assert test_view =~ "is invalid email address"
      assert test_view =~ "should be at least 12 character(s)"
    end
  end

  describe "disable/enable user" do
    import Ecto.Changeset
    alias FzHttp.Repo

    test "enable user", %{admin_conn: conn, unprivileged_user: user} do
      user = user |> change |> put_change(:disabled_at, DateTime.utc_now()) |> Repo.update!()
      path = ~p"/users/#{user.id}"

      {:ok, view, _html} = live(conn, path)

      view
      |> element("input[type=checkbox]")
      |> render_click()

      user = Repo.reload(user)

      refute user.disabled_at
    end

    test "disable user", %{admin_conn: conn, unprivileged_user: user} do
      path = ~p"/users/#{user.id}"

      {:ok, view, _html} = live(conn, path)

      view
      |> element("input[type=checkbox]")
      |> render_click()

      user = Repo.reload(user)

      assert user.disabled_at
    end
  end
end
