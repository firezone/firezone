defmodule PortalWeb.Access.ByGroupTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SubjectFixtures

  setup %{conn: conn} do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    subject = subject_fixture(account: account, actor: actor)
    conn = authorize_conn_with_provider(conn, actor, %{id: subject.credential.auth_provider_id})
    %{conn: conn, account: account, subject: subject}
  end

  defp open(conn, path) do
    {:ok, lv, _html} = live(conn, path)
    render_async(lv)
    lv
  end

  test "lists what each group can reach with links to the policies", %{conn: conn, account: account} do
    group = group_fixture(account: account, name: "Engineering")
    gitlab = resource_fixture(account: account, name: "GitLab")
    wiki = resource_fixture(account: account, name: "Wiki")
    gitlab_policy = policy_fixture(account: account, group: group, resource: gitlab)
    wiki_policy = policy_fixture(account: account, group: group, resource: wiki)
    lonely = group_fixture(account: account, name: "Lonely")

    lv = open(conn, ~p"/#{account}/access/by_group")

    row = "#groups-#{group.id}"
    assert has_element?(lv, "#{row} a[href='/#{account.slug}/policies/#{gitlab_policy.id}']", "GitLab")
    assert has_element?(lv, "#{row} a[href='/#{account.slug}/policies/#{wiki_policy.id}']", "Wiki")
    assert has_element?(lv, "#{row} td:last-child", "2")
    assert has_element?(lv, "#groups-#{lonely.id}", "Nothing")
  end

  test "search narrows the groups", %{conn: conn, account: account} do
    engineering = group_fixture(account: account, name: "Engineering")
    finance = group_fixture(account: account, name: "Finance")

    {:ok, lv, _html} = live(conn, ~p"/#{account}/access/by_group?groups_filter[name]=finance")
    render_async(lv)

    assert has_element?(lv, "#groups-#{finance.id}")
    refute has_element?(lv, "#groups-#{engineering.id}")
  end

  test "never lists direct-access groups", %{conn: conn, account: account, subject: subject} do
    resource = resource_fixture(account: account, name: "Prod DB")
    alice = actor_fixture(account: account, name: "Alice")
    {:ok, direct} = PortalWeb.DirectAccess.grant(resource, [alice.id], subject)

    lv = open(conn, ~p"/#{account}/access/by_group")

    refute has_element?(lv, "#groups-#{direct.id}")
  end
end
