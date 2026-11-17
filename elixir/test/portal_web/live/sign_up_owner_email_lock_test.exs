defmodule PortalWeb.SignUp.OwnerEmailLockTest do
  # The sandbox shares one connection between processes, so the lock has to be
  # exercised on independent connections to show that it blocks.
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Portal.Repo
  alias PortalWeb.SignUp.Database

  test "serializes sign-ups for the same email regardless of case" do
    email = "owner-#{System.unique_integer([:positive])}@example.com"
    holder = hold_lock(email)

    contender = try_lock(String.upcase(email))
    refute_receive {:locked, ^contender}, 500

    send(holder, :release)
    assert_receive {:locked, ^contender}, 5_000
    send(contender, :release)
  end

  test "does not block sign-ups for a different email" do
    holder = hold_lock("first-#{System.unique_integer([:positive])}@example.com")

    contender = try_lock("second-#{System.unique_integer([:positive])}@example.com")
    assert_receive {:locked, ^contender}, 5_000

    send(holder, :release)
    send(contender, :release)
  end

  defp hold_lock(email) do
    pid = try_lock(email)
    assert_receive {:locked, ^pid}, 5_000
    pid
  end

  defp try_lock(email) do
    test_pid = self()

    spawn_link(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Database.with_owner_email_lock(email, fn ->
          send(test_pid, {:locked, self()})

          receive do
            :release -> {:ok, :released}
          end
        end)
      end)
    end)
  end
end
