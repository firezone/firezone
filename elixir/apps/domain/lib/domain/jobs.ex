defmodule Domain.Jobs do
  @moduledoc """
  This module starts all recurrent job handlers defined by a module
  in individual processes and supervises them.
  """
  use Supervisor

  def start_link(module) do
    Supervisor.start_link(__MODULE__, module)
  end

  @impl true
  def init(module) do
    config = module.__config__()

    children =
      Enum.flat_map(module.__handlers__(), fn {name, interval} ->
        handler_config = Keyword.get(config, name, [])
        worker_module_enabled? = Keyword.get(config, :enabled, true)
        handler_enabled? = Keyword.get(handler_config, :enabled, true)

        if worker_module_enabled? and handler_enabled? do
          [
            Supervisor.child_spec(
              {Domain.Jobs.Executors.Global, {{module, name}, interval, handler_config}},
              id: {module, name}
            )
          ]
        else
          []
        end
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
