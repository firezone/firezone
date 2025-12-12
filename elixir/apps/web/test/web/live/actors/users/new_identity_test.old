defmodule Web.Live.Actors.User.NewIdentityTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    _provider = Fixtures.Auth.create_email_provider(account: account)

    # TODO: Users won't be able to naturally arrive at some of the routes tested on this page without another
    # manual provisioning provider like OIDC, so we add it here. Clean this up when identities are refactored.
    {oidc_provider, _bypass} =
      Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

    actor =
      Fixtures.Actors.create_actor(
        type: :account_admin_user,
        account: account,
        provider: oidc_provider
      )

    identity =
      Fixtures.Auth.create_identity(account: account, provider: oidc_provider, actor: actor)

    %{
      account: account,
      actor: actor,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    path = ~p"/#{account}/actors/users/#{actor}/new_identity"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Actors"
    assert breadcrumbs =~ actor.name
    assert breadcrumbs =~ "Add Identity"
  end

  test "renders form", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity")

    assert lv
           |> form("form")
           |> find_inputs() == [
             "identity[provider_id]",
             "identity[provider_identifier]",
             "identity[provider_identifier_confirmation]"
           ]
  end

  test "changes form depending on selected provider", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    provider = Fixtures.Auth.create_userpass_provider(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity")

    lv
    |> form("form", identity: %{provider_id: provider.id})
    |> render_change()

    assert lv
           |> form("form")
           |> find_inputs() == [
             "identity[provider_id]",
             "identity[provider_identifier]",
             "identity[provider_virtual_state][_persistent_id]",
             "identity[provider_virtual_state][password]",
             "identity[provider_virtual_state][password_confirmation]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity")

    lv
    |> form("form", identity: %{})
    |> validate_change(%{identity: %{provider_identifier: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "identity[provider_identifier]" => ["can't be blank"]
             }
    end)

    lv
    |> form("form", identity: %{})
    |> validate_change(
      %{
        identity: %{
          provider_identifier: Fixtures.Auth.email()
        }
      },
      fn form, _html ->
        assert form_validation_errors(form) == %{
                 "identity[provider_identifier_confirmation]" => ["email does not match"]
               }
      end
    )
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    attrs = %{provider_identifier: ""}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity")

    assert lv
           |> form("form", identity: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "identity[provider_identifier]" => ["can't be blank"]
           }

    assert lv
           |> form("form", identity: %{provider_identifier: Fixtures.Auth.email()})
           |> render_submit()
           |> form_validation_errors() == %{
             "identity[provider_identifier_confirmation]" => ["email does not match"]
           }
  end

  test "creates a new identity on valid attrs when next_step not set", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    email_addr = Fixtures.Auth.email()

    attrs = %{
      provider_identifier: email_addr,
      provider_identifier_confirmation: email_addr
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity")

    lv
    |> form("form", identity: attrs)
    |> render_submit()

    assert identity =
             Repo.get_by(Domain.ExternalIdentity, provider_identifier: attrs.provider_identifier)

    assert_redirect(lv, ~p"/#{account}/actors/#{identity.actor_id}")

    assert_email_sent(fn email ->
      assert email.text_body =~ account.slug
    end)
  end

  test "creates a new identity on valid attrs when next_step is set", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    email_addr = Fixtures.Auth.email()

    attrs = %{
      provider_identifier: email_addr,
      provider_identifier_confirmation: email_addr
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/users/#{actor}/new_identity?next_step=edit_groups")

    lv
    |> form("form", identity: attrs)
    |> render_submit()

    assert identity =
             Repo.get_by(Domain.ExternalIdentity, provider_identifier: attrs.provider_identifier)

    assert_redirect(lv, ~p"/#{account}/actors/#{identity.actor_id}/edit_groups")

    assert_email_sent(fn email ->
      assert email.text_body =~ account.slug
    end)
  end
end
