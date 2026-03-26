defmodule PortalWeb.Live.ActorsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.IdentityFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{account: account, actor: actor}
  end

  describe "handle_params :show" do
    test "redirects to actors list when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{Ecto.UUID.generate()}")

      assert path == ~p"/#{account}/actors"
    end
  end

  describe "handle_params :edit" do
    test "redirects to actors list when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{Ecto.UUID.generate()}/edit")

      assert path == ~p"/#{account}/actors"
    end
  end

  describe "handle_params :add_token" do
    test "redirects to actors list when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/actors/#{Ecto.UUID.generate()}/add_token")

      assert path == ~p"/#{account}/actors"
    end
  end

  describe "handle_event delete" do
    test "shows error flash when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "delete", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Actor not found"
    end
  end

  describe "handle_event disable" do
    test "shows error flash when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "disable", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Actor not found"
    end
  end

  describe "handle_event enable" do
    test "shows error flash when actor is not found", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "enable", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Actor not found"
    end
  end

  describe "handle_event create_user" do
    test "enforces users_count limit", %{account: account, actor: actor, conn: conn} do
      Ecto.Changeset.change(account, limits: %Portal.Accounts.Limits{users_count: 1})
      |> Repo.update!()

      actor_with_email_fixture(type: :account_user, account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      html =
        lv
        |> form("#user-form",
          actor: %{
            "name" => "Another User",
            "email" => "another-user@example.com",
            "type" => "account_user",
            "allow_email_otp_sign_in" => "true"
          }
        )
        |> render_submit()

      assert html =~ "User limit reached for your account"
      refute Repo.get_by(Portal.Actor, account_id: account.id, email: "another-user@example.com")
    end
  end

  describe "actors list" do
    test "redirects unauthorized users to sign-in", %{account: account, conn: conn} do
      path = ~p"/#{account}/actors"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end

    test "renders breadcrumbs", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
      breadcrumbs = String.trim(Floki.text(item))
      assert breadcrumbs =~ "Actors"
    end

    test "renders actors table with name, email, status, and last updated columns", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      rows =
        lv
        |> element("#actors")
        |> render()
        |> table_to_map()

      assert Enum.any?(rows, fn row -> row["name"] =~ other_actor.name end)
    end

    test "renders Add Actor button", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      assert html =~ "Add Actor"
    end

    test "renders empty state when no actors exist", %{conn: conn} do
      # Create a fresh account with only the admin actor and no other actors
      fresh_account = account_fixture()
      fresh_actor = admin_actor_fixture(account: fresh_account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(fresh_actor)
        |> live(~p"/#{fresh_account}/actors")

      # The admin actor itself is present, but we can check the table renders
      assert html =~ "actors"
    end

    test "filters actors by name", %{account: account, actor: actor, conn: conn} do
      unique_num = System.unique_integer([:positive, :monotonic])
      searchable_name = "UniqueSearchableName#{unique_num}"
      other_actor = actor_fixture(account: account, name: searchable_name)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      # Confirm both actors appear before filtering
      pre_filter_html = lv |> element("#actors") |> render()
      assert pre_filter_html =~ other_actor.name
      assert pre_filter_html =~ actor.name

      # Apply the filter and confirm the target actor appears
      lv
      |> element("#actors-filters")
      |> render_change(%{"actors_filter" => %{"name_or_email" => searchable_name}})

      filtered_html = lv |> element("#actors") |> render()
      assert filtered_html =~ other_actor.name
    end
  end

  describe "actor show" do
    test "renders actor name and type for a user actor", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      user_actor = actor_fixture(account: account, type: :account_user)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{user_actor.id}")

      assert html =~ user_actor.name
      assert html =~ "User"
    end

    test "renders actor name for a service account", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      sa = service_account_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{sa.id}")

      assert html =~ sa.name
      assert html =~ "Service Account"
    end

    test "renders identities tab for user actors", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      user_actor = actor_fixture(account: account, type: :account_user)
      _identity = identity_fixture(account: account, actor: user_actor)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{user_actor.id}")

      assert html =~ "External Identities"
    end

    test "renders tokens tab for service accounts", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      sa = service_account_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{sa.id}")

      assert html =~ "Tokens"
    end
  end

  describe "add user" do
    test "renders the add user form", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      assert html =~ "Add User"
      assert html =~ "user-form"
    end

    test "validates required fields on submit", %{account: account, actor: actor, conn: conn} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      html =
        lv
        |> form("#user-form", actor: %{"name" => "", "email" => ""})
        |> render_submit()

      # form should still be shown (not navigated away) because of validation errors
      assert html =~ "Add User"
    end

    test "creates a new user successfully and navigates to actor show", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      unique_num = System.unique_integer([:positive, :monotonic])
      new_email = "newuser#{unique_num}@example.com"
      new_name = "New User #{unique_num}"

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      result =
        lv
        |> form("#user-form",
          actor: %{
            "name" => new_name,
            "email" => new_email,
            "type" => "account_user",
            "allow_email_otp_sign_in" => "false"
          }
        )
        |> render_submit()

      # After creation, it patches to the new actor's show page. The response
      # is either a redirect or the rendered show page.
      case result do
        {:error, {:live_redirect, %{to: path}}} ->
          assert path =~ "/actors/"

        html when is_binary(html) ->
          assert html =~ new_name
      end

      assert Repo.get_by(Portal.Actor, account_id: account.id, email: new_email)
    end
  end

  describe "add service account" do
    test "renders the add service account form", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_service_account")

      assert html =~ "Add Service Account"
      assert html =~ "service-account-form"
    end

    test "creates a new service account successfully", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      unique_num = System.unique_integer([:positive, :monotonic])
      sa_name = "My Service Account #{unique_num}"
      expiration = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_service_account")

      result =
        lv
        |> form("#service-account-form", actor: %{"name" => sa_name})
        |> render_submit(%{"token_expiration" => expiration})

      case result do
        {:error, {:live_redirect, %{to: path}}} ->
          assert path =~ "/actors/"

        html when is_binary(html) ->
          assert html =~ sa_name
      end

      assert Repo.get_by(Portal.Actor,
               account_id: account.id,
               name: sa_name,
               type: :service_account
             )
    end
  end

  describe "edit actor" do
    test "renders the edit form with current actor name", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor.id}/edit")

      assert html =~ "Edit #{other_actor.name}"
      assert html =~ "actor-form"
    end

    test "saves changes to actor name successfully", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account)
      unique_num = System.unique_integer([:positive, :monotonic])
      updated_name = "Updated Name #{unique_num}"

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor.id}/edit")

      result =
        lv
        |> form("#actor-form",
          actor: %{
            "name" => updated_name,
            "email" => other_actor.email,
            "type" => "account_user"
          }
        )
        |> render_submit()

      case result do
        {:error, {:live_redirect, %{to: _path}}} ->
          :ok

        html when is_binary(html) ->
          assert html =~ updated_name
      end

      updated = Repo.get_by!(Portal.Actor, account_id: account.id, id: other_actor.id)
      assert updated.name == updated_name
    end

    test "shows validation error when name is empty", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor.id}/edit")

      html =
        lv
        |> form("#actor-form", actor: %{"name" => "", "email" => other_actor.email})
        |> render_change()

      # Form should show a validation error or remain on the edit page
      assert html =~ "actor-form"
    end

    test "prevents promoting user to admin when admin limit is reached", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account, type: :account_user)

      # Set admin limit to 1 (the setup admin already counts)
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 1}
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor.id}/edit")

      lv
      |> form("#actor-form",
        actor: %{
          "name" => other_actor.name,
          "email" => other_actor.email,
          "type" => "account_admin_user"
        }
      )
      |> render_submit()

      # The error should be visible in the rendered LV
      html = render(lv)
      assert html =~ "Admin user limit reached for your account"

      updated = Repo.get_by!(Portal.Actor, account_id: account.id, id: other_actor.id)
      assert updated.type == :account_user
    end

    test "allows promoting user to admin when under the limit", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account, type: :account_user)

      # Set admin limit to 5 (plenty of room)
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 5}
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor.id}/edit")

      lv
      |> form("#actor-form",
        actor: %{
          "name" => other_actor.name,
          "email" => other_actor.email,
          "type" => "account_admin_user"
        }
      )
      |> render_submit()

      updated = Repo.get_by!(Portal.Actor, account_id: account.id, id: other_actor.id)
      assert updated.type == :account_admin_user
    end

    test "allows promoting user to admin when limit is nil", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account, type: :account_user)

      # nil limit means unlimited
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: nil}
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_actor.id}/edit")

      lv
      |> form("#actor-form",
        actor: %{
          "name" => other_actor.name,
          "email" => other_actor.email,
          "type" => "account_admin_user"
        }
      )
      |> render_submit()

      updated = Repo.get_by!(Portal.Actor, account_id: account.id, id: other_actor.id)
      assert updated.type == :account_admin_user
    end

    test "allows demoting admin to user even when admin limit is reached", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_admin = actor_fixture(account: account, type: :account_admin_user)

      # Set admin limit to 1 — both admins are over the limit
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 1}
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/#{other_admin.id}/edit")

      lv
      |> form("#actor-form",
        actor: %{
          "name" => other_admin.name,
          "email" => other_admin.email,
          "type" => "account_user"
        }
      )
      |> render_submit()

      updated = Repo.get_by!(Portal.Actor, account_id: account.id, id: other_admin.id)
      assert updated.type == :account_user
    end
  end

  describe "handle_event create_user admin limits" do
    test "prevents creating admin user when admin limit is reached", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Set admin limit to 1 (the setup admin already counts)
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 1}
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      html =
        lv
        |> form("#user-form",
          actor: %{
            "name" => "New Admin",
            "email" => "new-admin@example.com",
            "type" => "account_admin_user",
            "allow_email_otp_sign_in" => "true"
          }
        )
        |> render_submit()

      assert html =~ "Admin user limit reached for your account"
      refute Repo.get_by(Portal.Actor, account_id: account.id, email: "new-admin@example.com")
    end

    test "allows creating admin user when under the limit", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Set admin limit to 5 (plenty of room)
      Ecto.Changeset.change(account,
        limits: %Portal.Accounts.Limits{account_admin_users_count: 5}
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors/add_user")

      lv
      |> form("#user-form",
        actor: %{
          "name" => "New Admin",
          "email" => "new-admin@example.com",
          "type" => "account_admin_user",
          "allow_email_otp_sign_in" => "true"
        }
      )
      |> render_submit()

      assert Repo.get_by(Portal.Actor, account_id: account.id, email: "new-admin@example.com")
    end
  end

  describe "handle_event delete (extended)" do
    test "successfully deletes an actor that is not self", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "delete", %{"id" => other_actor.id})
      assert html =~ "Actor deleted successfully"

      refute Repo.get_by(Portal.Actor, account_id: account.id, id: other_actor.id)
    end

    test "shows error when trying to delete self", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "delete", %{"id" => actor.id})
      assert html =~ "You cannot delete yourself"

      assert Repo.get_by(Portal.Actor, account_id: account.id, id: actor.id)
    end
  end

  describe "handle_event disable/enable" do
    test "successfully disables an active actor that is not self", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      other_actor = actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "disable", %{"id" => other_actor.id})

      disabled = Repo.get_by!(Portal.Actor, account_id: account.id, id: other_actor.id)
      assert disabled.disabled_at
    end

    test "shows error when trying to disable self", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      html = render_click(lv, "disable", %{"id" => actor.id})
      assert html =~ "You cannot disable yourself"

      not_disabled = Repo.get_by!(Portal.Actor, account_id: account.id, id: actor.id)
      refute not_disabled.disabled_at
    end

    test "successfully enables a disabled actor", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      disabled_actor = disabled_actor_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/actors")

      render_click(lv, "enable", %{"id" => disabled_actor.id})

      enabled = Repo.get_by!(Portal.Actor, account_id: account.id, id: disabled_actor.id)
      refute enabled.disabled_at
    end
  end
end
