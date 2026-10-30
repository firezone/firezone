defmodule Portal.Changes.Hooks.AccountSlugs do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    account_slug = struct_from_params(Portal.AccountSlug, data)
    change = %Change{lsn: lsn, op: :insert, struct: account_slug}

    PubSub.Changes.broadcast(account_slug.account_id, :account_slugs, change)
  end

  # Registry rows are never updated.
  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  # Rows only go away with their account, which Hooks.Accounts handles.
  @impl true
  def on_delete(_lsn, _old_data), do: :ok
end
