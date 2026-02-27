defmodule Portal.Workers.DeleteExpiredAuthenticationCacheEntriesTest do
  use Portal.DataCase, async: true

  alias Portal.AuthenticationCache
  alias Portal.Workers.DeleteExpiredAuthenticationCacheEntries

  test "perform/1 deletes expired authentication cache entries" do
    expired_key = "worker-expired-#{System.unique_integer([:positive, :monotonic])}"
    valid_key = "worker-valid-#{System.unique_integer([:positive, :monotonic])}"

    assert :ok = AuthenticationCache.put(expired_key, %{"value" => "expired"}, ttl: 50)
    assert :ok = AuthenticationCache.put(valid_key, %{"value" => "valid"}, ttl: :timer.minutes(5))

    wait_until(fn -> AuthenticationCache.get(expired_key) == :error end)

    assert :ok = DeleteExpiredAuthenticationCacheEntries.perform(%Oban.Job{})

    assert :error = AuthenticationCache.get(expired_key)
    assert {:ok, %{"value" => "valid"}} = AuthenticationCache.get(valid_key)
  end

  defp wait_until(fun, attempts \\ 200) do
    if fun.() do
      :ok
    else
      wait_until_retry(fun, attempts)
    end
  end

  defp wait_until_retry(_fun, 0) do
    flunk("timed out waiting for condition")
  end

  defp wait_until_retry(fun, attempts) do
    Process.sleep(1)
    wait_until(fun, attempts - 1)
  end
end
