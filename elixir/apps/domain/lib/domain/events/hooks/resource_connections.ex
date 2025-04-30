defmodule Domain.Events.Hooks.ResourceConnections do
  def insert(_data) do
    :ok
  end

  def update(_old_data, _data) do
    :ok
  end

  def delete(_old_data) do
    :ok
  end
end
