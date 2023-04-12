defmodule Domain.Relays do
  use Supervisor
  alias Domain.{Repo, Auth, Validator}
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Domain.Relays.Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

end
