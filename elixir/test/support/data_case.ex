defmodule Portal.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Portal.DataCase, async: true`, although
  this option is not recommended for other databases.
  """
  use ExUnit.CaseTemplate
  use Portal.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Swoosh.TestAssertions
      import Portal.DataCase

      alias Portal.Repo
      alias Portal.Fixtures
      alias Portal.Mocks
    end
  end

  def assert_datetime_diff(%DateTime{} = datetime1, %DateTime{} = datetime2, is, leeway \\ 5) do
    assert DateTime.diff(datetime1, datetime2, :second) in (is - leeway)..(is + leeway)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  When code makes async requests to the Bypass server, there is a chance that we will hit
  a race condition: either a test process or task can be terminated before the Bypass server
  sent a response, which will lead to a exit signal to the test process.

  We work around it by cancelling the expectations check (because we don't really care about
  them to be met in the case of `stub/3` calls).

  See https://github.com/PSPDFKit-labs/bypass/issues/120
  """
  def cancel_bypass_expectations_check(bypass) do
    Bypass.down(bypass)
    on_exit({Bypass, bypass.pid}, fn -> :ok end)
  end
end
