defmodule Portal.AuthenticationCacheTest do
  use Portal.DataCase, async: true

  alias Portal.AuthenticationCache

  defp unique_key do
    "auth-cache-test-#{System.unique_integer([:positive, :monotonic])}"
  end

  test "put/3 and get/1 returns stored value" do
    key = unique_key()
    value = %{"foo" => "bar"}

    assert :ok = AuthenticationCache.put(key, value)
    assert {:ok, ^value} = AuthenticationCache.get(key)
  end

  test "get/1 returns :error for expired entries" do
    key = unique_key()
    value = %{"short" => "lived"}

    assert :ok = AuthenticationCache.put(key, value, ttl: 50)
    wait_until(fn -> AuthenticationCache.get(key) == :error end)

    assert :error = AuthenticationCache.get(key)
  end

  test "pop/1 returns stored value and consumes it" do
    key = unique_key()
    value = %{"token" => "abc123"}

    assert :ok = AuthenticationCache.put(key, value)
    assert {:ok, ^value} = AuthenticationCache.pop(key)
    assert :error = AuthenticationCache.pop(key)
  end

  test "pop/1 returns :error for expired entries" do
    key = unique_key()

    assert :ok = AuthenticationCache.put(key, %{"expired" => true}, ttl: 50)
    wait_until(fn -> AuthenticationCache.get(key) == :error end)

    assert :error = AuthenticationCache.pop(key)
  end

  test "delete/1 removes entries" do
    key = unique_key()
    value = %{"delete" => "me"}

    assert :ok = AuthenticationCache.put(key, value)
    assert {:ok, ^value} = AuthenticationCache.get(key)
    assert :ok = AuthenticationCache.delete(key)
    assert :error = AuthenticationCache.get(key)
  end

  test "put/3 raises when ttl is invalid" do
    assert_raise ArgumentError, ~r/ttl must be a positive integer/, fn ->
      AuthenticationCache.put(unique_key(), %{"foo" => "bar"}, ttl: 0)
    end
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
