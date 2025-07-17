defmodule Domain.Events.Hooks.Tokens do
  @behaviour Domain.Events.Hooks
  alias Domain.{PubSub, Tokens, SchemaHelpers}

  @impl true
  def on_insert(_data), do: :ok

  @impl true

  # updates for email tokens have no side effects
  def on_update(%{"type" => "email"}, _data), do: :ok

  def on_update(_old_data, %{"type" => "email"}), do: :ok

  # Soft-delete - process as delete
  def on_update(%{"deleted_at" => nil} = old_data, %{"deleted_at" => deleted_at})
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  # Regular update
  def on_update(_old_data, _new_data), do: :ok

  @impl true
  def on_delete(old_data) do
    token = SchemaHelpers.struct_from_params(Tokens.Token, old_data)

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(token)

    PubSub.Account.broadcast(token.account_id, {:deleted, token})
  end
end
