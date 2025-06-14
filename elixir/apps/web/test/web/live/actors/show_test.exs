defmodule Web.Live.Actors.ShowTest do
  use Web.ConnCase, async: true

  test "redirects to sign in page for unauthorized user", %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    path = ~p"/#{account}/actors/#{actor}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders deleted actor without action buttons", %{conn: conn} do
    account = Fixtures.Accounts.create_account()

    actor =
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      |> Fixtures.Actors.delete()

    auth_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    auth_identity = Fixtures.Auth.create_identity(account: account, actor: auth_actor)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(auth_identity)
      |> live(~p"/#{account}/actors/#{actor}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
  end

  test "renders breadcrumbs item", %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Actors"
    assert breadcrumbs =~ actor.name
  end

  test "renders clients table", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    client = Fixtures.Clients.create_client(account: account, actor: actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    [row] =
      lv
      |> element("#clients")
      |> render()
      |> table_to_map()

    assert row[""] =~ "Apple iOS"
    assert row["name"] == client.name
    assert row["status"] == "Offline"
    assert row["last started"]
    assert row["created"]
  end

  test "updates clients table using presence events", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    client = Fixtures.Clients.create_client(account: account, actor: actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    Domain.Config.put_env_override(:test_pid, self())
    :ok = Domain.Clients.Presence.Actor.subscribe(actor.id)
    assert Domain.Clients.Presence.connect(client) == :ok
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:actor_clients:" <> _}
    assert_receive {:live_table_reloaded, "clients"}, 500

    wait_for(fn ->
      [row] =
        lv
        |> element("#clients")
        |> render()
        |> table_to_map()

      assert row["status"] == "Online"
    end)
  end

  test "renders flows table", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    client = Fixtures.Clients.create_client(account: account, actor: actor)

    flow =
      Fixtures.Flows.create_flow(
        account: account,
        client: client
      )

    flow = Repo.preload(flow, [:client, gateway: [:group], policy: [:actor_group, :resource]])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized"]
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["client"] ==
             "#{flow.client.name} #{client.last_seen_remote_ip}"

    assert row["gateway"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} #{flow.gateway.last_seen_remote_ip}"
  end

  test "renders flows even for deleted policies", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    client = Fixtures.Clients.create_client(account: account, actor: actor)

    flow =
      Fixtures.Flows.create_flow(
        account: account,
        client: client
      )

    flow = Repo.preload(flow, [:client, gateway: [:group], policy: [:actor_group, :resource]])
    Fixtures.Policies.delete_policy(flow.policy)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized"]
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["client"] ==
             "#{flow.client.name} #{client.last_seen_remote_ip}"

    assert row["gateway"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} #{flow.gateway.last_seen_remote_ip}"
  end

  test "renders flows even for deleted policy assocs", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    client = Fixtures.Clients.create_client(account: account, actor: actor)

    flow =
      Fixtures.Flows.create_flow(
        account: account,
        client: client
      )

    flow = Repo.preload(flow, [:client, gateway: [:group], policy: [:actor_group, :resource]])
    Fixtures.Actors.delete_group(flow.policy.actor_group)
    Fixtures.Resources.delete_resource(flow.policy.resource)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized"]
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["client"] ==
             "#{flow.client.name} #{client.last_seen_remote_ip}"

    assert row["gateway"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} #{flow.gateway.last_seen_remote_ip}"
  end

  test "renders groups table", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    group = Fixtures.Actors.create_group(account: account)
    Fixtures.Actors.create_membership(account: account, actor: actor, group: group)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}")

    [row] =
      lv
      |> element("#groups")
      |> render()
      |> table_to_map()

    assert row["name"] == group.name
  end

  describe "users" do
    setup do
      account = Fixtures.Accounts.create_account()
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      %{
        account: account,
        actor: actor,
        provider: provider,
        identity: identity
      }
    end

    test "renders (you) next to subject actor title", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert html =~ "(you)"

      other_actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: other_actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      refute html =~ "(you)"
    end

    test "renders actor details", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert html =~ actor.name
      assert html =~ "User"

      table =
        lv
        |> element("#actor")
        |> render()
        |> vertical_table_to_map()

      assert table["name"] == actor.name
      assert table["role"] == "admin"
      assert around_now?(table["last signed in"])
    end

    test "renders actor identities", %{
      account: account,
      actor: actor,
      identity: admin_identity,
      conn: conn
    } do
      invited_identity =
        Fixtures.Auth.create_identity(account: account, actor: actor)
        |> Ecto.Changeset.change(
          created_by: :identity,
          created_by_subject: %{"email" => admin_identity.email, "name" => actor.name}
        )
        |> Repo.update!()

      synced_identity =
        Fixtures.Auth.create_identity(account: account, actor: actor)
        |> Ecto.Changeset.change(created_by: :provider)
        |> Repo.update!()

      admin_identity = Repo.preload(admin_identity, :provider)
      invited_identity = Repo.preload(invited_identity, :provider)
      synced_identity = Repo.preload(synced_identity, :provider)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("#identities")
      |> render()
      |> table_to_map()
      |> with_table_row(
        "identity",
        "#{admin_identity.provider_identifier}",
        fn row ->
          assert row["actions"] =~ "Delete"
          assert around_now?(row["last signed in"])
          assert around_now?(row["created"])
        end
      )
      |> with_table_row(
        "identity",
        "#{invited_identity.provider_identifier}",
        fn row ->
          assert row["actions"] =~ "Delete"
          assert row["created"] =~ "by #{actor.name}"
          assert row["last signed in"] == "Never"
        end
      )
      |> with_table_row(
        "identity",
        "#{synced_identity.provider_identifier}",
        fn row ->
          refute row["actions"]
          assert row["created"] =~ "by Directory Sync"
          assert row["last signed in"] == "Never"
        end
      )
    end

    test "allows sending welcome email with email identity", %{
      account: account,
      actor: actor,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      email_identity =
        Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
        |> Ecto.Changeset.change(
          created_by: :identity,
          created_by_subject: %{"email" => admin_identity.email, "name" => ""}
        )
        |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("#identity-#{email_identity.id} button", "Send Welcome Email")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Welcome email sent to #{email_identity.provider_identifier}"

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Firezone"
        assert email.text_body =~ account.slug
      end)
    end

    test "allows sending welcome email with oidc identity", %{
      account: account,
      actor: actor,
      identity: admin_identity,
      conn: conn
    } do
      oidc_email = Fixtures.Auth.email()

      oidc_identity =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor,
          provider_state: %{
            "userinfo" => %{"email" => oidc_email}
          }
        )
        |> Ecto.Changeset.change(
          created_by: :identity,
          created_by_subject: %{"email" => admin_identity.email, "name" => ""}
        )
        |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("#identity-#{oidc_identity.id} button", "Send Welcome Email")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Welcome email sent to #{oidc_email}"

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Firezone"
        assert email.text_body =~ account.slug
      end)
    end

    test "rate limits welcome emails", %{
      account: account,
      actor: actor,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      email_identity =
        Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
        |> Ecto.Changeset.change(
          created_by: :identity,
          created_by_subject: %{"email" => admin_identity.email, "name" => ""}
        )
        |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      for _ <- 1..3 do
        assert lv
               |> element("#identity-#{email_identity.id} button", "Send Welcome Email")
               |> render_click()
               |> Floki.find(".flash-info")
               |> element_to_text() =~
                 "Welcome email sent to #{email_identity.provider_identifier}"
      end

      assert lv
             |> element("#identity-#{email_identity.id} button", "Send Welcome Email")
             |> render_click()
             |> Floki.find(".flash-error")
             |> element_to_text() =~
               "You sent too many welcome emails to this address. Please try again later."
    end

    test "shows email button for identities with email", %{
      account: account,
      actor: actor,
      provider: email_provider,
      identity: admin_identity,
      conn: conn
    } do
      {google_provider, _bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

      google_identity =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor,
          provider: google_provider,
          provider_state: %{
            "userinfo" => %{"email" => Fixtures.Auth.email()}
          }
        )

      {oidc_provider, _bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      oidc_manually_provisioned_identity =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor,
          provider: oidc_provider,
          provider_identifier: Fixtures.Auth.email()
        )

      oidc_identity =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor,
          provider: oidc_provider,
          provider_state: %{
            "userinfo" => %{"email" => Fixtures.Auth.email()}
          }
        )

      oidc_identity_with_no_email =
        Fixtures.Auth.create_identity(
          account: account,
          actor: actor,
          provider: oidc_provider,
          provider_identifier: "sub123"
        )

      email_identity =
        Fixtures.Auth.create_identity(account: account, actor: actor, provider: email_provider)
        |> Ecto.Changeset.change(
          created_by: :identity,
          created_by_subject: %{"email" => admin_identity.email, "name" => ""}
        )
        |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("#identity-#{email_identity.id} button", "Send Welcome Email")
             |> has_element?()

      assert lv
             |> element("#identity-#{google_identity.id} button", "Send Welcome Email")
             |> has_element?()

      assert lv
             |> element(
               "#identity-#{oidc_manually_provisioned_identity.id} button",
               "Send Welcome Email"
             )
             |> has_element?()

      assert lv
             |> element("#identity-#{oidc_identity.id} button", "Send Welcome Email")
             |> has_element?()

      refute lv
             |> element(
               "#identity-#{oidc_identity_with_no_email.id} button",
               "Send Welcome Email"
             )
             |> has_element?()
    end

    test "allows deleting identities", %{
      account: account,
      actor: actor,
      identity: admin_identity,
      conn: conn
    } do
      other_identity =
        Fixtures.Auth.create_identity(account: account, actor: actor)
        |> Ecto.Changeset.change(
          created_by: :identity,
          created_by_subject: %{"email" => admin_identity.email, "name" => ""}
        )
        |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("#identity-#{other_identity.id} button[type=submit]", "Delete")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Identity was deleted."
    end

    test "allows creating identities", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("a", "Add Identity")
      |> render_click()

      assert_redirect(lv, ~p"/#{account}/actors/users/#{actor}/new_identity")

      actor = Fixtures.Actors.update(actor, last_synced_at: DateTime.utc_now())

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("a", "Add Identity")
      |> render_click()

      assert_redirect(lv, ~p"/#{account}/actors/users/#{actor}/new_identity")
    end

    test "renders actor tokens", %{
      account: account,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      Fixtures.Tokens.create_token(
        type: :client,
        account: account,
        identity: identity
      )

      Fixtures.Tokens.create_token(
        account: account,
        identity: identity,
        last_seen_at: DateTime.utc_now(),
        last_seen_remote_ip: Fixtures.Auth.remote_ip()
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      [row1, row2] =
        lv
        |> element("#tokens")
        |> render()
        |> table_to_map()

      assert row1["type"] == "browser"

      assert String.contains?(row1["expires"], "Tomorrow") ||
               String.contains?(row1["expires"], "In 24 hours")

      assert row1["last used"] == "Never"
      assert around_now?(row1["created"])
      assert row1["actions"] =~ "Revoke"

      assert row2["type"] == "client"

      assert String.contains?(row2["expires"], "Tomorrow") ||
               String.contains?(row2["expires"], "In 24 hours")

      assert row2["last used"] == "Never"
      assert around_now?(row2["created"])
      assert row2["actions"] =~ "Revoke"
    end

    test "allows revoking tokens", %{
      account: account,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      token =
        Fixtures.Tokens.create_token(
          type: :client,
          account: account,
          identity: identity
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("td button[type=submit]", "Revoke")
             |> render_click()

      assert lv
             |> element("#tokens")
             |> render()
             |> table_to_map() == []

      assert Repo.get_by(Domain.Tokens.Token, id: token.id).deleted_at
    end

    test "allows revoking all tokens", %{
      account: account,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      token =
        Fixtures.Tokens.create_token(
          type: :client,
          account: account,
          identity: identity
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click()

      assert lv
             |> element("#tokens")
             |> render()
             |> table_to_map() == []

      assert Repo.get_by(Domain.Tokens.Token, id: token.id).deleted_at
    end

    test "allows editing actors", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("a", "Edit User")
             |> render_click() ==
               {:error,
                {:live_redirect, %{to: ~p"/#{account}/actors/#{actor}/edit", kind: :push}}}
    end

    test "allows deleting actors", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("button[type=submit]", "Delete User")
      |> render_click()

      assert_redirect(lv, ~p"/#{account}/actors")

      assert Repo.get(Domain.Actors.Actor, actor.id).deleted_at
    end

    test "allows deleting synced actors that don't have any identities left", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor =
        Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
        |> Fixtures.Actors.update(last_synced_at: DateTime.utc_now())

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("button[type=submit]", "Delete User")
      |> render_click()

      assert_redirect(lv, ~p"/#{account}/actors")

      assert Repo.get(Domain.Actors.Actor, actor.id).deleted_at
    end

    test "renders error when trying to delete last admin", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("button[type=submit]", "Delete User")
             |> render_click()
             |> Floki.find(".flash-error")
             |> element_to_text() =~ "You can't delete the last admin of an account."

      refute Repo.get(Domain.Actors.Actor, actor.id).deleted_at
    end

    test "allows disabling actors", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      refute has_element?(lv, "button", "Enable User")

      assert lv
             |> element("button[type=submit]", "Disable User")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Actor was disabled."

      assert Repo.get(Domain.Actors.Actor, actor.id).disabled_at
    end

    test "renders error when trying to disable last admin", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("button[type=submit]", "Disable User")
             |> render_click()
             |> Floki.find(".flash-error")
             |> element_to_text() =~ "You can't disable the last admin of an account."

      refute Repo.get(Domain.Actors.Actor, actor.id).disabled_at
    end

    test "allows enabling actors", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      actor = Fixtures.Actors.disable(actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      refute has_element?(lv, "button", "Disable User")

      assert lv
             |> element("button[type=submit]", "Enable User")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Actor was enabled."

      refute Repo.get(Domain.Actors.Actor, actor.id).disabled_at
    end
  end

  describe "service accounts" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)

      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)

      identity =
        Fixtures.Auth.create_identity(
          actor: [type: :account_admin_user],
          account: account
        )

      %{
        account: account,
        actor: actor,
        provider: provider,
        identity: identity
      }
    end

    test "renders actor details", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert html =~ "Service Account"

      assert lv
             |> element("#actor")
             |> render()
             |> vertical_table_to_map() == %{
               "last signed in" => "Never",
               "name" => actor.name,
               "role" => "service account"
             }
    end

    test "does not render actor identities", %{
      account: account,
      actor: actor,
      identity: admin_identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      refute has_element?(lv, "#identities")
    end

    test "allows creating tokens", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("a:first-child", "Create Token")
      |> render_click()

      assert_redirect(lv, ~p"/#{account}/actors/service_accounts/#{actor}/new_identity")
    end

    test "allows editing actors", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("a", "Edit Service Account")
             |> render_click() ==
               {:error,
                {:live_redirect, %{to: ~p"/#{account}/actors/#{actor}/edit", kind: :push}}}
    end

    test "allows deleting actors", %{
      account: account,
      identity: identity,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      lv
      |> element("button[type=submit]", "Delete Service Account")
      |> render_click()

      assert_redirect(lv, ~p"/#{account}/actors")

      assert Repo.get(Domain.Actors.Actor, actor.id).deleted_at
    end

    test "allows disabling actors", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      refute has_element?(lv, "button", "Enable Service Account")

      assert lv
             |> element("button[type=submit]", "Disable Service Account")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Actor was disabled."

      assert Repo.get(Domain.Actors.Actor, actor.id).disabled_at
    end

    test "allows enabling actors", %{
      account: account,
      actor: actor,
      identity: identity,
      conn: conn
    } do
      actor = Fixtures.Actors.disable(actor)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/actors/#{actor}")

      refute has_element?(lv, "button", "Disable Service Account")

      assert lv
             |> element("button[type=submit]", "Enable Service Account")
             |> render_click()
             |> Floki.find(".flash-info")
             |> element_to_text() =~ "Actor was enabled."

      refute Repo.get(Domain.Actors.Actor, actor.id).disabled_at
    end

    test "renders actor tokens", %{
      account: account,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      Fixtures.Tokens.create_token(
        type: :client,
        account: account,
        identity: identity
      )

      Fixtures.Tokens.create_token(
        account: account,
        identity: identity,
        last_seen_at: DateTime.utc_now(),
        last_seen_remote_ip: Fixtures.Auth.remote_ip()
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      [row1, row2] =
        lv
        |> element("#tokens")
        |> render()
        |> table_to_map()

      assert row1["type"] == "browser"

      assert String.contains?(row1["expires"], "Tomorrow") ||
               String.contains?(row1["expires"], "In 24 hours")

      assert row1["last used"] == "Never"
      assert around_now?(row1["created"])
      assert row1["actions"] =~ "Revoke"

      assert row2["type"] == "client"

      assert String.contains?(row2["expires"], "Tomorrow") ||
               String.contains?(row2["expires"], "In 24 hours")

      assert row2["last used"] == "Never"
      assert around_now?(row2["created"])
      assert row2["actions"] =~ "Revoke"
    end

    test "allows revoking tokens", %{
      account: account,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      token =
        Fixtures.Tokens.create_token(
          type: :client,
          account: account,
          identity: identity
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("td button[type=submit]", "Revoke")
             |> render_click()

      assert lv
             |> element("#tokens")
             |> render()
             |> table_to_map() == []

      assert Repo.get_by(Domain.Tokens.Token, id: token.id).deleted_at
    end

    test "allows revoking all tokens", %{
      account: account,
      provider: provider,
      identity: admin_identity,
      conn: conn
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      token =
        Fixtures.Tokens.create_token(
          type: :client,
          account: account,
          identity: identity
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(admin_identity)
        |> live(~p"/#{account}/actors/#{actor}")

      assert lv
             |> element("button[type=submit]", "Revoke All")
             |> render_click()

      assert lv
             |> element("#tokens")
             |> render()
             |> table_to_map() == []

      assert Repo.get_by(Domain.Tokens.Token, id: token.id).deleted_at
    end
  end
end
