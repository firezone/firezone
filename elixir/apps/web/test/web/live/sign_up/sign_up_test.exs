defmodule Web.Live.SignUpTest do
  use Web.ConnCase, async: true

  test "renders signup form", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "registration[account][_persistent_id]",
             "registration[account][name]",
             "registration[account][slug]",
             "registration[actor][_persistent_id]",
             "registration[actor][name]",
             "registration[actor][type]",
             "registration[email]"
           ]
  end

  test "creates new account", %{conn: conn} do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account_name = "FooBar"

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    attrs = %{
      account: %{name: account_name},
      actor: %{name: "John Doe"},
      email: "jdoe@test.local"
    }

    assert html =
             lv
             |> form("form", registration: attrs)
             |> render_submit()

    assert html =~ "Your account has been created!"
    assert html =~ account_name
  end

  test "renders changeset errors on input change", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    attrs = %{
      account: %{name: "FooBar"},
      actor: %{name: "John Doe"},
      email: "jdoe@test.local"
    }

    lv
    |> form("form", registration: attrs)
    |> validate_change(
      %{registration: %{account: %{name: ""}, actor: %{name: ""}, email: ""}},
      fn form, _html ->
        assert form_validation_errors(form) == %{
                 "registration[account][name]" => ["can't be blank"],
                 "registration[actor][name]" => ["can't be blank"],
                 "registration[email]" => ["can't be blank"]
               }
      end
    )
  end

  test "renders changeset errors on submit", %{conn: conn} do
    attrs = %{
      account: %{name: "FooBar"},
      actor: %{name: "John Doe"},
      email: "jdoe"
    }

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    assert lv
           |> form("form", registration: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "registration[email]" => ["has invalid format"]
           }
  end

  test "renders signup disabled message", %{conn: conn} do
    Domain.Config.put_system_env_override(:feature_sign_up_enabled, false)

    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Sign-ups are currently disabled"
    assert html =~ "sales@firezone.dev"
  end
end
