defmodule Web.Live.Actors.ServiceAccounts.NewIdentityTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
    provider = Fixtures.Auth.create_email_provider(account: account)

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: [type: :account_admin_user]
      )

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
    path = ~p"/#{account}/actors/service_accounts/#{actor}/new_identity"

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
      |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Actors"
    assert breadcrumbs =~ actor.name
    assert breadcrumbs =~ "Create Token"
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
      |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

    assert lv
           |> form("form")
           |> find_inputs() == [
             "token[expires_at]",
             "token[name]"
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
      |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

    lv
    |> form("form", identity: %{})
    |> validate_change(
      %{token: %{expires_at: "1991-01-01"}},
      fn form, _html ->
        assert %{
                 "token[expires_at]" => ["must be greater than" <> _]
               } = form_validation_errors(form)
      end
    )
  end

  test "renders changeset errors on submit", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    attrs = %{expires_at: "1991-01-01"}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

    html =
      lv
      |> form("form", token: attrs)
      |> render_submit()

    assert %{
             "token[expires_at]" => ["must be greater than" <> _]
           } = form_validation_errors(html)
  end

  test "creates a new actor on valid attrs", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    expires_at = Date.utc_today() |> Date.add(3)

    attrs = %{
      expires_at: Date.to_iso8601(expires_at)
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

    html =
      lv
      |> form("form", token: attrs)
      |> render_submit()

    context = %Domain.Auth.Context{
      type: :client,
      remote_ip: Fixtures.Auth.remote_ip(),
      user_agent: Fixtures.Auth.user_agent(),
      remote_ip_location_region: "Mexico",
      remote_ip_location_city: "Merida",
      remote_ip_location_lat: 37.7749,
      remote_ip_location_lon: -120.4194
    }

    assert {:ok, subject} =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("code")
             |> element_to_text()
             |> Domain.Auth.authenticate(context)

    assert subject.actor.id == actor.id
    assert DateTime.to_date(subject.expires_at) == expires_at
  end
end
