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
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account_name = "FooBar"

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    email = Fixtures.Auth.email()

    attrs = %{
      account: %{name: account_name},
      actor: %{name: "John Doe"},
      email: email
    }

    Bypass.open()
    |> Domain.Mocks.Stripe.mock_create_customer_endpoint(%{
      id: Ecto.UUID.generate(),
      name: account_name
    })
    |> Domain.Mocks.Stripe.mock_create_subscription_endpoint()

    assert html =
             lv
             |> form("form", registration: attrs)
             |> render_submit()

    assert html =~ "Your account has been created!"
    assert html =~ account_name

    account = Repo.one(Domain.Account)
    assert account.name == account_name
    assert account.metadata.stripe.customer_id
    assert account.metadata.stripe.billing_email == email

    group = Repo.one(Domain.Group)
    assert group.account_id == account.id
    assert group.name == "Everyone"
    assert group.type == :managed

    provider = Repo.one(Domain.Auth.Provider)
    assert provider.account_id == account.id

    actor = Repo.one(Domain.Actor)
    assert actor.account_id == account.id
    assert actor.name == "John Doe"

    identity = Repo.one(Domain.ExternalIdentity)
    assert identity.account_id == account.id
    assert identity.provider_identifier == email

    assert_email_sent(fn email ->
      assert email.subject == "Welcome to Firezone"
      assert email.text_body =~ url(~p"/#{account}")
    end)

    internet_resource = Repo.one(Domain.Resources.Resource)
    assert internet_resource.account_id == account.id
    assert internet_resource.name == "Internet"
    assert internet_resource.type == :internet

    default_site = Repo.get_by(Domain.Site, name: "Default Site")
    assert default_site.account_id == account.id
    assert default_site.managed_by == :account

    internet_site = Repo.get_by(Domain.Site, name: "Internet")
    assert internet_site.account_id == account.id
    assert internet_site.managed_by == :system
  end

  test "rate limits welcome emails", %{conn: conn} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account_name = "FooBar"
    email = Fixtures.Auth.email()

    attrs = %{
      account: %{name: account_name},
      actor: %{name: "John Doe"},
      email: email
    }

    Bypass.open()
    |> Domain.Mocks.Stripe.mock_create_customer_endpoint(%{
      id: Ecto.UUID.generate(),
      name: account_name
    })
    |> Domain.Mocks.Stripe.mock_create_subscription_endpoint()

    for _ <- 1..3 do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      assert html =
               lv
               |> form("form", registration: attrs)
               |> render_submit()

      assert html =~ "Your account has been created!"
    end

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    assert html =
             lv
             |> form("form", registration: attrs)
             |> render_submit()

    assert html =~ "This email has been rate limited. Please try again later."
  end

  test "trims the user email", %{conn: conn} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account_name = "FooBar"

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    email = Fixtures.Auth.email()

    attrs = %{
      account: %{name: account_name},
      actor: %{name: "John Doe"},
      email: " " <> email <> " "
    }

    Bypass.open()
    |> Domain.Mocks.Stripe.mock_create_customer_endpoint(%{
      id: Ecto.UUID.generate(),
      name: account_name
    })
    |> Domain.Mocks.Stripe.mock_create_subscription_endpoint()

    lv
    |> form("form", registration: attrs)
    |> render_submit()

    account = Repo.one(Domain.Account)
    assert account.name == account_name
    assert account.metadata.stripe.customer_id
    assert account.metadata.stripe.billing_email == email

    identity = Repo.one(Domain.ExternalIdentity)
    assert identity.account_id == account.id
    assert identity.provider_identifier == email
  end

  test "allows whitelisted domains to create new account", %{conn: conn} do
    whitelisted_domain = "example.com"
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    Domain.Config.put_env_override(:sign_up_whitelisted_domains, [whitelisted_domain])

    account_name = "FooBar"

    attrs = %{
      account: %{name: account_name},
      actor: %{name: "John Doe"},
      email: Fixtures.Auth.email(whitelisted_domain)
    }

    Bypass.open()
    |> Domain.Mocks.Stripe.mock_create_customer_endpoint(%{
      id: Ecto.UUID.generate(),
      name: account_name
    })
    |> Domain.Mocks.Stripe.mock_create_subscription_endpoint()

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    html =
      lv
      |> form("form", registration: attrs)
      |> render_submit()

    assert html =~ "Your account has been created!"
    assert html =~ account_name
  end

  test "does not show account creation form when sign ups are disabled", %{conn: conn} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    Domain.Config.feature_flag_override(:sign_up, false)

    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    refute has_element?(lv, "form")
  end

  test "does not allow to create account from not whitelisted domain", %{conn: conn} do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    Domain.Config.feature_flag_override(:sign_up, true)
    Domain.Config.put_env_override(:sign_up_whitelisted_domains, ["firezone.dev"])

    account_name = "FooBar"

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    email = Fixtures.Auth.email()

    attrs = %{
      account: %{name: account_name},
      actor: %{name: "John Doe"},
      email: email
    }

    assert html =
             lv
             |> form("form", registration: attrs)
             |> render_submit()

    assert html =~ "this email domain is not allowed at this time"
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
             "registration[email]" => ["is an invalid email address"]
           }
  end

  test "renders changeset errors on submit when sign up disabled", %{
    conn: conn
  } do
    Domain.Config.feature_flag_override(:sign_up, false)
    Domain.Config.put_env_override(:sign_up_whitelisted_domains, ["foo.com"])

    {:ok, _lv, html} = live(conn, ~p"/sign_up")
    assert html =~ "Sign-ups are currently disabled."
  end

  test "renders sign up disabled message", %{conn: conn} do
    Domain.Config.feature_flag_override(:sign_up, false)
    Domain.Config.put_env_override(:sign_up_whitelisted_domains, [])

    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Sign-ups are currently disabled"
    assert html =~ "sales@firezone.dev"
  end
end
