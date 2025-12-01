defmodule Domain.Changes.Hooks.Clients do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(lsn, old_data, data) do
    old_client = struct_from_params(Domain.Client, old_data)
    client = struct_from_params(Domain.Client, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_client, struct: client}

    # Unverifying a client
    # This is a special case - we need to delete associated flows when unverifying a client since
    # it could affect connectivity if any policies are based on the verified status.
    if not is_nil(old_client.verified_at) and is_nil(client.verified_at) do
      delete_flows_for(client)
    end

    PubSub.Account.broadcast(client.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    client = struct_from_params(Domain.Client, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: client}

    PubSub.Account.broadcast(client.account_id, change)
  end

  # Inline function from Domain.Flows
  defp delete_flows_for(%Domain.Client{} = client) do
    import Ecto.Query

    from(f in Domain.Flow, as: :flows)
    |> where([flows: f], f.account_id == ^client.account_id)
    |> where([flows: f], f.client_id == ^client.id)
    |> Domain.Safe.unscoped()
    |> Domain.Safe.delete_all()
  end
end
