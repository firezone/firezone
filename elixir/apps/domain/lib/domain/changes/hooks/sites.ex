defmodule Domain.Changes.Hooks.Sites do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Changes.Change, PubSub}
  import Domain.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(lsn, old_data, data) do
    old_site = struct_from_params(Domain.Site, old_data)
    site = struct_from_params(Domain.Site, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_site, struct: site}

    PubSub.Account.broadcast(site.account_id, change)
  end

  @impl true

  # Deleting a site will delete the associated resource connection, where
  # we handle removing it from the client's resource list.
  def on_delete(_lsn, _old_data), do: :ok
end
