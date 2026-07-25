defmodule Portal.Google.CredentialsTest do
  use ExUnit.Case, async: true

  alias Portal.Google.Credentials

  setup do
    %{server: start_supervised!({Credentials, name: unique_name()})}
  end

  test "caches a token until five minutes before expiration", %{server: server} do
    test_pid = self()

    fetch = fn ->
      send(test_pid, :fetch)
      {:ok, %{token: "cached-token", expires_in: 3600}}
    end

    assert Credentials.fetch(server, :token, fetch) == {:ok, "cached-token"}
    assert Credentials.fetch(server, :token, fetch) == {:ok, "cached-token"}

    assert_received :fetch
    refute_received :fetch
  end

  test "caches tokens independently by key", %{server: server} do
    test_pid = self()

    fetch = fn key ->
      fn ->
        send(test_pid, {:fetch, key})
        {:ok, %{token: "token-for-#{key}", expires_in: 3600}}
      end
    end

    assert Credentials.fetch(server, :first, fetch.(:first)) == {:ok, "token-for-first"}
    assert Credentials.fetch(server, :second, fetch.(:second)) == {:ok, "token-for-second"}
    assert Credentials.fetch(server, :first, fetch.(:first)) == {:ok, "token-for-first"}
    assert Credentials.fetch(server, :second, fetch.(:second)) == {:ok, "token-for-second"}

    assert_received {:fetch, :first}
    assert_received {:fetch, :second}
  end

  test "refreshes a token inside the five-minute margin", %{server: server} do
    test_pid = self()

    fetch = fn ->
      send(test_pid, :fetch)
      {:ok, %{token: "short-lived-token", expires_in: 300}}
    end

    assert Credentials.fetch(server, :token, fetch) == {:ok, "short-lived-token"}
    assert Credentials.fetch(server, :token, fetch) == {:ok, "short-lived-token"}

    assert_received :fetch
    assert_received :fetch
  end

  test "does not cache errors and remains available", %{server: server} do
    assert Credentials.fetch(server, :token, fn -> {:error, :unavailable} end) ==
             {:error, :unavailable}

    assert Process.alive?(server)

    assert Credentials.fetch(server, :token, fn ->
             {:ok, %{token: "recovered-token", expires_in: 3600}}
           end) == {:ok, "recovered-token"}
  end

  test "fetches directly when the selected cache process is not running" do
    missing_server = unique_name()

    assert Credentials.fetch(missing_server, :token, fn ->
             {:ok, %{token: "direct-token", expires_in: "3600"}}
           end) == {:ok, "direct-token"}
  end

  defp unique_name, do: :"google_credentials_#{inspect(make_ref())}"
end
