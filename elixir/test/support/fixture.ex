defmodule Portal.Fixture do
  alias Portal.Repo

  defmacro __using__(_opts) do
    quote do
      import Portal.Fixture
      alias Portal.Repo
      alias Portal.Fixtures
    end
  end

  def update!(schema, changes) do
    schema
    |> Ecto.Changeset.change(Enum.into(changes, %{}))
    |> Repo.update!()
  end

  def unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

  # Use for any value a test refutes in captured logs: capture_log is global,
  # so other async tests can log the same fixed strings.
  def unique_email(prefix) do
    "#{prefix}-#{unique_integer()}@example.com"
  end

  def unique_name(prefix) do
    "#{prefix} #{unique_integer()}"
  end

  # Without a marker, only lines logged by the calling process count. Pass a
  # marker when the message comes from another process (a GenServer, a job).
  def logged_lines(log) do
    logged_lines(log, "pid=#{:erlang.pid_to_list(self())} ")
  end

  # For a negative log check on a fixed message: only lines that also carry this
  # test's unique value count, so other tests' identical messages are ignored.
  def logged_lines(log, marker) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, marker))
    |> Enum.join("\n")
  end

end
