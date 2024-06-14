defmodule Domain.Auth.DirectorySync do
  use Supervisor
  alias Domain.Auth.DirectorySync.WorkOS

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      WorkOS
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
