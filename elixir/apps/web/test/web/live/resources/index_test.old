defmodule Web.Live.Resources.IndexTest do
  use Web.ConnCase, async: true
  alias Domain.Changes

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/resources"

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
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
  end

  test "renders add resource button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/resources/new']")

    assert Floki.text(button) =~ "Add Resource"
  end

  test "hides resource button when feature is disabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:multi_site_resources, false)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/resources/new']")

    refute Floki.text(button) =~ "Add Multi-Site Resource"
  end

  test "renders resources table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_site(account: account)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        site_id: site.id
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    Enum.each(resource_rows, fn row ->
      assert row["name"] =~ resource.name
      assert row["address"] =~ resource.address
      assert row["sites"] =~ site.name
      assert row["authorized groups"] == "None - Create a Policy to grant access."
    end)
  end

  test "sort alphabetically by name ASC by default", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    resource5 = Fixtures.Resources.create_resource(account: account, name: "Resource 5")
    resource4 = Fixtures.Resources.create_resource(account: account, name: "Resource 4")
    resource3 = Fixtures.Resources.create_resource(account: account, name: "Resource 3")
    resource2 = Fixtures.Resources.create_resource(account: account, name: "Resource 2")
    resource1 = Fixtures.Resources.create_resource(account: account, name: "Resource 1")

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    first_row = Enum.at(resource_rows, 0)
    assert first_row["name"] =~ resource1.name

    second_row = Enum.at(resource_rows, 1)
    assert second_row["name"] =~ resource2.name

    third_row = Enum.at(resource_rows, 2)
    assert third_row["name"] =~ resource3.name

    fourth_row = Enum.at(resource_rows, 3)
    assert fourth_row["name"] =~ resource4.name

    fifth_row = Enum.at(resource_rows, 4)
    assert fifth_row["name"] =~ resource5.name
  end

  test "renders authorized groups peek", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_site(account: account)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        site_id: site.id
      )

    policies =
      [
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        ),
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        ),
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        )
      ]
      |> Repo.preload(:group)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    Enum.each(resource_rows, fn row ->
      for policy <- policies do
        assert row["authorized groups"] =~ policy.group.name
      end
    end)

    Fixtures.Policies.create_policy(
      account: account,
      resource: resource
    )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    resource_rows =
      lv
      |> element("#resources")
      |> render()
      |> table_to_map()

    Enum.each(resource_rows, fn row ->
      assert row["authorized groups"] =~ "and 1 more"
    end)
  end

  test "renders Internet Resource section if enabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    account = Fixtures.Accounts.update_account(account, features: %{internet_resource: true})
    site = Fixtures.Sites.create_internet_site(account: account)

    Fixtures.Resources.create_internet_resource(
      account: account,
      site_id: site.id
    )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    path = ~p"/#{account}/resources/internet"

    assert {_, {:live_redirect, %{to: ^path}}} =
             lv
             |> element("#view-internet-resource")
             |> render_click()
  end

  test "does not render Internet Resource section if disabled", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    site = Fixtures.Sites.create_internet_site(account: account)

    Fixtures.Resources.create_internet_resource(
      account: account,
      site_id: site.id
    )

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources")

    refute html =~ "view-internet-resource"
    refute html =~ "View Internet Resource"
  end

  describe "handle_info/2" do
    test "Shows reload button when resource is created", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/resources")

      refute html =~ "The table data has changed."
      refute html =~ "reload-btn"

      resource = Fixtures.Resources.create_resource(account: account)

      # Simulate WAL broadcast
      Changes.Hooks.Resources.on_insert(0, %{
        "id" => resource.id,
        "account_id" => account.id
      })

      reload_btn =
        lv
        |> element("#resources-reload-btn")
        |> render()

      assert reload_btn
    end

    test "Shows reload button when resource is deleted", %{
      account: account,
      identity: identity,
      conn: conn
    } do
      resource = Fixtures.Resources.create_resource(account: account)
      subject = Fixtures.Auth.create_subject(identity: identity)

      {:ok, lv, html} =
        conn
        |> authorize_conn(identity)
        |> live(~p"/#{account}/resources")

      refute html =~ "The table data has changed."
      refute html =~ "reload-btn"

      Domain.Resources.delete_resource(resource, subject)

      Changes.Hooks.Resources.on_delete(
        0,
        %{
          "id" => resource.id,
          "account_id" => account.id
        }
      )

      reload_btn =
        lv
        |> element("#resources-reload-btn")
        |> render()

      assert reload_btn
    end
  end
end
