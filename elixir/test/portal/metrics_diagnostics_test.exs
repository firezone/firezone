defmodule Portal.MetricsDiagnosticsTest do
  use Portal.DataCase, async: true
  import Portal.MetricsDiagnostics, only: [active?: 1]
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.MetricsFixtures

  describe "active?/1" do
    test "is true for a Client of an actor with unexpired diagnostics" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      client = client_fixture(account: account, actor: actor)

      refute active?(client)

      metrics_diagnostics_fixture(actor)
      assert active?(client)

      refute active?(client_fixture(account: account))
    end

    test "is false once the diagnostics expire" do
      actor = actor_fixture()
      client = client_fixture(account: actor.account, actor: actor)
      metrics_diagnostics_fixture(actor, DateTime.add(DateTime.utc_now(), -1, :second))

      refute active?(client)
    end

    test "is false for Gateways" do
      account = account_fixture()
      metrics_diagnostics_fixture(actor_fixture(account: account))

      refute active?(gateway_fixture(account: account))
    end
  end

  test "an actor's diagnostics are deleted with it" do
    actor = actor_fixture()
    metrics_diagnostics_fixture(actor)

    Repo.delete!(actor)

    assert Repo.aggregate(Portal.MetricsDiagnostics, :count) == 0
  end
end
