defmodule Domain.Events.Hooks.Tokens do
  @behaviour Domain.Events.Hooks
  alias Domain.PubSub

  @impl true
  def on_insert(_data), do: :ok

  @impl true

  # updates for email tokens have no side effects
  def on_update(%{"type" => "email"}, _data), do: :ok

  def on_update(_old_data, %{"type" => "email"}), do: :ok

  # Soft-delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, _new_data), do: :ok

  @impl true
  def on_delete(%{"id" => token_id}) do
    PubSub.Token.disconnect(token_id)
  end
end
