defmodule Domain.Jobs.RecurrentTest do
  use ExUnit.Case, async: true
  import Domain.Jobs.Recurrent

  defmodule TestDefinition do
    use Domain.Jobs.Recurrent, otp_app: :domain
    require Logger

    every seconds(1), :second_test, config do
      send(config[:test_pid], :executed)
    end

    every minutes(5), :minute_test do
      :ok
    end
  end

  describe "seconds/1" do
    test "converts seconds to milliseconds" do
      assert seconds(1) == 1000
      assert seconds(13) == 13000
    end
  end

  describe "minutes/1" do
    test "converts minutes to milliseconds" do
      assert minutes(1) == 60000
      assert minutes(13) == 780_000
    end
  end

  test "defines callbacks" do
    assert length(TestDefinition.__handlers__()) == 2

    assert {:minute_test, 300_000} in TestDefinition.__handlers__()
    assert {:second_test, 1000} in TestDefinition.__handlers__()

    assert TestDefinition.minute_test(test_pid: self()) == :ok

    assert TestDefinition.second_test(test_pid: self()) == :executed
    assert_receive :executed
  end
end
