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

    Fixtures.Auth.create_token_provider(account: account)

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
    assert live(conn, ~p"/#{account}/actors/service_accounts/#{actor}/new_identity") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
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

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Actors"
    assert breadcrumbs =~ actor.name
    assert breadcrumbs =~ "Add Token"
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
             "identity[provider_identifier]",
             "identity[provider_virtual_state][_persistent_id]",
             "identity[provider_virtual_state][expires_at]"
           ]
  end

  # TODO: LiveView to_form doesn't read the changeset errors when we inject a dynamic changeset in an adapter,
  # will need to find a workaround later
  # test "renders changeset errors on input change", %{
  #   account: account,
  #   actor: actor,
  #   identity: identity,
  #   conn: conn
  # } do
  #   {:ok, lv, _html} =
  #     conn
  #     |> authorize_conn(identity)
  #     |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

  #   lv
  #   |> form("form", identity: %{})
  #   |> validate_change(
  #     %{identity: %{provider_virtual_state: %{expires_at: "1991-01-01"}}},
  #     fn form, _html ->
  #       assert form_validation_errors(form) == %{
  #                "identity[provider_virtual_state][expires_at]" => ["can't be blank"]
  #              }
  #     end
  #   )
  # end

  # test "renders changeset errors on submit", %{
  #   account: account,
  #   actor: actor,
  #   identity: identity,
  #   conn: conn
  # } do
  #   attrs = %{provider_virtual_state: %{expires_at: "1991-01-01"}}

  #   {:ok, lv, _html} =
  #     conn
  #     |> authorize_conn(identity)
  #     |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

  #   assert lv
  #          |> form("form", identity: attrs)
  #          |> render_submit()
  #          |> form_validation_errors() == %{
  #            "identity[provider_virtual_state][expires_at]" => ["can't be blank"]
  #          }
  # end

  test "creates a new actor on valid attrs", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    expires_at = Date.utc_today() |> Date.add(3)

    attrs = %{
      provider_virtual_state: %{
        expires_at: Date.to_iso8601(expires_at)
      }
    }

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/service_accounts/#{actor}/new_identity")

    html =
      lv
      |> form("form", identity: attrs)
      |> render_submit()

    context = %Domain.Auth.Context{
      remote_ip: Fixtures.Auth.remote_ip(),
      user_agent: Fixtures.Auth.user_agent(),
      remote_ip_location_region: "Mexico",
      remote_ip_location_city: "Merida",
      remote_ip_location_lat: 37.7749,
      remote_ip_location_lon: -120.4194
    }

    assert {:ok, subject} =
             Floki.find(html, "code")
             |> element_to_text()
             |> Domain.Auth.sign_in(context)

    assert subject.actor.id == actor.id
    assert DateTime.to_date(subject.expires_at) == expires_at
  end
end
