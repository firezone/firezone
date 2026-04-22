defmodule PortalWeb.PoliciesTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.{Policy, Repo}

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.GroupFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/policies"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "renders policy list page", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      _policy = policy_fixture(group: group, resource: resource)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies")

      assert html =~ "Policies"
      assert html =~ group.name
      assert html =~ resource.name
    end

    test "opens new policy panel from list and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies")

      assert html =~ "New Policy"

      render_click(lv, "open_new_policy_form")
      assert_patch(lv, ~p"/#{account}/policies/new")
      assert render(lv) =~ "Add Policy"

      render_click(lv, "cancel_policy_form")
      assert_patch(lv, ~p"/#{account}/policies")
    end
  end

  describe ":new action" do
    test "renders add policy form", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/new")

      assert html =~ "Add Policy"
      assert html =~ "Group"
      assert html =~ "Resource"
    end

    test "creates a policy on submit", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/new")

      html =
        lv
        |> form("[phx-submit='submit_policy_form']",
          policy: %{
            group_id: group.id,
            resource_id: resource.id,
            description: "Allow group access"
          }
        )
        |> render_submit()

      assert html =~ "created successfully"

      policy =
        Repo.get_by!(Policy,
          group_id: group.id,
          resource_id: resource.id,
          description: "Allow group access"
        )

      assert policy
    end
  end

  describe ":show action" do
    test "renders policy detail panel with group and resource names", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}")

      assert html =~ group.name
      assert html =~ resource.name
    end

    test "closes panel, opens edit form, disables, enables, and cancels delete", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}")

      render_click(lv, "open_edit_form")
      assert_patch(lv, ~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "cancel_policy_form")
      assert_patch(lv, ~p"/#{account}/policies/#{policy.id}")

      html = render_click(lv, "confirm_disable_policy")
      assert html =~ "Disable this policy?"

      render_click(lv, "cancel_disable_policy")
      refute render(lv) =~ "Disable this policy?"

      render_click(lv, "confirm_disable_policy")
      render_click(lv, "disable_policy")

      policy = Repo.get_by!(Policy, id: policy.id, account_id: account.id)
      assert policy.disabled_at

      render_click(lv, "enable_policy")

      policy = Repo.get_by!(Policy, id: policy.id, account_id: account.id)
      assert is_nil(policy.disabled_at)

      html = render_click(lv, "confirm_delete_policy")
      assert html =~ "Delete this policy?"

      render_click(lv, "cancel_delete_policy")
      refute render(lv) =~ "Delete this policy?"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/policies")
    end
  end

  describe ":edit action" do
    test "renders edit policy form", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      assert html =~ "Edit Policy"
      assert html =~ "Group"
      assert html =~ "Resource"
    end

    test "updates policy description and condition state", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource, description: "Old Description")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "toggle_conditions_dropdown")
      assert render_click(lv, "add_condition", %{"type" => "remote_ip"}) =~ "IP Range"

      html =
        lv
        |> element("input[name='_ip_range_input']")
        |> render_change(%{"_ip_range_input" => "10.10.0.0/16"})

      assert html =~ "10.10.0.0/16"

      html = render_click(lv, "add_ip_range_value")
      assert html =~ "10.10.0.0/16"

      html = render_click(lv, "remove_ip_range_value", %{"range" => "10.10.0.0/16"})
      refute html =~ "10.10.0.0/16"

      lv
      |> element("input[name='_ip_range_input']")
      |> render_change(%{"_ip_range_input" => "10.10.0.0/16"})

      render_click(lv, "add_ip_range_value")

      html =
        lv
        |> form("[phx-submit='submit_policy_form']",
          policy: %{
            group_id: group.id,
            resource_id: resource.id,
            description: "Updated Description"
          }
        )
        |> render_submit()

      assert html =~ "updated successfully"

      policy = Repo.get_by!(Policy, id: policy.id, account_id: account.id)
      assert policy.description == "Updated Description"

      assert Enum.any?(
               policy.conditions,
               &(&1.property == :remote_ip and &1.values == ["10.10.0.0/16"])
             )
    end
  end

  describe ":conditions" do
    test "saves time-of-day condition to DB", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "toggle_conditions_dropdown")
      render_click(lv, "add_condition", %{"type" => "current_utc_datetime"})
      render_click(lv, "start_add_tod_range")

      lv
      |> element("input[name='_tod_on']")
      |> render_change(%{"_tod_on" => "09:00"})

      lv
      |> element("input[name='_tod_off']")
      |> render_change(%{"_tod_off" => "17:00"})

      render_click(lv, "toggle_tod_pending_day", %{"day" => "M"})
      render_click(lv, "toggle_tod_pending_day", %{"day" => "T"})
      render_click(lv, "confirm_tod_range")

      html =
        lv
        |> form("[phx-submit='submit_policy_form']",
          policy: %{
            group_id: group.id,
            resource_id: resource.id,
            description: "With TOD condition"
          }
        )
        |> render_submit()

      assert html =~ "updated successfully"

      policy = Repo.get_by!(Policy, id: policy.id, account_id: account.id)

      assert Enum.any?(
               policy.conditions,
               &(&1.property == :current_utc_datetime and
                   "M/09:00-17:00/UTC" in &1.values and
                   "T/09:00-17:00/UTC" in &1.values)
             )
    end

    test "removes a condition from edit form", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "toggle_conditions_dropdown")
      html = render_click(lv, "add_condition", %{"type" => "remote_ip"})
      assert html =~ "IP Range"

      html = render_click(lv, "remove_condition", %{"type" => "remote_ip"})
      refute html =~ "IP Range"
    end

    test "manages auth provider conditions", %{conn: conn, account: account, actor: actor} do
      auth_provider = email_otp_provider_fixture(account: account)
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn_with_provider(actor, auth_provider)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "toggle_conditions_dropdown")
      html = render_click(lv, "add_condition", %{"type" => "auth_provider_id"})
      assert html =~ "Authentication Provider"

      html = render_click(lv, "toggle_auth_provider_value", %{"id" => auth_provider.id})
      assert html =~ auth_provider.name

      html = render_click(lv, "change_auth_provider_operator", %{"operator" => "is_not_in"})
      assert html =~ "is not in"
    end

    test "manages time-of-day conditions via add range form", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "toggle_conditions_dropdown")
      html = render_click(lv, "add_condition", %{"type" => "current_utc_datetime"})

      assert html =~ "Add range"
      refute html =~ ~s(type="time")

      html = render_click(lv, "start_add_tod_range")
      assert html =~ ~s(type="time")
      assert html =~ ~s(name="_tod_on")
      assert html =~ ~s(name="_tod_off")

      for code <- ["M", "T", "W", "R", "F", "S", "U"] do
        assert html =~ ~s(phx-value-day="#{code}")
      end
    end

    test "renders time-of-day condition from saved policy", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)

      policy =
        policy_fixture(
          group: group,
          resource: resource,
          conditions: [
            %{
              property: :current_utc_datetime,
              operator: :is_in_day_of_week_time_ranges,
              values: ["M/09:30-17:45/America/New_York"]
            }
          ]
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      assert html =~ ~s(value="09:30")
      assert html =~ ~s(value="17:45")
    end

    test "manages location conditions", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}/edit")

      render_click(lv, "toggle_conditions_dropdown")
      html = render_click(lv, "add_condition", %{"type" => "remote_ip_location_region"})
      assert html =~ "Search countries"

      html =
        lv
        |> element("input[name='_location_search']")
        |> render_change(%{"_location_search" => "United"})

      assert html =~ "United States"

      html = render_click(lv, "toggle_location_value", %{"code" => "US"})
      assert html =~ "US"

      html = render_click(lv, "toggle_location_value", %{"code" => "US"})
      refute html =~ ">US<"
    end
  end

  describe "delete" do
    test "shows confirm delete then deletes policy", %{conn: conn, account: account, actor: actor} do
      group = group_fixture(account: account)
      resource = resource_fixture(account: account)
      policy = policy_fixture(group: group, resource: resource)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/policies/#{policy.id}")

      html = render_click(lv, "confirm_delete_policy")
      assert html =~ "Delete"

      render_click(lv, "delete_policy")
      assert_patch(lv, ~p"/#{account}/policies")
    end
  end
end
