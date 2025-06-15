defmodule Domain.Events.Hooks.Accounts do
  @behaviour Domain.Events.Hooks
  alias Domain.PubSub
  require Logger

  @impl true
  def on_insert(_data), do: :ok

  # Account disabled - disconnect clients
  @impl true
  def on_update(
        %{"disabled_at" => nil} = _old_data,
        %{"disabled_at" => disabled_at, "id" => account_id} = _data
      )
      when not is_nil(disabled_at) do
    PubSub.Account.Clients.disconnect(account_id)
  end

  def on_update(%{"config" => old_config}, %{"config" => config, "id" => account_id}) do
    if old_config != config do
      PubSub.Account.broadcast(account_id, :config_changed)
    else
      :ok
    end
  end

  @impl true
  def on_delete(_old_data) do
    :ok
  end
end
