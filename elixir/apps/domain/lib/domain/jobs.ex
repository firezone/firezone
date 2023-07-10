defmodule Domain.Jobs do
  @moduledoc """
  This module starts all recurrent job handlers defined by a module
  in individual processes and supervises them.
  """
  use Supervisor

  def start_link(module) do
    Supervisor.start_link(__MODULE__, module, name: __MODULE__)
  end

  def init(module) do
    config = module.__config__()

    children =
      Enum.flat_map(module.__handlers__(), fn {name, interval} ->
        handler_config = Keyword.get(config, name, [])

        if Keyword.get(handler_config, :enabled, true) do
          [{Domain.Jobs.Executors.Global, {{module, name}, interval, handler_config}}]
        else
          []
        end
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
