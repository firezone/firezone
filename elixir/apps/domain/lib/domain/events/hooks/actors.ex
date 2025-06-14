defmodule Domain.Events.Hooks.Actors do
  @behaviour Domain.Events.Hooks

  @impl true
  def on_insert(_data), do: :ok

  @impl true
  def on_update(_old_data, _data), do: :ok

  @impl true
  def on_delete(_old_data), do: :ok
end
