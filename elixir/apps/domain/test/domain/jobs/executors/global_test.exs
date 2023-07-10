defmodule Domain.Jobs.Executors.GlobalTest do
  use ExUnit.Case, async: true
  import Domain.Jobs.Executors.Global

  def execute(:send_test_message, config) do
    send(config[:test_pid], {:executed, self(), :erlang.monotonic_time()})
    :ok
  end

  test "executes the handler on the interval" do
    assert {:ok, _pid} = start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    assert_receive {:executed, _pid, time1}
    assert_receive {:executed, _pid, time2}

    assert time1 < time2
  end

  test "delays initial message by the initial_delay" do
    assert {:ok, _pid} =
             start_link({
               {__MODULE__, :send_test_message},
               25,
               test_pid: self(), initial_delay: 100
             })

    refute_receive {:executed, _pid, _time}, 50
    assert_receive {:executed, _pid, _time}
  end

  test "registers itself as a leader if there is no global name registered" do
    assert {:ok, pid} = start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})
    name = {Domain.Jobs.Executors.Global, __MODULE__, :send_test_message}
    assert :global.whereis_name(name) == pid

    assert :sys.get_state(pid) ==
             {
               {
                 {__MODULE__, :send_test_message},
                 25,
                 [test_pid: self()]
               },
               :leader
             }
  end

  test "other processes register themselves as fallbacks and monitor the leader" do
    assert {:ok, leader_pid} =
             start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    assert {:ok, fallback1_pid} =
             start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    assert {:ok, fallback2_pid} =
             start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    name = {Domain.Jobs.Executors.Global, __MODULE__, :send_test_message}
    assert :global.whereis_name(name) == leader_pid

    assert {_state, {:fallback, ^leader_pid, _monitor_ref}} = :sys.get_state(fallback1_pid)
    assert {_state, {:fallback, ^leader_pid, _monitor_ref}} = :sys.get_state(fallback2_pid)
  end

  test "other processes register a new leader when old one is down" do
    assert {:ok, leader_pid} =
             start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    assert {:ok, fallback1_pid} =
             start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    assert {:ok, fallback2_pid} =
             start_link({{__MODULE__, :send_test_message}, 25, test_pid: self()})

    Process.flag(:trap_exit, true)
    Process.exit(leader_pid, :kill)
    assert_receive {:EXIT, ^leader_pid, :killed}

    %{leader: [new_leader_pid], fallback: [fallback_pid]} =
      Enum.group_by([fallback1_pid, fallback2_pid], fn pid ->
        case :sys.get_state(pid) do
          {_state, {:fallback, _leader_pid, _monitor_ref}} -> :fallback
          {_state, :leader} -> :leader
        end
      end)

    assert {_state, {:fallback, ^new_leader_pid, _monitor_ref}} = :sys.get_state(fallback_pid)
    assert {_state, :leader} = :sys.get_state(new_leader_pid)

    name = {Domain.Jobs.Executors.Global, __MODULE__, :send_test_message}
    assert :global.whereis_name(name) == new_leader_pid

    assert_receive {:executed, ^new_leader_pid, _time}
  end
end
