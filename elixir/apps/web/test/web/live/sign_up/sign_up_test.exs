defmodule Web.Live.SignUpTest do
  use Web.ConnCase, async: true

  test "renders sign up form", %{conn: conn} do
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

  test "creates new account and sends a welcome email", %{conn: conn} do
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

    account = Repo.one(Domain.Accounts.Account)
    assert account.name == account_name

    provider = Repo.one(Domain.Auth.Provider)
    assert provider.account_id == account.id

    actor = Repo.one(Domain.Actors.Actor)
    assert actor.account_id == account.id
    assert actor.name == "John Doe"

    identity = Repo.one(Domain.Auth.Identity)
    assert identity.account_id == account.id
    assert identity.provider_identifier == "jdoe@test.local"

    assert_email_sent(fn email ->
      assert email.subject == "Welcome to Firezone"

      verify_sign_in_token_path =
        ~p"/#{account}/sign_in/providers/#{provider.id}/verify_sign_in_token"

      assert email.text_body =~ "#{verify_sign_in_token_path}"
      assert email.text_body =~ "identity_id=#{identity.id}"
      assert email.text_body =~ "secret="

      assert email.text_body =~ url(~p"/#{account}")
    end)
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

  test "renders sign up disabled message", %{conn: conn} do
    Domain.Config.feature_flag_override(:signups, false)

    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Sign-ups are currently disabled"
    assert html =~ "sales@firezone.dev"
  end
end
