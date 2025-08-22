defmodule Domain.Changes.Hooks.Accounts do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Accounts, Changes.Change, Flows, PubSub}
  import Domain.SchemaHelpers
  require Logger

  @impl true
  def on_insert(_lsn, _data), do: :ok

  # Account slug changed - disconnect gateways for updated init

  @impl true

  # Account disabled - process as a delete
  def on_update(
        lsn,
        %{"disabled_at" => nil} = old_data,
        %{"disabled_at" => disabled_at}
      )
      when not is_nil(disabled_at) do
    on_delete(lsn, old_data)
  end

  # Account soft-deleted - process as a delete
  def on_update(
        lsn,
        %{"deleted_at" => nil} = old_data,
        %{"deleted_at" => deleted_at}
      )
      when not is_nil(deleted_at) do
    on_delete(lsn, old_data)
  end

  def on_update(lsn, old_data, data) do
    old_account = struct_from_params(Accounts.Account, old_data)
    account = struct_from_params(Accounts.Account, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_account, struct: account}

    PubSub.Account.broadcast(account.id, change)
  end

  @impl true

  def on_delete(lsn, old_data) do
    account = struct_from_params(Accounts.Account, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: account}

    # TODO: Hard delete
    # This can be removed upon implementation of hard delete
    Flows.delete_flows_for(account)

    PubSub.Account.broadcast(account.id, change)
  end
end
