defmodule PortalWeb.GettingStartedTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyAuthorizationFixtures
  import Ecto.Query, only: [from: 2]

  setup do
    account = account_fixture()
    %{account: account}
  end

  defp put_getting_started(actor, value) do
    actor
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:preferences, %Portal.Actor.Preferences{getting_started: value})
    |> Portal.Repo.update!()
  end

  defp getting_started(actor) do
    case Portal.Repo.get_by!(Portal.Actor, account_id: actor.account_id, id: actor.id).preferences do
      nil -> nil
      preferences -> preferences.getting_started
    end
  end

  defp open_sites(conn, account, actor) do
    {:ok, view, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
    view
  end

  defp online(device) do
    :ok = Portal.Presence.Devices.Account.track(device)
    device
  end

  # The guide checks presence on a timer, so wait for it to catch up
  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp status_done?(view, step) do
    has_element?(view, ~s(#getting-started-status-#{step}[data-done="true"]))
  end

  defp continue(view), do: view |> element("#getting-started-continue") |> render_click()

  describe "a new account owner" do
    setup %{account: account} do
      actor =
        admin_actor_fixture(account: account, name: "Ada Lovelace")
        |> put_getting_started(:pending)

      %{actor: actor}
    end

    test "sees the goal chooser, greeted by first name", %{conn: conn, account: account, actor: actor} do
      view = open_sites(conn, account, actor)

      assert has_element?(view, "#getting-started-modal", "Welcome to Firezone, Ada")
      assert has_element?(view, "#getting-started-modal", "What would you like to do first?")
      assert has_element?(view, "#getting-started-goal-device_mesh", "Connect my devices")
      assert has_element?(view, "#getting-started-goal-remote_access", "Reach a remote network or service")
      assert has_element?(view, "#getting-started-explore", "I'll explore on my own")
    end

    test "choosing to connect devices saves the goal and starts its first step", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      view = open_sites(conn, account, actor)

      view |> element("#getting-started-goal-device_mesh") |> render_click()

      assert has_element?(view, "#getting-started-modal h3", "Connect your devices")
      assert has_element?(view, "#getting-started-mesh-step-0", "Install Firezone on this computer")
      assert getting_started(actor) == :device_mesh
    end

    test "choosing to reach a remote network saves the goal and starts its first step", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      view = open_sites(conn, account, actor)

      view |> element("#getting-started-goal-remote_access") |> render_click()

      assert has_element?(view, "#getting-started-modal h3", "Reach a remote network or service")
      assert has_element?(view, "#getting-started-remote-step-0", "Install Firezone on this computer")
      assert getting_started(actor) == :remote_access
    end

    test "exploring on their own dismisses the guide", %{conn: conn, account: account, actor: actor} do
      view = open_sites(conn, account, actor)

      view |> element("#getting-started-explore") |> render_click()

      refute has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == :dismissed
    end

    test "closing the modal dismisses the guide", %{conn: conn, account: account, actor: actor} do
      view = open_sites(conn, account, actor)

      view |> element("#getting-started-modal") |> render_hook("dismiss", %{})

      refute has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == :dismissed
    end

    test "ignores unknown goals", %{conn: conn, account: account, actor: actor} do
      view = open_sites(conn, account, actor)

      view |> element("#getting-started-modal") |> render_hook("choose", %{"goal" => "nope"})

      assert has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == :pending
    end

    test "only sees the chooser once", %{conn: conn, account: account, actor: actor} do
      conn = authorize_conn(conn, actor)
      {:ok, view, _html} = live(conn, ~p"/#{account}/sites")
      view |> element("#getting-started-goal-remote_access") |> render_click()

      {:ok, view, _html} = live(conn, ~p"/#{account}/resources")
      refute has_element?(view, "#getting-started-modal")
    end

    test "keeps the chooser closed when the page re-renders", %{conn: conn, account: account, actor: actor} do
      view = open_sites(conn, account, actor)
      view |> element("#getting-started-explore") |> render_click()

      # The subject held by the page still says :pending until the next mount
      render_patch(view, ~p"/#{account}/sites?getting_started_test=1")

      refute has_element?(view, "#getting-started-modal")
    end

    test "is greeted without a name when it is blank", %{conn: conn, account: account, actor: actor} do
      actor = actor |> Ecto.Changeset.change(name: " ") |> Portal.Repo.update!()

      view = open_sites(conn, account, actor)

      assert has_element?(view, "#getting-started-modal h3", "Welcome to Firezone 👋")
    end
  end

  describe "reopening from the user menu" do
    test "opens the chooser for an admin who was never offered it", %{conn: conn, account: account} do
      actor = admin_actor_fixture(account: account)
      view = open_sites(conn, account, actor)

      assert has_element?(view, "#open-getting-started", "Getting started")
      view |> element("#open-getting-started") |> render_click()

      assert has_element?(view, "#getting-started-modal", "What would you like to do first?")
    end

    test "closing it again changes nothing", %{conn: conn, account: account} do
      actor = admin_actor_fixture(account: account)
      view = open_sites(conn, account, actor)

      view |> element("#open-getting-started") |> render_click()
      view |> element("#getting-started-explore") |> render_click()

      refute has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == nil
    end

    test "does not overwrite a goal picked earlier when closed", %{conn: conn, account: account} do
      actor = admin_actor_fixture(account: account) |> put_getting_started(:device_mesh)
      view = open_sites(conn, account, actor)

      view |> element("#open-getting-started") |> render_click()
      view |> element("#getting-started-modal") |> render_hook("dismiss", %{})

      refute has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == :device_mesh
    end

    test "saves a newly picked goal", %{conn: conn, account: account} do
      actor = admin_actor_fixture(account: account) |> put_getting_started(:dismissed)
      view = open_sites(conn, account, actor)

      view |> element("#open-getting-started") |> render_click()
      view |> element("#getting-started-goal-remote_access") |> render_click()

      assert has_element?(view, "#getting-started-remote-step-0")
      assert getting_started(actor) == :remote_access
    end

    test "can be reopened after the first-time chooser was dismissed", %{conn: conn, account: account} do
      actor = admin_actor_fixture(account: account) |> put_getting_started(:pending)
      view = open_sites(conn, account, actor)

      view |> element("#getting-started-explore") |> render_click()
      view |> element("#open-getting-started") |> render_click()

      assert has_element?(view, "#getting-started-modal")
    end
  end

  describe "an existing admin" do
    test "never offered the guide does not see it", %{conn: conn, account: account} do
      actor = admin_actor_fixture(account: account)

      view = open_sites(conn, account, actor)

      refute has_element?(view, "#getting-started-modal")
    end

    for value <- [:device_mesh, :remote_access, :dismissed] do
      test "who already answered with #{value} does not see it", %{conn: conn, account: account} do
        actor = admin_actor_fixture(account: account) |> put_getting_started(unquote(value))

        view = open_sites(conn, account, actor)

        refute has_element?(view, "#getting-started-modal")
      end
    end
  end

  describe "connect my devices" do
    setup %{account: account} do
      actor = admin_actor_fixture(account: account) |> put_getting_started(:device_mesh)
      %{actor: actor}
    end

    defp open_mesh(conn, account, actor) do
      view = open_sites(conn, account, actor)
      view |> element("#open-getting-started") |> render_click()
      view
    end


    test "walks through all three steps as devices come online and connect", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      view = open_mesh(conn, account, actor)

      # Step 1: this computer
      assert has_element?(view, "#getting-started-mesh-step-0")
      assert has_element?(view, "#getting-started-status-0", "Waiting for this computer to sign in")
      assert has_element?(view, "#getting-started-continue[disabled]")

      first = client_fixture(account: account, actor: actor, name: "ada-laptop") |> online()
      assert eventually(fn -> status_done?(view, 0) end)
      assert has_element?(view, "#getting-started-status-0", "ada-laptop is online")
      assert has_element?(view, "#getting-started-status-0", Portal.Device.fqdn(first))
      refute has_element?(view, "#getting-started-continue[disabled]")

      # Step 2: another computer
      continue(view)
      assert has_element?(view, "#getting-started-mesh-step-1")
      assert has_element?(view, "#getting-started-account-slug", account.slug)
      assert has_element?(view, "#getting-started-continue[disabled]")

      second = client_fixture(account: account, actor: actor, name: "ada-desktop") |> online()
      assert eventually(fn -> status_done?(view, 1) end)
      assert has_element?(view, "#getting-started-status-1", "ada-desktop is online")

      # Step 3: ping the second from the first
      continue(view)
      assert has_element?(view, "#getting-started-mesh-step-2", "Ping ada-desktop from ada-laptop")
      assert has_element?(view, "#getting-started-ping", "ping #{Portal.Device.fqdn(second)}")
      assert has_element?(view, "#getting-started-continue[disabled]")

      policy_authorization_fixture(account: account, actor: actor, client: first, gateway: second)
      assert eventually(fn -> status_done?(view, 2) end)
      assert has_element?(view, "#getting-started-status-2", "ada-laptop reached ada-desktop")

      # Done
      continue(view)
      assert has_element?(view, "#getting-started-mesh-done", "Your devices are connected")
      assert has_element?(view, "#getting-started-back", "Change goal")

      view |> element("#getting-started-continue", "Done") |> render_click()
      refute has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == :device_mesh
    end

    test "ignores devices that belong to someone else", %{conn: conn, account: account, actor: actor} do
      view = open_mesh(conn, account, actor)

      other = actor_fixture(account: account)
      client_fixture(account: account, actor: other) |> online()
      # Let a few checks run
      Process.sleep(100)

      refute status_done?(view, 0)
      assert has_element?(view, "#getting-started-continue[disabled]")
    end

    test "ignores a connection to a device outside the two", %{conn: conn, account: account, actor: actor} do
      first = client_fixture(account: account, actor: actor) |> online()
      client_fixture(account: account, actor: actor) |> online()
      gateway = gateway_fixture(account: account)

      view = open_mesh(conn, account, actor)
      assert has_element?(view, "#getting-started-mesh-step-2")

      policy_authorization_fixture(account: account, actor: actor, client: first, gateway: gateway)
      Process.sleep(100)

      refute status_done?(view, 2)
    end

    test "can't continue before the step is done", %{conn: conn, account: account, actor: actor} do
      view = open_mesh(conn, account, actor)

      view |> element("#getting-started-modal") |> render_hook("continue", %{})

      assert has_element?(view, "#getting-started-mesh-step-0")
    end

    test "reopening picks up at the first step that isn't done", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor) |> online()

      view = open_mesh(conn, account, actor)

      assert has_element?(view, "#getting-started-mesh-step-1")
    end

    test "reopening after everything is done shows the finish screen", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      first = client_fixture(account: account, actor: actor) |> online()
      second = client_fixture(account: account, actor: actor) |> online()
      policy_authorization_fixture(account: account, actor: actor, client: second, gateway: first)

      view = open_mesh(conn, account, actor)

      assert has_element?(view, "#getting-started-mesh-done")
    end

    test "back returns to the previous step", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor) |> online()
      view = open_mesh(conn, account, actor)
      assert has_element?(view, "#getting-started-mesh-step-1")

      view |> element("#getting-started-back", "Back") |> render_click()

      assert has_element?(view, "#getting-started-mesh-step-0")
      assert status_done?(view, 0)
    end

    test "change goal on the first step goes back to the chooser", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      view = open_mesh(conn, account, actor)

      view |> element("#getting-started-back", "Change goal") |> render_click()

      assert has_element?(view, "#getting-started-goal-device_mesh")
      assert getting_started(actor) == :device_mesh
    end

    test "closing keeps the goal", %{conn: conn, account: account, actor: actor} do
      view = open_mesh(conn, account, actor)

      view |> element("#getting-started-modal") |> render_hook("dismiss", %{})

      refute has_element?(view, "#getting-started-modal")
      assert getting_started(actor) == :device_mesh
    end
  end

  describe "reach a remote network or service" do
    import Portal.GroupFixtures
    import Portal.SiteFixtures

    setup %{account: account} do
      actor = admin_actor_fixture(account: account) |> put_getting_started(:remote_access)
      site = site_fixture(account: account, name: "Default Site")
      everyone = managed_group_fixture(account: account, name: "Everyone")
      %{actor: actor, site: site, everyone: everyone}
    end

    defp open_remote(conn, account, actor) do
      view = open_sites(conn, account, actor)
      view |> element("#open-getting-started") |> render_click()
      view
    end

    defp submit_address(view, address) do
      view
      |> form("#getting-started-address-form", resource: %{address: address})
      |> render_submit()
    end

    defp preferences(actor) do
      Portal.Repo.get_by!(Portal.Actor, account_id: actor.account_id, id: actor.id).preferences
    end

    defp gateway_count(account) do
      Portal.Repo.aggregate(
        from(d in Portal.Device, where: d.account_id == ^account.id and d.type == :gateway),
        :count
      )
    end

    test "walks through all four steps", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site,
      everyone: everyone
    } do
      view = open_remote(conn, account, actor)

      # Step 1: this computer
      assert has_element?(view, "#getting-started-remote-step-0")
      assert has_element?(view, "#getting-started-continue[disabled]")
      client = client_fixture(account: account, actor: actor, name: "ada-laptop") |> online()
      assert eventually(fn -> status_done?(view, 0) end)
      continue(view)

      # Step 2: what to reach
      assert has_element?(view, "#getting-started-remote-step-1", "What do you want to reach?")
      submit_address(view, "wiki.example.internal")

      resource = Portal.Repo.get_by!(Portal.Resource, account_id: account.id, name: "wiki.example.internal")
      assert resource.type == :dns
      assert resource.address == "wiki.example.internal"
      assert resource.site_id == site.id

      assert Portal.Repo.get_by!(Portal.Policy,
               account_id: account.id,
               group_id: everyone.id,
               resource_id: resource.id
             )

      # Step 3: the Gateway, with an install command for a pre-created Gateway
      assert has_element?(view, "#getting-started-remote-step-2", "Install a Gateway")
      assert render(view) =~ "Use this token when prompted"
      assert %{getting_started_resource_id: resource_id, getting_started_gateway_id: gateway_id} =
               preferences(actor)

      assert resource_id == resource.id
      gateway = Portal.Repo.get_by!(Portal.Device, account_id: account.id, id: gateway_id)
      assert gateway.site_id == site.id

      for {tab, icon} <- [
            {"debian-instructions", "icon-os-debian"},
            {"docker-instructions", "icon-docker"},
            {"systemd-instructions", "ri-terminal-line"}
          ] do
        assert has_element?(view, "#getting-started-#{tab} .#{icon}")
      end

      view |> element("#getting-started-docker-instructions") |> render_click()
      assert has_element?(view, "#deploy-code-docker", "docker run")

      gateway |> Map.put(:site_id, site.id) |> online()
      assert eventually(fn -> status_done?(view, "gateway") end)
      continue(view)

      # Step 4: reach it
      assert has_element?(view, "#getting-started-remote-step-3", "Open wiki.example.internal")
      assert has_element?(view, "#getting-started-try", "ping wiki.example.internal")
      assert has_element?(view, "#getting-started-continue[disabled]")

      policy_authorization_fixture(
        account: account,
        actor: actor,
        client: client,
        gateway: gateway,
        resource: resource,
        group: everyone
      )

      assert eventually(fn -> status_done?(view, "reach") end)
      continue(view)

      assert has_element?(view, "#getting-started-remote-done", "You're connected")

      assert has_element?(
               view,
               ~s(#getting-started-remote-done a[href="/#{account.slug}/resources/#{resource.id}"]),
               "Choose which groups can access it"
             )

      assert has_element?(
               view,
               ~s(#getting-started-remote-done a[href="/#{account.slug}/groups/new"]),
               "Create groups for your team"
             )

      view |> element("#getting-started-continue", "Done") |> render_click()
      refute has_element?(view, "#getting-started-modal")
    end

    test "labels the kind of address as it is typed", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor) |> online()
      view = open_remote(conn, account, actor)

      for {address, label} <- [
            {"wiki.example.internal", "DNS"},
            {"10.0.1.20", "IP"},
            {"10.0.0.0/16", "CIDR"}
          ] do
        view
        |> form("#getting-started-address-form", resource: %{address: address})
        |> render_change()

        assert has_element?(view, "#getting-started-address-type", label)
      end
    end

    test "shows why an address can't be added", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor) |> online()
      view = open_remote(conn, account, actor)

      submit_address(view, "10.0.0.0/99")

      assert has_element?(view, "#getting-started-remote-step-1")
      assert has_element?(view, ~s([data-validation-error-for="resource[address]"]))
      refute Portal.Repo.get_by(Portal.Resource, account_id: account.id, name: "10.0.0.0/99")
    end

    test "creates the Default Site when the account has none", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      Portal.Repo.delete!(site)
      client_fixture(account: account, actor: actor) |> online()
      view = open_remote(conn, account, actor)

      submit_address(view, "10.0.1.20")

      resource = Portal.Repo.get_by!(Portal.Resource, account_id: account.id, name: "10.0.1.20")
      assert Portal.Repo.get_by!(Portal.Site, account_id: account.id, id: resource.site_id).name == "Default Site"
    end

    test "reopening reuses the Gateway it created instead of making another", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      client_fixture(account: account, actor: actor) |> online()
      conn = authorize_conn(conn, actor)

      {:ok, view, _html} = live(conn, ~p"/#{account}/sites")
      view |> element("#open-getting-started") |> render_click()
      submit_address(view, "wiki.example.internal")
      %{getting_started_gateway_id: gateway_id} = preferences(actor)
      count = gateway_count(account)

      {:ok, reopened, _html} = live(conn, ~p"/#{account}/resources")
      reopened |> element("#open-getting-started") |> render_click()

      assert has_element?(reopened, "#getting-started-remote-step-2")
      assert render(reopened) =~ "Use this token when prompted"
      assert preferences(actor).getting_started_gateway_id == gateway_id
      assert gateway_count(account) == count
    end

    test "skips the install command when the Site already has a Gateway online", %{
      conn: conn,
      account: account,
      actor: actor,
      site: site
    } do
      client_fixture(account: account, actor: actor) |> online()
      gateway_fixture(account: account, site: site) |> online()
      count = gateway_count(account)
      view = open_remote(conn, account, actor)

      submit_address(view, "wiki.example.internal")

      assert has_element?(view, "#getting-started-remote-step-2")
      assert status_done?(view, "gateway")
      refute render(view) =~ "Use this token when prompted"
      assert gateway_count(account) == count
    end

    test "suggests a host to reach in a network", %{conn: conn, account: account, actor: actor, site: site} do
      client_fixture(account: account, actor: actor) |> online()
      gateway_fixture(account: account, site: site) |> online()
      view = open_remote(conn, account, actor)

      submit_address(view, "10.0.0.0/16")
      continue(view)

      assert has_element?(view, "#getting-started-remote-step-3", "Reach something in 10.0.0.0/16")
      assert has_element?(view, "#getting-started-try", "ping 10.0.0.1")
    end

    test "has no command to suggest for a wildcard name", %{conn: conn, account: account, actor: actor, site: site} do
      client_fixture(account: account, actor: actor) |> online()
      gateway_fixture(account: account, site: site) |> online()
      view = open_remote(conn, account, actor)

      submit_address(view, "*.example.internal")
      continue(view)

      assert has_element?(view, "#getting-started-remote-step-3", "Reach a host in *.example.internal")
      refute has_element?(view, "#getting-started-try")
    end

    test "keeps the added Resource when going back", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor) |> online()
      view = open_remote(conn, account, actor)
      submit_address(view, "wiki.example.internal")

      view |> element("#getting-started-back", "Back") |> render_click()

      assert has_element?(view, "#getting-started-status-resource", "wiki.example.internal was added")
      refute has_element?(view, "#getting-started-address-form")
      refute has_element?(view, "#getting-started-continue[disabled]")
    end
  end

  describe "changing goal" do
    setup %{account: account} do
      actor = admin_actor_fixture(account: account) |> put_getting_started(:device_mesh)
      %{actor: actor}
    end

    test "is offered on the first step in place of back", %{conn: conn, account: account, actor: actor} do
      view = open_sites(conn, account, actor)
      view |> element("#open-getting-started") |> render_click()

      assert has_element?(view, "#getting-started-back", "Change goal")
    end

    test "is not offered on the steps in between", %{conn: conn, account: account, actor: actor} do
      client_fixture(account: account, actor: actor) |> online()
      view = open_sites(conn, account, actor)
      view |> element("#open-getting-started") |> render_click()

      assert has_element?(view, "#getting-started-mesh-step-1")
      assert has_element?(view, "#getting-started-back", "Back")
      refute render(view) =~ "Change goal"
    end

    test "is offered on the finish screen and switches to the other goal", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      first = client_fixture(account: account, actor: actor) |> online()
      second = client_fixture(account: account, actor: actor) |> online()
      policy_authorization_fixture(account: account, actor: actor, client: first, gateway: second)

      view = open_sites(conn, account, actor)
      view |> element("#open-getting-started") |> render_click()
      assert has_element?(view, "#getting-started-mesh-done")

      view |> element("#getting-started-back", "Change goal") |> render_click()
      view |> element("#getting-started-goal-remote_access") |> render_click()

      assert has_element?(view, "#getting-started-remote-step-1")
      assert getting_started(actor) == :remote_access
    end
  end
end
