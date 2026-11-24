defmodule PortalWeb.Access.SimulatorTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  setup %{conn: conn} do
    account = account_fixture()
    admin = admin_actor_fixture(account: account)
    subject = subject_fixture(account: account, actor: admin)
    site = site_fixture(account: account, name: "Production")

    %{
      conn: authorize_conn_with_provider(conn, admin, %{id: subject.credential.auth_provider_id}),
      account: account,
      site: site
    }
  end

  defp simulate(conn, account, params) do
    {:ok, lv, _html} = live(conn, ~p"/#{account}/access/simulator?#{params}")
    render_async(lv)
    lv
  end

  defp member(account, group, name) do
    actor = actor_fixture(account: account, name: name)
    membership_fixture(account: account, group: group, actor: actor)
    actor
  end

  defp match_order(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#simulator-matches li[id^='simulator-match-']")
    |> Enum.flat_map(&Floki.attribute(&1, "id"))
  end

  defp path_html(lv, index) do
    lv |> element("#simulator-path-#{index}") |> render()
  end

  test "redirects to sign in when not authenticated", %{account: account} do
    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/#{account}/access/simulator")
    assert to =~ "sign_in"
  end

  test "is a tab of the Access section", %{conn: conn, account: account} do
    {:ok, lv, _html} = live(conn, ~p"/#{account}/access/simulator")

    assert has_element?(lv, "a[href='/#{account.slug}/access/simulator']", "Simulator")
    assert has_element?(lv, "#simulator-intro")
  end

  test "submitting the form puts the query in the URL", %{conn: conn, account: account} do
    {:ok, lv, _html} = live(conn, ~p"/#{account}/access/simulator")

    lv
    |> form("#simulator-form", simulation: %{address: "10.1.2.3", protocol: "udp", port: "53"})
    |> render_submit()

    assert_patch(lv, ~p"/#{account}/access/simulator?#{[address: "10.1.2.3", port: "53", protocol: "udp"]}")
    render_async(lv)
    assert has_element?(lv, "#simulator-summary", "UDP 53")
  end

  test "rejects an address that is not an IP or a name, and a bad port", %{conn: conn, account: account} do
    lv = simulate(conn, account, address: "not an address!", protocol: "tcp", port: "99999")

    assert has_element?(lv, "#simulator-address-error")
    assert has_element?(lv, "#simulator-port-error")
    refute has_element?(lv, "#simulator-result")
  end

  test "orders CIDR resources by the longest prefix and stops at an unconditional policy", %{
    conn: conn,
    account: account,
    site: site
  } do
    wide = cidr_resource_fixture(account: account, site: site, name: "Corp", address: "10.0.0.0/8")
    narrow = cidr_resource_fixture(account: account, site: site, name: "Lab", address: "10.1.0.0/16")
    exact = ip_resource_fixture(account: account, site: site, name: "Printer", address: "10.1.2.3")
    _other = cidr_resource_fixture(account: account, site: site, name: "Other", address: "192.168.0.0/16")

    everyone = group_fixture(account: account, name: "Staff")
    lab = group_fixture(account: account, name: "Lab team")
    policy_fixture(account: account, group: everyone, resource: wide)
    policy_fixture(account: account, group: lab, resource: narrow)

    member(account, everyone, "Ada")
    both = member(account, lab, "Grace")
    membership_fixture(account: account, group: everyone, actor: both)

    lv = simulate(conn, account, address: "10.1.2.3", protocol: "tcp", port: "443")

    assert match_order(lv) == [
             "simulator-match-#{exact.id}",
             "simulator-match-#{narrow.id}",
             "simulator-match-#{wide.id}"
           ]

    assert has_element?(lv, "#simulator-match-#{exact.id}", "No policy")
    assert has_element?(lv, "#simulator-summary", "3 resources cover it, and 2 actors can reach it.")

    # Grace has the /16, so the /8 never applies to her.
    paths = [path_html(lv, 0), path_html(lv, 1)]
    grace = Enum.find(paths, &(&1 =~ "Grace"))
    ada = Enum.find(paths, &(&1 =~ "Ada"))

    assert grace =~ "Reaches it through Lab"
    refute grace =~ "Corp"
    assert ada =~ "Reaches it through Corp"
  end

  test "prefers the narrower filter on the same network, and reports filters that refuse", %{
    conn: conn,
    account: account,
    site: site
  } do
    open = cidr_resource_fixture(account: account, site: site, name: "Open", address: "10.2.0.0/16")

    https =
      cidr_resource_fixture(
        account: account,
        site: site,
        name: "HTTPS only",
        address: "10.2.0.0/16",
        filters: [%{protocol: :tcp, ports: ["443"]}]
      )

    ssh =
      cidr_resource_fixture(
        account: account,
        site: site,
        name: "SSH only",
        address: "10.2.0.0/24",
        filters: [%{protocol: :tcp, ports: ["22"]}]
      )

    group = group_fixture(account: account, name: "Ops")
    policy_fixture(account: account, group: group, resource: open)
    policy_fixture(account: account, group: group, resource: https)
    member(account, group, "Linus")

    blocked_group = group_fixture(account: account, name: "Admins")
    policy_fixture(account: account, group: blocked_group, resource: ssh)
    member(account, blocked_group, "Ken")

    lv = simulate(conn, account, address: "10.2.0.9", protocol: "tcp", port: "443")

    assert match_order(lv) == [
             "simulator-match-#{ssh.id}",
             "simulator-match-#{https.id}",
             "simulator-match-#{open.id}"
           ]

    assert has_element?(lv, "#simulator-match-#{ssh.id}[data-allowed='false']", "Filters refuse TCP 443")
    assert has_element?(lv, "#simulator-path-0[data-reaches='true']", "Reaches it through HTTPS only")
    assert has_element?(lv, "#simulator-path-1[data-reaches='false']", "Blocked by the filters on SSH only")
    assert path_html(lv, 1) =~ "Ken"
  end

  test "a conditional policy falls back to the next resource", %{conn: conn, account: account, site: site} do
    wide = cidr_resource_fixture(account: account, site: site, name: "Corp", address: "10.0.0.0/8")
    narrow = cidr_resource_fixture(account: account, site: site, name: "Lab", address: "10.3.0.0/16")
    group = group_fixture(account: account, name: "Engineering")

    policy_fixture(
      account: account,
      group: group,
      resource: narrow,
      conditions: [%{property: :remote_ip, operator: :is_in_cidr, values: ["203.0.113.0/24"]}]
    )

    policy_fixture(account: account, group: group, resource: wide)
    member(account, group, "Barbara")

    lv = simulate(conn, account, address: "10.3.4.5", protocol: "tcp", port: "22")

    html = path_html(lv, 0)
    assert html =~ "Reaches it through Lab"
    assert html =~ "203.0.113.0/24"
    assert html =~ "Else"
    assert html =~ "Corp"
    assert html =~ "No conditions or posture checks"
  end

  test "orders DNS resources like connlib and matches the apex with *.", %{
    conn: conn,
    account: account,
    site: site
  } do
    exact = dns_resource_fixture(account: account, site: site, name: "GitLab", address: "gitlab.example.com")
    single = dns_resource_fixture(account: account, site: site, name: "One label", address: "*.example.com")
    any = dns_resource_fixture(account: account, site: site, name: "Any depth", address: "**.example.com")
    other = dns_resource_fixture(account: account, site: site, name: "Other", address: "*.example.org")

    lv = simulate(conn, account, address: "GitLab.Example.com.", protocol: "tcp", port: "443")

    assert match_order(lv) == [
             "simulator-match-#{exact.id}",
             "simulator-match-#{single.id}",
             "simulator-match-#{any.id}"
           ]

    refute has_element?(lv, "#simulator-match-#{other.id}")
    assert has_element?(lv, "#simulator-notes", "own DNS")

    lv = simulate(conn, account, address: "example.com", protocol: "tcp", port: "443")
    assert match_order(lv) == ["simulator-match-#{single.id}", "simulator-match-#{any.id}"]

    lv = simulate(conn, account, address: "a.b.example.com", protocol: "tcp", port: "443")
    assert match_order(lv) == ["simulator-match-#{any.id}"]
  end

  test "actors who reach the same resource without conditions share one row", %{
    conn: conn,
    account: account,
    site: site
  } do
    resource = ip_resource_fixture(account: account, site: site, name: "Jenkins", address: "10.8.8.8")
    builders = group_fixture(account: account, name: "Builders")
    testers = group_fixture(account: account, name: "Testers")
    policy_fixture(account: account, group: builders, resource: resource)
    policy_fixture(account: account, group: testers, resource: resource)
    member(account, builders, "Alan")
    member(account, testers, "Joan")

    lv = simulate(conn, account, address: "10.8.8.8", protocol: "tcp", port: "8080")

    refute has_element?(lv, "#simulator-path-1")
    html = path_html(lv, 0)
    assert html =~ "2 actors"
    assert html =~ "Builders"
    assert html =~ "Testers"
  end

  test "the Everyone group holds every user but no service account", %{
    conn: conn,
    account: account,
    site: site
  } do
    resource = ip_resource_fixture(account: account, site: site, name: "Wiki", address: "10.9.9.9")
    everyone = managed_group_fixture(account: account, name: "Everyone")
    policy_fixture(account: account, group: everyone, resource: resource)
    actor_fixture(account: account, name: "Margaret")
    service_account_fixture(account: account, name: "CI bot")

    lv = simulate(conn, account, address: "10.9.9.9", protocol: "tcp", port: "80")

    html = path_html(lv, 0)
    assert html =~ "Margaret"
    refute html =~ "CI bot"
  end

  test "the Internet Resource catches what nothing else covers", %{conn: conn, account: account} do
    internet = internet_resource_fixture(account: account)
    group = group_fixture(account: account, name: "Remote")
    policy_fixture(account: account, group: group, resource: internet)
    member(account, group, "Radia")

    lv = simulate(conn, account, address: "1.1.1.1", protocol: "icmp")

    assert match_order(lv) == ["simulator-match-#{internet.id}"]
    assert has_element?(lv, "#simulator-summary", "ICMP")
    assert path_html(lv, 0) =~ "Internet Resource turned on"
  end

  test "device pools decide who reaches a device's tunnel address", %{conn: conn, account: account} do
    owner = actor_fixture(account: account, name: "Owner")
    device = client_fixture(account: account, actor: owner, name: "build-box", ipv4_address: %Postgrex.INET{address: {100, 64, 1, 2}})
    pool = device_pool_resource_fixture(account: account, name: "Build boxes", devices: [device])
    empty_pool = device_pool_resource_fixture(account: account, name: "Empty pool", devices: [])

    group = group_fixture(account: account, name: "Builders")
    policy_fixture(account: account, group: group, resource: pool)
    member(account, group, "Dennis")

    outsiders = group_fixture(account: account, name: "Outsiders")
    policy_fixture(account: account, group: outsiders, resource: empty_pool)
    member(account, outsiders, "Ken")

    lv = simulate(conn, account, address: "100.64.1.2", protocol: "tcp", port: "22")

    assert has_element?(lv, "#simulator-notes", "build-box uses this tunnel address")
    assert has_element?(lv, "#simulator-path-0[data-reaches='true']", "Reaches it through Build boxes")
    assert has_element?(lv, "#simulator-path-1[data-reaches='false']", "Refused: Empty pool does not hold this device")
  end

  test "says when nothing covers the address", %{conn: conn, account: account} do
    lv = simulate(conn, account, address: "2001:db8::1", protocol: "tcp", port: "443")

    assert has_element?(lv, "#simulator-summary", "no resource covers it.")
    assert has_element?(lv, "#simulator-nobody")
  end
end
