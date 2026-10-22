defmodule Portal.Test.LogicalSlots do
  @moduledoc """
  Creates logical replication slots without waiting on other tests.

  Postgres only finishes creating a logical slot once every transaction that
  was open on the server has ended. Async tests keep their sandbox
  transactions open, so a slot created mid-suite waits for the slowest test
  running beside it. Copying an existing slot does not wait.

  This process creates one temporary template slot before any test runs and
  hands out copies of it. The template is advanced to the current WAL
  position before each copy, so a copy only decodes what happens after it.
  Being temporary, the template is dropped when this process's connection
  closes, even if the suite crashes.
  """

  use GenServer

  def start do
    GenServer.start(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Creates a durable logical slot named `name` using the pgoutput plugin."
  def create!(name) do
    :ok = GenServer.call(__MODULE__, {:create, name}, :infinity)
  end

  @impl true
  def init(nil) do
    {:ok, conn} =
      Portal.Repo.config()
      |> Keyword.drop([:pool])
      |> Keyword.put(:pool_size, 1)
      |> Postgrex.start_link()

    template = "test_slot_template_#{System.pid()}"

    # Nothing in this suite runs yet, but other suites on the same server may,
    # so this one creation is allowed to wait for them.
    Postgrex.query!(
      conn,
      "SELECT pg_create_logical_replication_slot($1, 'pgoutput', true)",
      [template],
      timeout: :infinity
    )

    {:ok, %{conn: conn, template: template}}
  end

  @impl true
  def handle_call({:create, name}, _from, state) do
    Postgrex.query!(
      state.conn,
      "SELECT pg_replication_slot_advance($1, pg_current_wal_flush_lsn())",
      [state.template],
      timeout: :infinity
    )

    Postgrex.query!(
      state.conn,
      "SELECT pg_copy_logical_replication_slot($1, $2, false)",
      [state.template, name]
    )

    {:reply, :ok, state}
  end
end
