defmodule PortalWeb.Access.ByResourceTest do
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

  test "lists who reaches each resource, people as a count", %{conn: conn, account: account, subject: subject} do
    resource = resource_fixture(account: account, name: "GitLab")
    group = group_fixture(account: account, name: "Engineering")
    policy = policy_fixture(account: account, group: group, resource: resource)

    people =
      for name <- ~w[Alice Bob Carol Dave] do
        actor_fixture(account: account, name: name).id
      end

    {:ok, direct} = PortalWeb.DirectAccess.grant(resource, people, subject)
    direct_policy = Portal.Repo.get_by!(Portal.Policy, group_id: direct.id)
    unused = resource_fixture(account: account, name: "Unused")

    lv = open(conn, ~p"/#{account}/access/by_resource")

    row = "#resources-#{resource.id}"
    assert has_element?(lv, "#{row} a[href='/#{account.slug}/policies/#{policy.id}']", "Engineering")
    assert has_element?(lv, "#{row} a[href='/#{account.slug}/policies/#{direct_policy.id}']", "4 people")
    refute render(lv) =~ direct.name
    assert has_element?(lv, "#resources-#{unused.id}", "Nobody")
  end

  test "search matches the name or address", %{conn: conn, account: account} do
    gitlab = resource_fixture(account: account, name: "GitLab", type: :dns, address: "gitlab.example.com")
    wiki = resource_fixture(account: account, name: "Wiki", type: :dns, address: "wiki.example.com")

    {:ok, lv, _html} = live(conn, ~p"/#{account}/access/by_resource?resources_filter[name_or_address]=gitlab")
    render_async(lv)

    assert has_element?(lv, "#resources-#{gitlab.id}")
    refute has_element?(lv, "#resources-#{wiki.id}")
  end
end
