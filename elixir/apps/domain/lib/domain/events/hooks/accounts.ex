defmodule Domain.Events.Hooks.Accounts do
  @behaviour Domain.Events.Hooks
  alias Domain.{Accounts, PubSub, SchemaHelpers}
  require Logger

  @impl true
  def on_insert(_data), do: :ok

  # Account slug changed - disconnect gateways for updated init

  @impl true

  # Account disabled - process as a delete
  def on_update(
        %{"disabled_at" => nil} = old_data,
        %{"disabled_at" => disabled_at}
      )
      when not is_nil(disabled_at) do
    on_delete(old_data)
  end

  # Account soft-deleted - process as a delete

  def on_update(
        %{"deleted_at" => nil} = old_data,
        %{"deleted_at" => deleted_at}
      )
      when not is_nil(deleted_at) do
    on_delete(old_data)
  end

  def on_update(old_data, data) do
    old_account = SchemaHelpers.struct_from_params(Accounts.Account, old_data)
    account = SchemaHelpers.struct_from_params(Accounts.Account, data)
    :ok = PubSub.Account.broadcast(account.id, {:updated, old_account, account})
  end

  @impl true

  def on_delete(old_data) do
    account = SchemaHelpers.struct_from_params(Accounts.Account, old_data)
    PubSub.Account.broadcast(account.id, {:deleted, account})

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Domain.Flows.delete_flows_for(account)
  end
end
