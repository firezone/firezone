defmodule Portal.Devices.RegistrationRateLimitTest do
  use ExUnit.Case, async: true

  alias Portal.Account
  alias Portal.Accounts.Limits
  alias Portal.Devices.RegistrationRateLimit

  test "permits a double rollout burst and refills one allowance per day" do
    account = %Account{
      id: Ecto.UUID.generate(),
      limits: %Limits{users_count: 6, connected_devices_per_actor: 3}
    }

    for _ <- 1..56, do: assert(:ok == RegistrationRateLimit.check(account))
    assert {:error, :rate_limit, retry_after_ms} = RegistrationRateLimit.check(account)
    # 28 registrations/day means about 51 minutes until the next registration.
    assert retry_after_ms in 3_000_000..3_120_000

    key = "device_registration:#{account.id}"
    [{^key, remaining, updated_at}] = :ets.lookup(PortalAPI.RateLimit.Local, key)
    :ets.insert(PortalAPI.RateLimit.Local, {key, remaining, updated_at - :timer.hours(24)})
    for _ <- 1..28, do: assert(:ok == RegistrationRateLimit.check(account))
    assert {:error, :rate_limit, _} = RegistrationRateLimit.check(account)
  end

  test "accounts have independent buckets and seat changes use the current allowance" do
    limits = %Limits{users_count: 1, connected_devices_per_actor: 1}
    account = %Account{id: Ecto.UUID.generate(), limits: limits}
    for _ <- 1..22, do: assert(:ok == RegistrationRateLimit.check(account))
    assert {:error, :rate_limit, _} = RegistrationRateLimit.check(account)
    assert :ok == RegistrationRateLimit.check(%{account | id: Ecto.UUID.generate()})

    increased = %{account | limits: %{limits | users_count: 100}}
    assert {:error, :rate_limit, retry_after_ms} = RegistrationRateLimit.check(increased)
    assert retry_after_ms < 1_000_000
  end

  test "add-on devices are included and unlimited entitlements skip Hammer" do
    limits = %Limits{
      users_count: 0,
      connected_devices_per_actor: 1,
      adhoc_service_accounts_count: 100
    }

    account = %Account{id: Ecto.UUID.generate(), limits: limits}
    for _ <- 1..220, do: assert(:ok == RegistrationRateLimit.check(account))
    assert {:error, :rate_limit, _} = RegistrationRateLimit.check(account)

    assert :ok ==
             RegistrationRateLimit.check(%{
               account
               | limits: %{limits | connected_devices_per_actor: nil}
             })

    assert :ok ==
             RegistrationRateLimit.check(%{
               account
               | limits: %{limits | adhoc_service_accounts_count: nil}
             })

    assert :ok == RegistrationRateLimit.check(%{account | limits: nil})
  end
end
