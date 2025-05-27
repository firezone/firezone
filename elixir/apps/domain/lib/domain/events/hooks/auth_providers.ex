defmodule Domain.Events.Hooks.AuthProviders do
  def on_insert(_data) do
    :ok
  end

  def on_update(_old_data, _data) do
    :ok
  end

  def on_delete(_old_data) do
    :ok
  end
end
