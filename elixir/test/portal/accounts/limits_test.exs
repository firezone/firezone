defmodule Portal.Accounts.LimitsTest do
  use ExUnit.Case, async: true

  alias Portal.Accounts.Limits

  describe "device_allowance/1" do
    test "derives quotas from the existing seat and device allowances" do
      for {seats, devices, expected} <- [
            {6, 3, 28},
            {1, 5, 15},
            {10, 5, 61},
            {25, 5, 137},
            {100, 5, 520},
            {500, 5, 2560},
            {100, 10, 1020},
            {1000, 10, 10110}
          ] do
        limits = %Limits{users_count: seats, connected_devices_per_actor: devices}
        assert Limits.device_allowance(limits) == expected
      end
    end

    test "adds a Gateway allowance for each complete ten seats" do
      for {seats, expected} <- [{0, 10}, {9, 55}, {10, 61}, {19, 106}, {20, 112}] do
        assert Limits.device_allowance(%Limits{
                 users_count: seats,
                 connected_devices_per_actor: 5
               }) == expected
      end
    end

    test "uses the active-seat allowance ahead of the user allowance" do
      limits = %Limits{
        users_count: 1000,
        monthly_active_users_count: 100,
        connected_devices_per_actor: 10
      }

      assert Limits.device_allowance(limits) == 1020
      assert Limits.device_allowance(%{limits | monthly_active_users_count: 0}) == 10
    end

    test "adds one device per seat-exempt service account without multiplying or adding Gateways" do
      limits = %Limits{
        monthly_active_users_count: 100,
        connected_devices_per_actor: 10,
        adhoc_service_accounts_count: 10_000
      }

      assert Limits.device_allowance(limits) == 11_020
      assert Limits.device_allowance(%{limits | adhoc_service_accounts_count: 0}) == 1020
      assert Limits.device_allowance(%{limits | monthly_active_users_count: 0}) == 10_010
      assert Limits.device_allowance(%{limits | adhoc_service_accounts_count: nil}) == nil
    end

    test "unlimited or missing seat and device allowances remain unlimited" do
      assert Limits.device_allowance(nil) == nil
      assert Limits.device_allowance(%Limits{}) == nil

      assert Limits.device_allowance(%Limits{
               monthly_active_users_count: 100,
               connected_devices_per_actor: nil
             }) == nil

      assert Limits.device_allowance(%Limits{connected_devices_per_actor: 5}) == nil
    end
  end

  test "Relay quotas allow twice the device allowance, or remain unlimited" do
    assert Limits.relay_allocation_limit(%Limits{users_count: 6, connected_devices_per_actor: 3}) ==
             56

    assert Limits.relay_allocation_limit(%Limits{
             users_count: 100,
             connected_devices_per_actor: 5
           }) == 1040

    assert Limits.relay_allocation_limit(%Limits{
             monthly_active_users_count: 100,
             connected_devices_per_actor: 10,
             adhoc_service_accounts_count: 10_000
           }) == 22_040

    assert Limits.relay_allocation_limit(%Limits{}) == nil
    assert Limits.relay_allocation_limit(nil) == nil
  end
end
