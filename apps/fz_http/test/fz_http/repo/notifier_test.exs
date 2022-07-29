defmodule FzHttp.Repo.NotifierTest do
  use ExUnit.Case, async: false

  import FzHttp.TestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias FzHttp.Events
  alias FzHttp.Repo

  @notify_wait 1

  setup do
    start_supervised!({Postgrex.Notifications, [name: Repo.Notifications] ++ Repo.config()})
    start_supervised!(Repo.Notifier)
    :ok = Sandbox.checkout(Repo)
  end

  test "adds and removes user from wall state on db notifications" do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, [user: user]} = create_user(%{})

      Process.sleep(@notify_wait)

      wall_state_add = :sys.get_state(Events.wall_pid())

      Repo.delete!(user)

      Process.sleep(@notify_wait)

      wall_state_remove = :sys.get_state(Events.wall_pid())

      assert wall_state_add ==
               %{
                 users: MapSet.new([user.id]),
                 devices: MapSet.new([]),
                 rules: MapSet.new([])
               }

      assert wall_state_remove ==
               %{
                 users: MapSet.new([]),
                 devices: MapSet.new([]),
                 rules: MapSet.new([])
               }
    end)
  end

  test "adds and removes rule from wall state on db notifications" do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, [rule: rule]} = create_rule(%{})

      Process.sleep(@notify_wait)

      wall_state_add = :sys.get_state(Events.wall_pid())

      Repo.delete!(rule)

      Process.sleep(@notify_wait)

      wall_state_remove = :sys.get_state(Events.wall_pid())

      assert wall_state_add ==
               %{
                 users: MapSet.new([]),
                 devices: MapSet.new([]),
                 rules:
                   MapSet.new([%{action: rule.action, destination: "10.10.10.0/24", user_id: nil}])
               }

      assert wall_state_remove ==
               %{
                 users: MapSet.new([]),
                 devices: MapSet.new([]),
                 rules: MapSet.new([])
               }
    end)
  end
end
