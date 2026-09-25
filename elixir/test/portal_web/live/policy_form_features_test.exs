defmodule PortalWeb.PolicyFormFeaturesTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.ResourceFixtures

  for page <- [:policies, :resources, :groups],
      {conditions?, posture?, locked} <- [
        {false, false, "policy-restrictions"},
        {true, false, "device-posture"},
        {true, true, nil}
      ] do
    test "#{page} form with conditions=#{conditions?} and posture=#{posture?}", %{conn: conn} do
      account = account_fixture(features: %{policy_conditions: unquote(conditions?), device_posture: unquote(posture?)})
      actor = admin_actor_fixture(account: account)
      resource = resource_fixture(account: account)
      group = group_fixture(account: account)
      conn = authorize_conn(conn, actor)

      html = render_form(unquote(page), conn, account, resource, group)

      document = Floki.parse_fragment!(html)
      locked_sections = Floki.find(document, "[data-locked-section]")

      assert_locked_state(locked_sections, document, html, unquote(locked))

      form_text = document |> Floki.find("form") |> Floki.text()
      assert {flow_position, _} = :binary.match(form_text, "Flow log reporting")
      assert {conditions_position, _} = :binary.match(form_text, "Conditions")
      assert flow_position < conditions_position
    end
  end

  defp render_form(page, conn, account, resource, group) do
    case page do
      :policies ->
        {:ok, _lv, html} = live(conn, ~p"/#{account}/policies/new")
        html

      :resources ->
        {:ok, lv, _html} = live(conn, ~p"/#{account}/resources/#{resource.id}")
        render_click(lv, "open_grant_form")

      :groups ->
        {:ok, lv, _html} = live(conn, ~p"/#{account}/groups/#{group.id}?tab=resources")
        render_click(lv, "open_grant_resource_form")
    end

  end

  defp assert_locked_state(locked_sections, document, html, locked) do
    if locked do
      assert [section] = locked_sections
      assert Floki.attribute(section, "data-locked-section") == [locked]
      assert length(String.split(Floki.text(document), "Upgrade to Unlock")) == 2
      assert Floki.find(section, "[aria-hidden='true']") != []
      refute html =~ ~s(name="policy[postures]")
    else
      assert locked_sections == []
      refute html =~ "Upgrade to Unlock"
      assert html =~ ~s(name="policy[postures]")
    end

  end
end
