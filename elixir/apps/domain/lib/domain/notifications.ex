defmodule Domain.Notifications do
  use Supervisor
  require Logger

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Domain.Notifications.Jobs.OutdatedGateways
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
